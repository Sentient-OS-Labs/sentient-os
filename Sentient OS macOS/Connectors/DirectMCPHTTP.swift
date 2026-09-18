//
// DirectMCPHTTP.swift
// Bounded, cookie-free HTTPS requests to a provider's pinned origins. Redirects are refused,
// including credential-bearing redirects; discovery and MCP share this one transport.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation

nonisolated enum DirectMCPHTTP {
    struct Response: Sendable { let status: Int; let headers: [String: String]; let body: Data }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    static func request(_ url: URL, provider: DirectMCPProvider, method: String = "GET",
                        headers: [String: String] = [:], body: Data? = nil,
                        limit: Int = 2_000_000, rpcID: Int? = nil) async throws -> Response {
        try provider.validate(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 35
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw DirectMCPError.invalidResponse }
            var fields: [String: String] = [:]
            for (key, value) in response.allHeaderFields { fields[String(describing: key).lowercased()] = String(describing: value) }
            var data = Data()
            let isStream = fields["content-type"]?.lowercased().contains("text/event-stream") == true
            var line = Data(), event = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw DirectMCPError.tooLarge }
                data.append(byte)
                if isStream, let rpcID {
                    if byte == 10 {
                        if line.last == 13 { line.removeLast() }
                        if line.isEmpty, !event.isEmpty {
                            if let object = try? JSONSerialization.jsonObject(with: event) as? [String: Any],
                               object["id"] as? Int == rpcID {
                                return Response(status: response.statusCode, headers: fields, body: event)
                            }
                            event = Data()
                        } else if let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") {
                            if !event.isEmpty { event.append(10) }
                            event.append(Data(text.dropFirst(5).drop(while: { $0 == " " }).utf8))
                        }
                        line = Data()
                    } else { line.append(byte) }
                }
            }
            guard !isStream || rpcID == nil else { throw DirectMCPError.invalidResponse }
            return Response(status: response.statusCode, headers: fields, body: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DirectMCPError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw DirectMCPError.network
        }
    }

    static func object(_ response: Response) throws -> [String: Any] {
        guard (200..<300).contains(response.status) else { throw DirectMCPError.http(response.status) }
        guard let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw DirectMCPError.invalidResponse
        }
        return value
    }
    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func form(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let value = parameters.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
            + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(value.utf8)
    }
}
