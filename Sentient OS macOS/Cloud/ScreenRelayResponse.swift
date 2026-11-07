// Shared bounded Responses SSE transport for the screen-summary and text-proofreading routes.
// Keeps network sessions ephemeral and accepts only a complete terminal model response.
// Doc: ../Summarize/Documentation - Summarize.md and ../Proofread/Documentation - Proofread.md
import Foundation

nonisolated enum ScreenRelayResponse {
    enum Failure: Error, Equatable { case invalidResponse, incomplete, empty, http(Int) }

    static func text(for request: URLRequest, maximumTextBytes: Int = 32_000,
                     onResponse: (@MainActor @Sendable (HTTPURLResponse) -> Void)? = nil,
                     onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        guard http.value(forHTTPHeaderField: "content-type")?.hasPrefix("text/event-stream") == true else { throw Failure.invalidResponse }
        await onResponse?(http)
        var parser = ResponsesTextStream(maximumTextBytes: maximumTextBytes, maximumEventBytes: maximumTextBytes > 32_000 ? 512_000 : 128_000)
        var publishedAt = ContinuousClock.now
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                if let update = try parser.push(byte), publishedAt.duration(to: .now) >= .milliseconds(65) || parser.completed {
                    await onText(update); publishedAt = .now
                }
                if parser.completed { break }
            }
            let text = try parser.finish()
            await onText(text)
            return text
        } catch {
            if !Task.isCancelled, !parser.text.isEmpty { await onText(parser.text) }
            throw error
        }
    }
}

/// Incremental UTF-8 SSE framing, including CRLF, multiline data, comments and arbitrary chunks.
/// Caps framing and output before allocation can grow with a malformed upstream stream.
nonisolated struct ResponsesTextStream {
    let maximumTextBytes: Int
    let maximumEventBytes: Int
    init(maximumTextBytes: Int = 32_000, maximumEventBytes: Int = 128_000) {
        self.maximumTextBytes = maximumTextBytes; self.maximumEventBytes = maximumEventBytes
    }
    private var line = Data()
    private var data = Data()
    private var total = 0
    private(set) var text = ""
    private(set) var completed = false

    mutating func push(_ byte: UInt8) throws -> String? {
        guard !completed else { return nil }
        total += 1
        guard total <= 1_000_000, line.count < maximumEventBytes else { throw ScreenRelayResponse.Failure.invalidResponse }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return try event() }
        let prefix = Data("data:".utf8)
        if line.starts(with: prefix) {
            var value = line.dropFirst(prefix.count)
            if value.first == 32 { value = value.dropFirst() }
            guard data.count + value.count < maximumEventBytes else { throw ScreenRelayResponse.Failure.invalidResponse }
            if !data.isEmpty { data.append(10) }
            data.append(contentsOf: value)
        }
        return nil
    }

    private mutating func event() throws -> String? {
        guard !data.isEmpty else { return nil }
        defer { data.removeAll(keepingCapacity: true) }
        if data == Data("[DONE]".utf8) { return nil }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw ScreenRelayResponse.Failure.invalidResponse }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event["delta"] as? String, text.utf8.count + delta.utf8.count <= maximumTextBytes else {
                throw ScreenRelayResponse.Failure.invalidResponse
            }
            text += delta
            return text
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed",
                  let output = response["output"] as? [[String: Any]] else { throw ScreenRelayResponse.Failure.invalidResponse }
            let final = output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .compactMap { part -> String? in
                    switch part["type"] as? String {
                    case "output_text": return part["text"] as? String
                    case "refusal": return part["refusal"] as? String
                    default: return nil
                    }
                }.joined(separator: "\n\n")
            guard final.utf8.count <= maximumTextBytes else { throw ScreenRelayResponse.Failure.invalidResponse }
            text = final.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ScreenRelayResponse.Failure.empty }
            completed = true
            return text
        case "error", "response.failed", "response.incomplete": throw ScreenRelayResponse.Failure.incomplete
        default: return nil
        }
    }

    mutating func finish() throws -> String {
        guard completed else { throw ScreenRelayResponse.Failure.incomplete }
        return text
    }
}
