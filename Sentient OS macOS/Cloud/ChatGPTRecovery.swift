import Foundation

/// Classify a terminal provider rejection. Tool results and successful runs never enter here.
nonisolated enum ChatGPTProviderFailure {
    case modelUnavailable, loginRequired

    static func classify(_ error: Error) -> Self? {
        guard case let CodexCLI.CLIError.exitFailure(_, detail) = error else { return nil }
        return classify(detail: detail)
    }

    static func classify(detail: String) -> Self? {
        let text = detail.lowercased()
        if text.contains("model_not_found") || text.contains("model_not_available")
            || (text.contains("model") && text.contains("not supported when using codex with a chatgpt account")) {
            return .modelUnavailable
        }
        if text.contains("workspace routing discovery unauthorized")
            || (text.contains("401") && (text.contains("unauthorized") || text.contains("authentication_error"))) {
            return .loginRequired
        }
        return nil
    }

    /// Only a rejected start can be replayed automatically. Any item, unknown event or
    /// unstructured output may describe work already performed and prevents automatic replay.
    static func rejectedBeforeWork(_ result: CodexCLI.ExecResult) -> Bool {
        guard result.status != 0 else { return false }
        var rejection = false
        for line in result.stdout.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { return false }
            switch type {
            case "thread.started", "turn.started": break
            case "error", "turn.failed":
                if classify(detail: String(line)) == .modelUnavailable { rejection = true }
            default: return false
            }
        }
        return rejection
    }
}

extension CodexCLI {
    /// Use the real request as the compatibility check, with at most one fallback.
    static func withModelFallback(args: [String], timeout: TimeInterval,
                                  onFallback: @Sendable () -> Void = {},
                                  operation: ([String], TimeInterval) async throws -> ExecResult) async throws -> ExecResult {
        let account = CodexRuntime.accountIdentity
        let began = ProcessInfo.processInfo.systemUptime
        let result = try await operation(args, timeout)
        guard ModelBackend.current == .chatgpt,
              let index = args.firstIndex(of: "-m"), args.indices.contains(index + 1),
              args[index + 1] != Model.gpt6luna.rawValue,
              ChatGPTProviderFailure.rejectedBeforeWork(result) else { return result }
        try Task.checkCancellation()
        guard account == CodexRuntime.accountIdentity else { return result }
        let remaining = timeout > 0 ? timeout - (ProcessInfo.processInfo.systemUptime - began) : timeout
        guard timeout <= 0 || remaining > 0 else { return result }
        CodexAuth.useLunaAfterRejection(account: account)
        var fallback = args
        fallback[index + 1] = Model.gpt6luna.rawValue
        // Free accounts use normal service; preserve every other invocation option.
        if let tier = fallback.firstIndex(where: { $0.hasPrefix("service_tier=") }),
           tier > 0, fallback[tier - 1] == "-c" {
            fallback.removeSubrange((tier - 1)...tier)
        }
        onFallback()
        return try await operation(fallback, remaining)
    }
}
