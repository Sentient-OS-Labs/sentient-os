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

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Error>?
    private var tapInstalled = false
    private var yieldedBuffers: OSAllocatedUnfairLock<Int>?   // shared with the audio-thread tap (diagnostic)

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

        let transcriber = SpeechTranscriber(locale: await Self.resolvedLocale(), preset: .transcription)
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
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw VoiceError.modelUnavailable
        }
        let yielded = OSAllocatedUnfairLock(initialState: 0)   // buffers fed to the analyzer (diagnostic)
        self.yieldedBuffers = yielded
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
            yielded.withLock { $0 += 1 }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
        Log("voice: capture started (\(Self.msLabel(clock.now - started))ms)")
    }

    func stopAndTranscribe() async throws -> String {
        let clock = ContinuousClock(); let started = clock.now
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        // Bounded finalize: finalizeAndFinishThroughEndOfInput can park indefinitely inside the
        // speech daemon (field-proven 15s+ — and cancelAndFinishNow unwedged it in ~16ms). Give
        // the graceful path 5s, then force-close the session; whatever the results stream already
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
        let transcript: String
        if let resultsTask {
            transcript = (try? await resultsTask.value) ?? ""
        } else {
            transcript = ""
        }
        teardown()
        let buffers = yieldedBuffers?.withLock { $0 } ?? 0
        Log("voice: finalized (\(Self.msLabel(clock.now - started))ms · \(buffers) buffers)")
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
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func teardown() {
        analyzer = nil
        resultsTask = nil
    }

    /// The spoken language: the user's locale if supported by the on-device model, else US English.
    private static func resolvedLocale() async -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return match }
        return Locale(identifier: "en-US")
    }

    // MARK: Model readiness (memoized · single-flight · shielded from caller cancellation)

    /// Session memo — once the model is verified installed, start() never touches the asset daemon again.
    private static var modelReady = false

    /// The ONE in-flight install. Unstructured on purpose: downloadAndInstall() ignores cooperative
    /// cancellation, so a bailing caller (the 15s watchdog, a tap-to-type, Esc) must never cancel or
    /// duplicate it — "cancelled" installs keep running in the daemon and stack up into the very
    /// contention that parks the next attempt. Clears itself when it finishes, so a failure retries fresh.
    private static var installTask: Task<Void, Error>?

    /// True only while a genuine model download is in flight — the coordinator answers a voice hold
    /// with an honest "still downloading" notice instead of listening into a model that isn't there.
    static var isModelDownloading: Bool { installTask != nil && !modelReady }

    /// Make sure the on-device model is installed. The installed-locales check is the ONLY honest one:
    /// assetInstallationRequest returns a request even when the model is fully installed, so gating on
    /// it (the old code) meant an asset-daemon round-trip on EVERY capture — usually a ~0.1s no-op,
    /// occasionally a 15s+ park, and the park is what wedged Sidekick when the key lifted early.
    private static func ensureModelReady() async throws {
        if modelReady { return }
        let locale = await resolvedLocale()
        if await installed(locale) {
            markReady(locale)
            return
        }
        let task = installTask ?? launchInstall(locale: locale)
        installTask = task
        try await task.value
    }

    private static func installed(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// The single shared install (a genuine first-run download, or a re-download after an OS purge).
    private static func launchInstall(locale: Locale) -> Task<Void, Error> {
        Task {
            defer { installTask = nil }   // finished either way; markReady records a success
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log("voice: downloading the on-device speech model…")
                try await request.downloadAndInstall()
            }
            markReady(locale)
        }
    }

    private static func markReady(_ locale: Locale) {
        guard !modelReady else { return }
        modelReady = true
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
