//
//  SpeechAnalyzerEngine.swift
//  Sentient OS macOS
//
//  macOS 26+ speech-to-text via the Speech framework's SpeechAnalyzer + SpeechTranscriber — fully
//  on-device (private AND high-quality), no network, and no temp audio file (the mic stays in memory).
//  Live mic buffers are converted to the analyzer's format and streamed in; on stop we finalize and
//  return the single best transcript. No partials.
//
//  Model readiness is memoized + single-flight: SpeechTranscriber.installedLocales is the ONLY honest
//  installed check (assetInstallationRequest hands back a request even when the model is fully
//  installed — field-proven), and the one shared install task is shielded from caller cancellation
//  (downloadAndInstall ignores cancellation, so a "cancelled" install keeps running in the daemon).
//
//  Key methods: prewarm() (install the model ahead of first use) · start() · stopAndTranscribe() · cancel().
//

import Speech
import os
@preconcurrency import AVFAudio

@available(macOS 26, *)
final class SpeechAnalyzerEngine: QuickTranscriptionEngine {
    /// SpeechAnalyzer handles long-form audio; we cap a single spoken command at 3 minutes.
    static let maxUtteranceDuration: TimeInterval = 180

    /// ONE audio engine for the process. A fresh AVAudioEngine per capture opens a new HAL IO proc
    /// each press, and rapid press/cancel churn wedges CoreAudio input into delivering ZERO buffers
    /// (field-proven: a 2.3s hold fed the analyzer nothing). Reuse the instance; only the tap and
    /// start/stop cycle per capture.
    private static let sharedAudioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?
    private var tapInstalled = false
    /// (tap callbacks, buffers fed to the analyzer) — shared with the audio-thread tap (diagnostic:
    /// tap 0 = the mic never delivered; fed 0 with tap >0 = the format conversion failed).
    private var tapCounts: OSAllocatedUnfairLock<(Int, Int)>?

    // MARK: Warm-up (best-effort, called when the hotkey arms so first use is instant)

    static func prewarm() async {
        do {
            try await ensureModelReady()
        } catch {
            Log("voice: prewarm skipped — \(error.localizedDescription)")
        }
    }

    // MARK: Capture

    func start() async throws {
        let clock = ContinuousClock(); let started = clock.now
        try await Self.ensureModelReady()
        try Task.checkCancellation()   // a bailed start (watchdog / tap / Esc) must never open the mic late

        // Let a just-cancelled session finish closing first — a fresh analyzer otherwise queues
        // behind the zombie session inside the speech daemon (field-proven: an Esc mid-capture
        // parked the very next press for 15s).
        await Self.closingSession?.value
        try Task.checkCancellation()

        let transcriber = SpeechTranscriber(locale: await Self.captureLocale(), preset: .transcription)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.modelUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
        self.analyzer = analyzer

        // Collect the finalized phrases as the transcriber publishes them.
        resultsTask = Task {
            var text = AttributedString()
            for try await result in transcriber.results {
                text.append(result.text)
            }
            return String(text.characters)
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation()   // cancelled during the session handoff → never touch the mic

        // Mic → convert to the analyzer's format → stream in. The tap runs on an audio thread and
        // touches only these locals (never the MainActor self), so there's no isolation violation.
        let engine = Self.sharedAudioEngine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw VoiceError.modelUnavailable
        }
        let counts = OSAllocatedUnfairLock(initialState: (0, 0))
        self.tapCounts = counts
        input.removeTap(onBus: 0)   // defensive: a stale tap from an interrupted capture must not linger
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            counts.withLock { $0.0 += 1 }
            guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
            counts.withLock { $0.1 += 1 }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        Log("voice: capture started (\(Self.msLabel(clock.now - started))ms)")
    }

    func stopAndTranscribe() async throws -> String {
        let clock = ContinuousClock(); let started = clock.now
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        let (taps, fed) = tapCounts?.withLock { $0 } ?? (0, 0)

        // No audio ever reached the analyzer (a dead/warming mic): there is nothing to transcribe,
        // and an EMPTY session is exactly the one that parks — its finalize no-ops but its results
        // stream never terminates (field-proven: Esc's resultsTask.cancel unwedged it in 2ms).
        // Close the session immediately and answer honestly.
        if fed == 0 {
            resultsTask?.cancel()
            if let analyzer {
                let previous = Self.closingSession
                Self.closingSession = Task {
                    await previous?.value
                    await analyzer.cancelAndFinishNow()
                }
            }
            teardown()
            Log("voice: finalized (\(Self.msLabel(clock.now - started))ms · tap \(taps) · fed 0 — no audio, session closed)")
            return ""
        }

        // Bounded finalize: it can park inside the speech daemon; cancelAndFinishNow reliably
        // unwedges it, so give the graceful path 5s then force-close. Whatever the results stream
        // produced still comes back below.
        if let analyzer {
            let finalize = Task { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            let bound = Task {
                try await Task.sleep(for: .seconds(5))
                Log("voice: finalize parked — force-closing the session")
                await analyzer.cancelAndFinishNow()
            }
            _ = try? await finalize.value
            bound.cancel()
        }
        // Bounded collection: the results stream is the OTHER half that can refuse to end.
        let transcript: String
        if let resultsTask {
            let bound = Task {
                try await Task.sleep(for: .seconds(2))
                Log("voice: results stream parked — cancelling collection")
                resultsTask.cancel()
            }
            transcript = (try? await resultsTask.value) ?? ""
            bound.cancel()
        } else {
            transcript = ""
        }
        teardown()
        Log("voice: finalized (\(Self.msLabel(clock.now - started))ms · tap \(taps) · fed \(fed))")
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        // Close the analyzer session FOR REAL. Dropping the object leaves a zombie session in the
        // speech daemon that the next capture queues behind; cancelAndFinishNow is the documented
        // immediate stop. Chained on the previous close so rapid bursts stay ordered; start() awaits
        // the latest one.
        if let analyzer {
            let previous = Self.closingSession
            Self.closingSession = Task {
                await previous?.value
                await analyzer.cancelAndFinishNow()
            }
        }
        teardown()
    }

    /// The in-flight teardown of the most recently cancelled session (completed tasks linger —
    /// awaiting one is then free). See cancel().
    private static var closingSession: Task<Void, Never>?

    // MARK: Internals

    private func stopAudio() {
        let engine = Self.sharedAudioEngine
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func teardown() {
        analyzer = nil
        resultsTask = nil
    }

    /// The spoken language: App language preference (or system), resolved against installable
    /// SpeechTranscriber locales. Tries Russian/English regional variants before any English
    /// fallback — never silently stick on en-US when the user asked for Russian.
    private static func resolvedLocale() async -> Locale {
        let preferred = AppLanguage.preferredSpeechLocale
        let app = AppLanguage.stored.rawValue
        let wantRussian = AppLanguage.wantsRussianSpeech
        Log("voice: resolving STT locale (preferred \(preferred.identifier), app language \(app))")

        for candidate in AppLanguage.speechLocaleCandidates {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                Log("voice: STT locale → \(match.identifier) (matched from \(candidate.identifier))")
                return match
            }
        }

        // Scan the full supported list by language code (covers ru_RU vs ru-RU identifier drift).
        let supported = await SpeechTranscriber.supportedLocales
        let targetLang: String? = wantRussian ? "ru"
            : (AppLanguage.stored == .english || preferred.language.languageCode?.identifier == "en"
               ? "en" : preferred.language.languageCode?.identifier)
        if let targetLang,
           let match = supported.first(where: {
               $0.language.languageCode?.identifier == targetLang
           }) {
            Log("voice: STT locale → \(match.identifier) (scanned supportedLocales for \(targetLang); \(supported.count) supported)")
            return match
        }

        // Last chance: an already-installed locale of the right language (downloadable list can lag).
        let installed = await SpeechTranscriber.installedLocales
        if let targetLang,
           let match = installed.first(where: {
               $0.language.languageCode?.identifier == targetLang
           }) {
            Log("voice: STT locale → \(match.identifier) (from installedLocales for \(targetLang))")
            return match
        }

        let supportedIDs = supported.map(\.identifier).joined(separator: ", ")
        if wantRussian {
            Log("voice: ✗ no Russian SpeechTranscriber locale (supported: [\(supportedIDs)]) — will not fall back to en-US")
            return preferred
        }
        Log("voice: ⚠️ preferred STT locale \(preferred.identifier) unsupported (supported: [\(supportedIDs)]); falling back to en-US")
        if let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return en
        }
        return Locale(identifier: "en-US")
    }

    // MARK: Model readiness (memoized · single-flight · shielded from caller cancellation)

    /// Session memo — once the model is verified installed for a locale, start() never touches the
    /// asset daemon again for that locale. Cleared when App language resolves to a different STT locale.
    private static var modelReady = false
    private static var modelReadyLocaleID: String?

    /// The ONE in-flight install. Unstructured on purpose: downloadAndInstall() ignores cooperative
    /// cancellation, so a bailing caller (the 15s watchdog, a tap-to-type, Esc) must never cancel or
    /// duplicate it — "cancelled" installs keep running in the daemon and stack up into the very
    /// contention that parks the next attempt. Clears itself when it finishes, so a failure retries fresh.
    private static var installTask: Task<Void, Error>?

    /// True only while a genuine model download is in flight — the coordinator answers a voice hold
    /// with an honest "still downloading" notice instead of listening into a model that isn't there.
    static var isModelDownloading: Bool { installTask != nil && !modelReady }

    /// Locale whose on-device model passed `ensureModelReady`. Cleared when App language changes or
    /// the cached locale no longer matches the STT preference (e.g. en-US memo after switching to Russian).
    private static func captureLocale() async -> Locale {
        if modelReady, let id = modelReadyLocaleID {
            let ready = Locale(identifier: id)
            if AppLanguage.speechLocaleMatchesPreference(ready) { return ready }
            Log("voice: cached speech model (\(id)) doesn't match App language — clearing memo")
            invalidateModelReady()
        }
        return await resolvedLocale()
    }

    /// Make sure the on-device model is installed. The installed-locales check is the ONLY honest one:
    /// assetInstallationRequest returns a request even when the model is fully installed, so gating on
    /// it (the old code) meant an asset-daemon round-trip on EVERY capture — usually a ~0.1s no-op,
    /// occasionally a 15s+ park, and the park is what wedged Sidekick when the key lifted early.
    private static func ensureModelReady() async throws {
        let preferred = await resolvedLocale()
        for locale in await installLocaleCandidates(anchoredOn: preferred) {
            if try await ensureInstalled(locale) { return }
        }

        guard AppLanguage.allowsEnglishSpeechFallback else {
            await logRussianSpeechDiagnostics(note: "SpeechTranscriber install exhausted")
            Log("voice: ✗ Russian speech model for \(preferred.identifier) isn't ready — refusing en-US capture")
            throw VoiceError.modelUnavailable
        }

        let preferredID = preferred.identifier(.bcp47)
        let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en-US")
        guard en.identifier(.bcp47) != preferredID else { throw VoiceError.modelUnavailable }

        Log("voice: ⚠️ on-device speech model for \(preferred.identifier) isn't installable; trying en-US for capture")
        if try await ensureInstalled(en) { return }
        throw VoiceError.modelUnavailable
    }

    @discardableResult
    private static func ensureInstalled(_ locale: Locale) async throws -> Bool {
        let localeID = locale.identifier(.bcp47)
        if modelReady, modelReadyLocaleID == localeID {
            if await installed(locale) { return true }
            invalidateModelReady()
        }
        if modelReadyLocaleID != localeID { invalidateModelReady() }
        if await installed(locale) {
            markReady(locale)
            return true
        }
        do {
            let task = installTask ?? launchInstall(locale: locale)
            installTask = task
            try await task.value
        } catch {
            Log("voice: model install failed for \(locale.identifier) — \(error.localizedDescription)")
            await logRussianSpeechDiagnostics(note: "install error for \(locale.identifier)")
            return false
        }
        guard await installed(locale) else {
            await logRussianSpeechDiagnostics(note: "not in installedLocales after \(locale.identifier)")
            return false
        }
        markReady(locale)
        return true
    }

    /// Clears the session memo after a failed capture or a vanished on-device model.
    static func invalidateModelReady() {
        modelReady = false
        modelReadyLocaleID = nil
    }

    /// True when the on-device model for this locale (or its language) is installed.
    private static func installed(_ locale: Locale) async -> Bool {
        let target = AppLanguage.normalizedSpeechID(locale)
        let lang = locale.language.languageCode?.identifier
        return await SpeechTranscriber.installedLocales.contains { installed in
            AppLanguage.normalizedSpeechID(installed) == target
                || (lang != nil && installed.language.languageCode?.identifier == lang)
        }
    }

    /// Distinct SpeechTranscriber locales to try for install (BCP-47 drift: ru_RU vs ru-RU vs ru).
    private static func installLocaleCandidates(anchoredOn preferred: Locale) async -> [Locale] {
        var list: [Locale] = []
        var seen = Set<String>()
        let append: (Locale) -> Void = { loc in
            let id = AppLanguage.normalizedSpeechID(loc)
            guard seen.insert(id).inserted else { return }
            list.append(loc)
        }
        append(preferred)
        for candidate in AppLanguage.speechLocaleCandidates {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
                append(match)
            }
        }
        if AppLanguage.wantsRussianSpeech {
            let supported = await SpeechTranscriber.supportedLocales
            for match in supported where match.language.languageCode?.identifier == "ru" {
                append(match)
            }
        }
        return list
    }

    /// Actionable RU diagnostics when SpeechAnalyzer assets fail (supported vs installed vs SFSpeech).
    private static func logRussianSpeechDiagnostics(note: String) async {
        guard AppLanguage.wantsRussianSpeech else { return }
        let supported = await SpeechTranscriber.supportedLocales.filter {
            $0.language.languageCode?.identifier == "ru"
        }
        let installed = await SpeechTranscriber.installedLocales.filter {
            $0.language.languageCode?.identifier == "ru"
        }
        let supportedIDs = supported.map(\.identifier).joined(separator: ", ")
        let installedIDs = installed.isEmpty ? "(none)" : installed.map(\.identifier).joined(separator: ", ")
        var sfAvailable: [String] = []
        for loc in SFSpeechRecognizer.supportedLocales() where loc.language.languageCode?.identifier == "ru" {
            if SFSpeechRecognizer(locale: loc)?.isAvailable == true {
                sfAvailable.append(loc.identifier)
            }
        }
        let sfLine = sfAvailable.isEmpty ? "(none isAvailable)" : sfAvailable.joined(separator: ", ")
        Log("voice: RU STT diagnostics (\(note)) — SpeechTranscriber supported: [\(supportedIDs)]; installed: [\(installedIDs)]; SFSpeech isAvailable: [\(sfLine)]")
    }

    private static func assetStatusLabel(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported: return "unsupported"
        case .supported: return "supported (not installed)"
        case .downloading: return "downloading"
        case .installed: return "installed"
        @unknown default: return "unknown"
        }
    }

    /// The single shared install (a genuine first-run download, or a re-download after an OS purge).
    private static func launchInstall(locale: Locale) -> Task<Void, Error> {
        Task {
            defer { installTask = nil }   // finished either way; markReady records a success
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let before = await AssetInventory.status(forModules: [transcriber])
            Log("voice: asset status for \(locale.identifier) before install — \(assetStatusLabel(before))")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log("voice: downloading the on-device speech model for \(locale.identifier)…")
                do {
                    try await request.downloadAndInstall()
                } catch {
                    let after = await AssetInventory.status(forModules: [transcriber])
                    Log("voice: downloadAndInstall failed for \(locale.identifier) — \(error.localizedDescription); asset status after — \(assetStatusLabel(after))")
                    throw error
                }
            } else {
                let after = await AssetInventory.status(forModules: [transcriber])
                Log("voice: no asset install request for \(locale.identifier) — asset status \(assetStatusLabel(after)); checking installedLocales")
            }
            guard await installed(locale) else {
                let after = await AssetInventory.status(forModules: [transcriber])
                Log("voice: ✗ speech model for \(locale.identifier) not installed after install pass (asset status: \(assetStatusLabel(after)))")
                throw VoiceError.modelUnavailable
            }
            markReady(locale)
        }
    }

    private static func markReady(_ locale: Locale) {
        let localeID = locale.identifier(.bcp47)
        if modelReady, modelReadyLocaleID == localeID { return }
        modelReady = true
        modelReadyLocaleID = localeID
        Log("voice: speech model ready (\(locale.identifier))")
        // Pin the asset so macOS keeps it for us (best-effort; 5 reservation slots per app, we use 1).
        Task { try? await AssetInventory.reserve(locale: locale) }
    }

    /// Whole milliseconds, for the terse capture-timing logs.
    nonisolated private static func msLabel(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Convert one mic buffer to the analyzer's format (sample-rate + layout). Pure → safe off-main.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
