// Ordered Scribe WebSocket transport. Partial text replaces the current segment; commits
// are acknowledged before another segment is sent. No audio or credential logging.
// Doc: Documentation - Sidekick - General.md
import Foundation

nonisolated enum DictationFailure: LocalizedError, Sendable {
    case unavailable, disconnected, timedOut, overloaded, invalidResponse, retentionUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Dictation isn’t available right now. Try again in a moment."
        case .disconnected: "Dictation lost its connection. Your available text has been kept."
        case .timedOut: "Dictation took too long. Your available text has been kept."
        case .overloaded: "Dictation couldn’t keep up with the audio. Please try again."
        case .invalidResponse: "Dictation couldn’t finish reliably. Your available text has been kept."
        case .retentionUnavailable: "The configured voice privacy setting is unavailable."
        }
    }
}

nonisolated struct ScribeTranscript: Sendable {
    private(set) var committed = ""
    private(set) var partial = ""
    var text: String { [committed, partial].filter { !$0.isEmpty }.joined(separator: " ") }
    mutating func update(_ text: String, committed isCommitted: Bool) throws {
        guard text.utf8.count <= 32_768, committed.utf8.count + text.utf8.count <= 131_072 else {
            throw DictationFailure.invalidResponse
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCommitted {
            if !value.isEmpty { committed = [committed, value].filter { !$0.isEmpty }.joined(separator: " ") }
            partial = ""
        } else { partial = value }
    }
}

@MainActor
final class ScribeRealtimeConnection {
    private var endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    init() {}
    #if DEBUG
    /// Loopback-only synthetic WebSocket fixture. Never configured by preferences or network data.
    init(testEndpoint: URL) {
        precondition(testEndpoint.scheme == "ws" && testEndpoint.host == "127.0.0.1")
        endpoint = testEndpoint
    }
    #endif
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiver: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var commitWaiter: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var ready = false
    private var zeroRetention = false
    private(set) var transcript = ScribeTranscript()
    var onTranscript: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?

    func connect(token: String, zeroRetention: Bool) async throws {
        try Task.checkCancellation()
        self.zeroRetention = zeroRetention
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "language_code", value: Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"),
            URLQueryItem(name: "enable_logging", value: zeroRetention ? "false" : "true")]
        url.queryItems! += [
            "summarise", "summarize", "proofread", "sentient os", "sentient", "jesai",
            "take over", "finish this for me", "proofread this", "summarize this", "summarise this", "reply", "reply to this", "Magic Reply", "Sidekick", "Double Tap"
        ].map { URLQueryItem(name: "keyterms", value: $0) }
        // A token is opaque. Preserve literal '+' with servers that parse form-style queries.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: ScribeRedirectPolicy(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url.url!)
        socket.maximumMessageSize = 131_072
        self.socket = socket
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    try self?.receive(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error is DictationFailure ? error : DictationFailure.disconnected)
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiter = continuation
                armDeadline()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
        try Task.checkCancellation()
    }

    /// One caller sends packets sequentially, with at most 20 seconds between commits.
    func send(_ pcm: Data, commit: Bool = false) async throws {
        if let failure { throw failure }
        guard ready, let socket else { throw DictationFailure.disconnected }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(AudioChunk(audio_base_64: pcm.base64EncodedString(), commit: commit))
        do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
        catch { throw DictationFailure.disconnected }
    }

    func commit() async throws {
        if let failure { throw failure }
        guard ready, commitWaiter == nil else { throw DictationFailure.invalidResponse }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                commitWaiter = continuation
                armDeadline()
                Task { [weak self] in
                    do { try await self?.send(Data(), commit: true) }
                    catch { self?.fail(error) }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
        try Task.checkCancellation()
    }

    private struct AudioChunk: Encodable {
        let message_type = "input_audio_chunk"
        let audio_base_64: String
        let sample_rate = 16000
        let commit: Bool
    }
    private struct Event: Decodable {
        let message_type: String
        let text: String?
    }
    private func receive(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: throw DictationFailure.invalidResponse
        }
        guard data.count <= 131_072, let event = try? JSONDecoder().decode(Event.self, from: data) else {
            throw DictationFailure.invalidResponse
        }
        switch event.message_type {
        case "session_started":
            guard !ready, readyWaiter != nil else { throw DictationFailure.invalidResponse }
            ready = true; deadline?.cancel()
            readyWaiter?.resume(); readyWaiter = nil
        case "partial_transcript":
            guard ready, let text = event.text else { throw DictationFailure.invalidResponse }
            try transcript.update(text, committed: false)
            onTranscript?(transcript.text)
        case "committed_transcript":
            // Committing every 20 seconds avoids Scribe's ~36-second automatic boundary.
            // An unsolicited/duplicate commit cannot accidentally finish a later segment.
            guard ready, let text = event.text, commitWaiter != nil else { throw DictationFailure.invalidResponse }
            try transcript.update(text, committed: true)
            onTranscript?(transcript.text)
            deadline?.cancel()
            commitWaiter?.resume(); commitWaiter = nil
        case "warning":
            if zeroRetention { throw DictationFailure.retentionUnavailable }
        default:
            // Provider errors may contain private payloads. Surface only fixed app-owned text.
            throw DictationFailure.unavailable
        }
    }
    private func armDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.fail(DictationFailure.timedOut)
        }
    }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        releaseWaiters(error)
        onFailure?(error)
        close()
    }
    private func releaseWaiters(_ error: Error) {
        readyWaiter?.resume(throwing: error); readyWaiter = nil
        commitWaiter?.resume(throwing: error); commitWaiter = nil
    }
    func close() {
        failure = failure ?? CancellationError()
        releaseWaiters(failure!)
        deadline?.cancel(); deadline = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }
}

private final class ScribeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
