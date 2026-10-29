// Builds the isolated API-funded Claude child configuration from an admitted hosted run.
// Subscription credentials, profile, model policy and logs never supply hosted inference.
// Doc: Documentation - Cloud - ClaudeCLI (the claude -p engine).md

import Foundation

nonisolated enum HostedClaudeRuntime {
    enum Failure: LocalizedError {
        case runRequired, invalidConfiguration, unsafeProfile
        var errorDescription: String? {
            switch self {
            case .runRequired: "Sentient hosted inference needs an active usage allowance. Try again."
            case .invalidConfiguration: "Sentient hosted inference configuration is unavailable."
            case .unsafeProfile: "Sentient could not prepare its private inference profile."
            }
        }
    }

    /// A stable private profile retains resumable background sessions without reading ~/.claude.
    static var profileDirectory: URL { URL.sentientSupport.appendingPathComponent("Hosted Claude", isDirectory: true) }

    static func model() throws -> String {
        guard let run = HostedInference.currentRun else { throw Failure.runRequired }
        guard validModel(run.model) else { throw Failure.invalidConfiguration }
        return run.model
    }

    static func validModel(_ model: String) -> Bool {
        !model.isEmpty && model.utf8.count <= 128
            && model.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:").contains($0) }
    }

    /// The native executor gets GUI/session routing, never inherited inference credentials.
    /// Explicit local relay capabilities are merged by the caller only after this filter.
    static func executorEnvironment(_ inherited: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG",
                                    "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "XPC_SERVICE_NAME", "XPC_FLAGS"]
        return inherited.filter { allowed.contains($0.key) }
    }

    static func environment() throws -> [String: String] {
        guard let run = HostedInference.currentRun else { throw Failure.runRequired }
        return try environment(gatewayURL: run.gatewayURL, token: run.token, model: run.model, profile: profileDirectory, maxOutputTokens: run.maximumOutputTokens)
    }

    /// Pure input validation plus private-directory preparation; never writes a credential file.
    static func environment(gatewayURL: URL, token: String, model: String, profile: URL, maxOutputTokens: Int = 8_192) throws -> [String: String] {
        let loopback = ["127.0.0.1", "localhost", "[::1]", "::1"].contains(gatewayURL.host ?? "")
        guard gatewayURL.scheme == "https" || (gatewayURL.scheme == "http" && loopback),
              gatewayURL.host?.isEmpty == false, gatewayURL.user == nil, gatewayURL.password == nil,
              gatewayURL.query == nil, gatewayURL.fragment == nil,
              !token.isEmpty, token.utf8.count <= 16_384,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              validModel(model), (1...65_536).contains(maxOutputTokens), profile.isFileURL else { throw Failure.invalidConfiguration }
        let fm = FileManager.default
        if fm.fileExists(atPath: profile.path) {
            let values = try profile.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw Failure.unsafeProfile }
        } else {
            try fm.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
        return [
            "ANTHROPIC_BASE_URL": gatewayURL.absoluteString,
            // --bare accepts API-key auth only; this is the scoped gateway token, never the provider key.
            "ANTHROPIC_AUTH_TOKEN": "",
            "ANTHROPIC_API_KEY": token,
            "CLAUDE_CODE_OAUTH_TOKEN": "",
            "CLAUDE_CONFIG_DIR": profile.path,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
            "CLAUDE_CODE_SUBAGENT_MODEL": model,
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": String(maxOutputTokens),
            "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "ENABLE_TOOL_SEARCH": "false"
        ]
    }
}
