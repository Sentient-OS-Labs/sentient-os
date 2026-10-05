//
//  SFSpeechRecognizerEngine.swift
//  Sentient OS macOS
//
//  macOS 15 fallback speech-to-text via the classic Speech framework (SFSpeechRecognizer +
//  SFSpeechAudioBufferRecognitionRequest). Used only when SpeechAnalyzer (macOS 26+) isn't available.
//  Requests on-device recognition when the recognizer supports it; otherwise uses Apple’s service.
//  Audio is capped at 59s upstream (CommandCoordinator.startListening).
//
//  Key methods: start() · stopAndTranscribe() · cancel().
//

@preconcurrency import Speech
@preconcurrency import AVFAudio

final class SFSpeechRecognizerEngine: QuickTranscriptionEngine {
    /// SFSpeechRecognizer refuses audio longer than ~1 minute — stop a hair under.
    static let maxUtteranceDuration: TimeInterval = 59

    /// The instance of the shared microphone engine (MicrophoneEngine) this capture tapped.
    private var audioEngine: AVAudioEngine?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
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
        // Keep audio on this Mac whenever Apple's recognizer supports local recognition.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true   // not shown — they just keep `latest` current for the stop
        request.addsPunctuation = true
        self.request = request

        // Mic → the recognition request. The engine + tap format come from MicrophoneEngine (rebuilt
        // when the input device changed). The tap runs on an audio thread and touches only the
        // captured `request` local (never the MainActor self), so there's no isolation violation.
        let (engine, format) = try MicrophoneEngine.acquire()
        audioEngine = engine
        do {
            engine.prepare()
            try MicrophoneEngine.installTap(on: engine.inputNode, format: format) { buffer in
                request.append(buffer)
            }
            tapInstalled = true
            try engine.start()
        } catch {
            MicrophoneEngine.markDirty()
            throw error
        }

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
        guard let engine = audioEngine else { return }
        MicrophoneEngine.stop(engine, tapInstalled: tapInstalled)
        tapInstalled = false
        audioEngine = nil
    }

    private func teardown() {
        task = nil
        request = nil
    }
}
