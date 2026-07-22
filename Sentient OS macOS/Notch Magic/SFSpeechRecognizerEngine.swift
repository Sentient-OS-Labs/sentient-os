//
//  SFSpeechRecognizerEngine.swift
//  Sentient OS macOS
//
//  macOS 15 fallback speech-to-text via the classic Speech framework (SFSpeechRecognizer +
//  SFSpeechAudioBufferRecognitionRequest). Used only when SpeechAnalyzer (macOS 26+) isn't available.
//  Left server-capable by default for highest quality (Apple's API — our deliberate call, not forced
//  on-device), and it hard-caps audio at ~1 minute, so the hold is capped at 59s upstream.
//
//  Key methods: start() · stopAndTranscribe() · cancel().
//

import Speech
@preconcurrency import AVFAudio

final class SFSpeechRecognizerEngine: QuickTranscriptionEngine {
    /// SFSpeechRecognizer refuses audio longer than ~1 minute — stop a hair under.
    static let maxUtteranceDuration: TimeInterval = 59

    private let audioEngine = AVAudioEngine()
    /// Resolved at start() from App language (not at init) so a mid-session language change is honored.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private var latest = ""                 // the most complete transcription seen so far
    private var finalReceived = false
    private var finalContinuation: CheckedContinuation<String, Never>?

    // MARK: Capture

    func start() async throws {
        let recognizer = Self.makeRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.modelUnavailable }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true   // not shown — they just keep `latest` current for the stop
        request.addsPunctuation = true
        self.request = request

        // Mic → the recognition request. The tap runs on an audio thread and touches only the captured
        // `request` local (never the MainActor self), so there's no isolation violation.
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Pull out value types here (off-main), then hop only those onto the actor.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    func stopAndTranscribe() async throws -> String {
        stopAudio()
        request?.endAudio()
        let transcript = await waitForFinal()
        teardown()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        resumeFinal()        // unblock any awaiter with whatever we have
        teardown()
    }

    // MARK: Locale

    /// Whether Dictation / classic Speech can capture Russian when SpeechAnalyzer on-device assets fail.
    static func russianRecognizerIsAvailable() -> Bool {
        guard AppLanguage.wantsRussianSpeech else { return false }
        return makeRecognizer() != nil
    }

    /// Pick an SFSpeechRecognizer for App language — try regional variants, then scan
    /// `supportedLocales()`, before any default (system) recognizer. Logs clearly on fallback.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let preferred = AppLanguage.preferredSpeechLocale
        let app = AppLanguage.stored.rawValue
        let wantRussian = AppLanguage.wantsRussianSpeech
        Log("voice: SFSpeech resolving locale (preferred \(preferred.identifier), app language \(app))")

        for candidate in AppLanguage.speechLocaleCandidates {
            guard let recognizer = SFSpeechRecognizer(locale: candidate), recognizer.isAvailable else { continue }
            Log("voice: SFSpeech locale → \(candidate.identifier) (isAvailable=true)")
            return recognizer
        }

        let supported = SFSpeechRecognizer.supportedLocales()
        let targetLang: String? = wantRussian ? "ru"
            : (AppLanguage.stored == .english || preferred.language.languageCode?.identifier == "en"
               ? "en" : preferred.language.languageCode?.identifier)
        if let targetLang,
           let match = supported.first(where: {
               $0.language.languageCode?.identifier == targetLang
           }),
           let recognizer = SFSpeechRecognizer(locale: match),
           recognizer.isAvailable {
            Log("voice: SFSpeech locale → \(match.identifier) (scanned supportedLocales for \(targetLang))")
            return recognizer
        }

        let supportedIDs = supported.map(\.identifier).joined(separator: ", ")
        if wantRussian {
            Log("voice: ✗ no available Russian SFSpeechRecognizer (supported: [\(supportedIDs)]) — refusing English fallback")
            return nil
        }
        Log("voice: ⚠️ preferred SFSpeech locale \(preferred.identifier) unavailable (supported: [\(supportedIDs)]); trying English")
        for candidate in [Locale(identifier: "en-US"), Locale(identifier: "en-GB"), Locale(identifier: "en")] {
            guard let recognizer = SFSpeechRecognizer(locale: candidate), recognizer.isAvailable else { continue }
            Log("voice: SFSpeech locale → \(candidate.identifier) (English fallback)")
            return recognizer
        }
        if let recognizer = SFSpeechRecognizer(), recognizer.isAvailable {
            Log("voice: SFSpeech locale → system default (isAvailable=true)")
            return recognizer
        }
        return nil
    }

    // MARK: Internals

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty { latest = text }
        if isFinal || failed {
            finalReceived = true
            resumeFinal()
        }
    }

    /// Wait for the recognizer's final result after endAudio(), with a safety timeout so we never hang.
    private func waitForFinal() async -> String {
        if finalReceived || task == nil { return latest }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            finalContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.resumeFinal()
            }
        }
    }

    private func resumeFinal() {
        guard let continuation = finalContinuation else { return }
        finalContinuation = nil
        continuation.resume(returning: latest)
    }

    private func stopAudio() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func teardown() {
        task = nil
        request = nil
        recognizer = nil
    }
}
