import Foundation
import Observation

@MainActor protocol ComposerVoiceCapture: AnyObject {
    var onTranscript: ((String) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    func start() async throws
    func stopCapturing()
    func stopAndTranscribe() async throws -> String
    func cancel()
}

extension VoiceCapture: ComposerVoiceCapture {}

/// Main-composer dictation edits a draft. Stopping never submits; Send may request
/// submission after the final words arrive. A generation rejects all late callbacks.
@MainActor @Observable final class ComposerDictation {
    enum Stage { case idle, starting, recording, finalizing }
    private(set) var stage = Stage.idle
    private(set) var error: String?
    private(set) var hasTranscript = false
    private(set) var levels = Array(repeating: Float(0), count: 12)
    var isActive: Bool { stage != .idle }
    private let capture: any ComposerVoiceCapture
    private var generation: UUID?
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var update: ((String) -> Void)?
    private var pendingSend: (() -> Void)?
    private var base = ""

    init(capture: (any ComposerVoiceCapture)? = nil) { self.capture = capture ?? VoiceCapture() }

    func start(draft: String, update: @escaping (String) -> Void) {
        guard !isActive else { return }
        let id = UUID(); generation = id
        base = draft; self.update = update; error = nil; stage = .starting
        hasTranscript = false; levels = Array(repeating: 0, count: 12)
        capture.onLevel = { [weak self] value in
            guard let self, self.generation == id else { return }
            self.levels.removeFirst(); self.levels.append(value)
        }
        capture.onTranscript = { [weak self] text in
            guard let self, self.generation == id else { return }
            self.publish(text)
        }
        capture.onFailure = { [weak self] _ in
            guard let self, self.generation == id else { return }
            self.fail("Dictation stopped. Your available words are still in the draft.")
        }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.capture.start()
                guard self.generation == id, self.stage == .starting else { return }
                self.stage = .recording
            } catch {
                guard self.generation == id else { return }
                if error is CancellationError { self.cancel() }
                else { self.fail(error.localizedDescription) }
            }
        }
        limit = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            guard self?.generation == id else { return }
            self?.stop()
        }
    }

    func stop(sendWhenReady: (() -> Void)? = nil) {
        guard let id = generation else { return }
        if let sendWhenReady { pendingSend = sendWhenReady }
        if stage == .finalizing { return }
        capture.stopCapturing() // Close the microphone before any await.
        limit?.cancel(); limit = nil
        if stage == .starting {
            let send = pendingSend
            cancel(); send?()
            return
        }
        stage = .finalizing
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard self?.generation == id else { return }
            self?.fail("Dictation took too long. Your available words are still in the draft.")
        }
        finishTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.capture.stopAndTranscribe()
                guard self.generation == id else { return }
                self.publish(text)
                let send = self.pendingSend
                self.cancel(); send?()
            } catch {
                guard self.generation == id else { return }
                self.fail("Dictation stopped. Your available words are still in the draft.")
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        generation = nil
        capture.cancel()
        startTask?.cancel(); startTask = nil
        finishTask?.cancel(); finishTask = nil
        deadline?.cancel(); deadline = nil
        limit?.cancel(); limit = nil
        pendingSend = nil; update = nil; stage = .idle
    }

    private func publish(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        hasTranscript = true
        let separator = base.isEmpty || base.last?.isWhitespace == true ? "" : " "
        update?(base + separator + transcript)
    }
    private func fail(_ message: String) { cancel(); error = message }
}
