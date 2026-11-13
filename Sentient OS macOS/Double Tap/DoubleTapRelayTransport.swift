// TCP transport for the covered reply relay. CFNetwork's HTTP/3 uploads can stall
// with repeated QUIC loss probes even on a fresh URLSession. The system curl uses
// HTTP/2 over TLS here, with the shared process runner owning cancellation/deadlines.
import Foundation
import Synchronization
import CFNetwork

nonisolated enum DoubleTapRelayTransport {
    struct Response {
        let http: HTTPURLResponse
        let body: String
        let firstText: TimeInterval?
    }

    static func canUseHTTP2(for request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https",
              let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        // URLSession owns system proxy discovery, PAC scripts and proxy authentication.
        return proxies.allSatisfy { $0[kCFProxyTypeKey as String] as? String == kCFProxyTypeNone as String }
    }

    static func response(for request: URLRequest, started: Date) async throws -> Response {
        guard let url = request.url, url.scheme == "https", let body = request.httpBody else {
            throw URLError(.badURL)
        }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentient-reply-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloadURL = directory.appendingPathComponent("request")
        let headersURL = directory.appendingPathComponent("headers")
        let responseHeadersURL = directory.appendingPathComponent("response-headers")
        try body.write(to: payloadURL)
        let headers = (request.allHTTPHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        try headers.write(to: headersURL, atomically: false, encoding: .utf8)

        let firstText = Mutex<TimeInterval?>(nil)
        let result = try await CodexCLI.executeAsync(binary: "/usr/bin/curl", args: [
            "-q", "--http2", "--proto", "=https", "--silent", "--show-error", "--no-buffer",
            "--connect-timeout", "8", "--max-time", "25", "--max-filesize", "1048576",
            "--header", "@" + headersURL.path, "--data-binary", "@" + payloadURL.path,
            "--dump-header", responseHeadersURL.path, "--url", url.absoluteString
        ], stdinText: nil, cwd: nil, timeout: 26, includeCustomProviderKey: false,
        onStdoutLine: { line in
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "response.output_text.delta",
                  let delta = event["delta"] as? String, !delta.isEmpty else { return }
            firstText.withLock { if $0 == nil { $0 = Date().timeIntervalSince(started) } }
        })
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw URLError(result.status == 28 ? .timedOut : .networkConnectionLost)
        }
        let rawHeaders = try String(contentsOf: responseHeadersURL, encoding: .utf8)
        let http = try parseHeaders(rawHeaders, url: url)
        return Response(http: http, body: result.stdout, firstText: firstText.withLock { $0 })
    }

    /// Keep the final response if a proxy or server emitted an interim header block.
    static func parseHeaders(_ raw: String, url: URL) throws -> HTTPURLResponse {
        var status = 0
        var fields: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            if line.hasPrefix("HTTP/") {
                status = line.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                fields.removeAll()
            } else if let colon = line.firstIndex(of: ":") {
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard (100...599).contains(status),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: fields) else {
            throw URLError(.badServerResponse)
        }
        return response
    }
}
