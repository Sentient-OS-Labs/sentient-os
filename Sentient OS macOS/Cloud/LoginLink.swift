// Validates automatic OAuth links and reads Codex's login output without logging it.
// Decoder handles split writes and bounds retained output; authorizationURL rejects manual links.
// Doc: Documentation - Cloud - Codex Setup.md

import Foundation

nonisolated enum LoginLink {
    enum Provider { case chatgpt, claude }
    static let maximumBytes = 8_192

    /// Preserve the CLI's URL verbatim, including state and PKCE. Only a loopback return
    /// address can finish the existing browser login without asking for a pasted code.
    static func authorizationURL(_ text: String, provider: Provider) -> URL? {
        guard text.utf8.count <= maximumBytes,
              let url = URL(string: text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return nil }
        let endpoint = (parts.host ?? "") + parts.path
        switch provider {
        case .chatgpt:
            guard endpoint == "auth.openai.com/oauth/authorize" else { return nil }
        case .claude:
            guard ["claude.com/cai/oauth/authorize", "claude.ai/oauth/authorize",
                   "platform.claude.com/oauth/authorize", "console.anthropic.com/oauth/authorize"]
                .contains(endpoint) else { return nil }
        }
        func value(_ name: String) -> String? {
            let items = (parts.queryItems ?? []).filter { $0.name == name }
            guard items.count == 1, let value = items[0].value, !value.isEmpty else { return nil }
            return value
        }
        guard value("state") != nil, value("code_challenge") != nil, value("client_id") != nil,
              value("response_type") == "code", value("code_challenge_method") == "S256",
              let redirect = value("redirect_uri"), let callback = URLComponents(string: redirect),
              callback.scheme == "http", ["localhost", "127.0.0.1", "[::1]"].contains(callback.host ?? ""),
              let port = callback.port, (1...65535).contains(port),
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              callback.path == (provider == .chatgpt ? "/auth/callback" : "/callback") else { return nil }
        return url
    }

    struct Decoder {
        let provider: Provider
        private var buffer = Data()
        private var droppingLine = false
        private var delivered = false

        init(provider: Provider) { self.provider = provider }

        mutating func append(_ data: Data, endOfFile: Bool = false) -> URL? {
            guard !delivered else { return nil }
            // Process bytes so even a very long unterminated diagnostic cannot grow the buffer.
            for byte in data {
                if byte == 10 || byte == 13 {
                    if let url = finishLine() { return url }
                } else if !droppingLine {
                    if buffer.count < LoginLink.maximumBytes { buffer.append(byte) }
                    else { buffer.removeAll(keepingCapacity: true); droppingLine = true }
                }
            }
            return endOfFile ? finishLine() : nil
        }

        private mutating func finishLine() -> URL? {
            defer { buffer.removeAll(keepingCapacity: true); droppingLine = false }
            guard !droppingLine else { return nil }
            let line = String(decoding: buffer, as: UTF8.self)
            for token in line.split(whereSeparator: { $0.isWhitespace || $0.asciiValue == 27 || $0.asciiValue == 7 }) {
                if let url = LoginLink.authorizationURL(String(token), provider: provider) {
                    delivered = true
                    return url
                }
            }
            return nil
        }
    }

    /// Start only after Process.run succeeds, so a failed launch cannot strand a reader.
    static func read(_ pipe: Pipe, onURL: @escaping @Sendable (URL) -> Void) {
        try? pipe.fileHandleForWriting.close()
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            defer { try? handle.close() }
            var decoder = Decoder(provider: .chatgpt)
            while true {
                let data = handle.availableData
                if let url = decoder.append(data, endOfFile: data.isEmpty) { onURL(url) }
                if data.isEmpty { return }
            }
        }
    }
}
