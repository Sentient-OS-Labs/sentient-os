//
//  SpeechAnalyzerEngine.swift
//  Sentient OS macOS
//
//  macOS 26+ speech-to-text via the Speech framework's SpeechAnalyzer + SpeechTranscriber — fully
//  on-device (private AND high-quality), no network, and no temp audio file (the mic stays in memory).
//  Live mic buffers are converted to the analyzer's format and streamed in; on stop we finalize and
//  return the single best transcript. No partials.
//
//  Key methods: prewarm() (install the model ahead of first use) · start() · stopAndTranscribe() · cancel().
//

import Speech
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

    // MARK: Warm-up (best-effort, called when the hotkey arms so first use is instant)

    static func prewarm() async {
        do {
            let transcriber = SpeechTranscriber(locale: await resolvedLocale(), preset: .transcription)
            try await ensureModelInstalled(for: transcriber)
        } catch {
            Log("voice: prewarm skipped — \(error.localizedDescription)")
        }
    }

    // MARK: Capture

    func start() async throws {
        let transcriber = SpeechTranscriber(locale: await Self.resolvedLocale(), preset: .transcription)
        try await Self.ensureModelInstalled(for: transcriber)

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

        // Mic → convert to the analyzer's format → stream in. The tap runs on an audio thread and
        // touches only these locals (never the MainActor self), so there's no isolation violation.
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            throw VoiceError.modelUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopAndTranscribe() async throws -> String {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        let transcript: String
        if let resultsTask {
            transcript = (try? await resultsTask.value) ?? ""
        } else {
            transcript = ""
        }
        teardown()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        teardown()
    }

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

    /// Install the on-device model for the transcriber's locale if it isn't already (a no-op when present).
    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log("voice: downloading on-device speech model…")
            try await request.downloadAndInstall()
        }
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
