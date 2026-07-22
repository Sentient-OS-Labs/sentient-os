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
    private let recognizer = SpeechLocaleResolver.candidates.lazy
        .compactMap { SFSpeechRecognizer(locale: $0) }
        .first ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private var latest = ""                 // the most complete transcription seen so far
    private var finalReceived = false
    private var finalContinuation: CheckedContinuation<String, Never>?

    // MARK: Capture

    func start() async throws {
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.modelUnavailable }

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
    }
}
