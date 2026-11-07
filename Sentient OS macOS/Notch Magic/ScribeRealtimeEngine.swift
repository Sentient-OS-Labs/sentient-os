// One cancellable microphone-to-Scribe session. stopCapturing is synchronous; finalization
// drains already-captured audio and awaits the last committed transcript before returning.
// Doc: Documentation - Sidekick - General.md
import Foundation
@preconcurrency import AVFAudio

@MainActor
final class ScribeRealtimeEngine {
    private var audioEngine: AVAudioEngine?
    private var tapInstalled = false
    private var input: DictationAudio?
    private var conversion: Task<Void, Never>?
    private var sender: Task<String, Error>?
    private var startupDeadline: Task<Void, Never>?
    private var microphoneWatchdog: Task<Void, Never>?
    private var lastAudioAt: TimeInterval = 0
    private var deviceObserver: NSObjectProtocol?
    private let connection = ScribeRealtimeConnection()
    private var stopped = false
    private var cancelled = false
    private var failure: Error?
    var onTranscript: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var transcript: String { connection.transcript.text }

    func start() throws {
        guard !stopped, !cancelled else { throw CancellationError() }
        let input = DictationAudio()
        self.input = input
        let packets = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(80))
        let meter: @Sendable (Float) async -> Void = { [weak self] level in await self?.publishLevel(level) }
        let failed: @Sendable (Error) async -> Void = { [weak self] error in await self?.fail(error) }
        conversion = Task.detached {
            await DictationAudio.convert(input.buffers, into: packets.continuation, failure: failed, meter: meter)
        }
        connection.onTranscript = { [weak self] text in self?.onTranscript?(text) }
        connection.onFailure = { [weak self] error in self?.fail(error) }
        let (engine, format) = try MicrophoneEngine.acquire()
        audioEngine = engine
        do {
            engine.prepare()
            try MicrophoneEngine.installTap(on: engine.inputNode, format: format) { buffer in input.append(buffer) }
            tapInstalled = true
            try engine.start()
        } catch {
            MicrophoneEngine.markDirty(); cancel(); throw error
        }
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.fail(VoiceError.deviceChanged)
                }
            }
        lastAudioAt = ProcessInfo.processInfo.systemUptime
        microphoneWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastAudioAt > 3 {
                    self.fail(VoiceError.noMicrophone)
                    return
                }
            }
        }
        // Bounds token retrieval + handshake together, including an identity refresh stall.
        startupDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.fail(DictationFailure.timedOut)
        }
        sender = Task { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let token = try await HostedInferenceClient.shared.dictationToken()
                try Task.checkCancellation()
                try await connection.connect(token: token.token, zeroRetention: token.zeroRetention)
                startupDeadline?.cancel(); startupDeadline = nil
                onReady?()
                var segmentBytes = 0
                for try await packet in packets.stream {
                    try Task.checkCancellation()
                    try await connection.send(packet)
                    segmentBytes += packet.count
                    if segmentBytes >= 640_000 { // 20 s, below Scribe's automatic commit boundary
                        try await connection.commit()
                        segmentBytes = 0
                    }
                }
                if segmentBytes > 0 {
                    // Scribe starts processing after 2 seconds. Pad short final segments with
                    // synthetic silence, never by leaving the microphone open after release.
                    if segmentBytes < 64_000 {
                        var padding = 64_000 - segmentBytes
                        while padding > 0 {
                            let count = min(padding, 3200)
                            try await connection.send(Data(repeating: 0, count: count))
                            padding -= count
                        }
                    }
                    try await connection.commit()
                }
                try Task.checkCancellation()
                let text = connection.transcript.committed
                connection.close()
                return text
            } catch {
                if !cancelled { fail(error) }
                throw failure ?? error
            }
        }
    }
    private func publishLevel(_ level: Float) {
        guard !stopped, !cancelled else { return }
        lastAudioAt = ProcessInfo.processInfo.systemUptime
        onLevel?(level)
    }
    func stopCapturing() {
        guard !stopped else { return }
        stopped = true
        microphoneWatchdog?.cancel(); microphoneWatchdog = nil
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver); self.deviceObserver = nil }
        if let audioEngine { MicrophoneEngine.stop(audioEngine, tapInstalled: tapInstalled) }
        audioEngine = nil; tapInstalled = false
        input?.finish()
        onLevel?(0)
    }
    func finish() async throws -> String {
        stopCapturing()
        if let failure { throw failure }
        guard let sender else { return "" }
        return try await sender.value
    }
    private func fail(_ error: Error) {
        guard failure == nil, !cancelled else { return }
        failure = error
        stopCapturing()
        input?.finish(error)
        conversion?.cancel()
        startupDeadline?.cancel()
        connection.close()
        sender?.cancel()
        onFailure?(error)
    }
    func cancel() {
        cancelled = true
        stopCapturing()
        conversion?.cancel(); conversion = nil
        sender?.cancel(); sender = nil
        startupDeadline?.cancel(); startupDeadline = nil
        connection.close()
        input = nil
    }
}
