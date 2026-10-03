// Bounded HTTP/1.1 framing shared by the local model translator and Claude subscription bridge.
// One request per connection; no forwarding, authentication, or model policy lives here.
// Doc: Documentation - Cloud - Frontier Model Choice (BYOM).md

import Foundation
import Network

nonisolated enum LoopbackHTTP {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    static func read(_ connection: NWConnection, maximumBody: Int = 64 * 1_024 * 1_024,
                     authorize: (@Sendable ([String: String]) -> Bool)? = nil) async throws -> Request {
        let deadline = DispatchWorkItem { connection.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: deadline)
        defer { deadline.cancel() }
        let delimiter = Data("\r\n\r\n".utf8)
        var buffer = Data()
        while buffer.range(of: delimiter) == nil {
            guard buffer.count <= 65_536, let chunk = try await receive(connection), !chunk.isEmpty else {
                throw URLError(.badServerResponse)
            }
            buffer.append(chunk)
        }
        guard let split = buffer.range(of: delimiter), split.lowerBound <= 65_536 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let lines = String(decoding: buffer[..<split.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/") else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw URLError(.badServerResponse)
            }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw URLError(.badServerResponse) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Authenticate before buffering screenshot-sized bodies on private provider endpoints.
        guard authorize?(headers) != false else { throw URLError(.userAuthenticationRequired) }
        guard headers["transfer-encoding"] == nil, headers["content-encoding"] == nil else {
            throw URLError(.cannotDecodeContentData)
        }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let expected = Int(lengthText), expected <= maximumBody else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var body = Data(buffer[split.upperBound...])
        while body.count < expected {
            guard let chunk = try await receive(connection), !chunk.isEmpty else { throw URLError(.networkConnectionLost) }
            body.append(chunk)
        }
        guard body.count == expected else { throw URLError(.badServerResponse) }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(throwing: URLError(.networkConnectionLost)) }
            }
        }
    }

    static func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    static func response(status: Int, contentType: String = "application/json", body: Data = Data()) -> Data {
        Data(("HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n").utf8) + body
    }
}
