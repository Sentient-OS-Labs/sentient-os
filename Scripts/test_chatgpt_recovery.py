#!/usr/bin/env python3
"""Exercise production model policy and retry behavior with isolated preferences and fake responses."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
source = (APP / 'Cloud/CodexAuth.swift').read_text()
policy = source[source.index('    static func isLimited()'):source.index('    /// Extract `chatgpt_plan_type`')]
fixture = r'''
import Foundation
nonisolated enum ModelBackend { case chatgpt, claude, custom; static var current: Self = .chatgpt }
nonisolated enum CodexRuntime { static var accountIdentity: String? = "account-a" }
nonisolated enum CodexCLI {
    enum Model: String { case gpt6luna = "gpt-6-luna" }
    enum CLIError: Error { case exitFailure(code: Int32, message: String) }
    struct ExecResult { let status: Int32; let stdout: String; let stderr: String }
}
nonisolated enum CodexAuth {
    struct Plan { let raw: String; var tier: Tier { ["free", "go"].contains(raw.lowercased()) ? .limited : .full } }
    enum Tier { case full, limited }
    static var plan: Plan?
    static func currentPlan() -> Plan? { plan }
    static let assertedPlusKey = "plan.assertedPlus"
    static let earliestRefreshKey = "plan.earliestRefresh"
    static let defaults = UserDefaults(suiteName: UUID().uuidString)!
    // POLICY
}
'''.replace('// POLICY', policy.replace('UserDefaults.standard', 'defaults'))
tests = r'''
@main struct Tests {
    static var count = 0
    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label); count += 1
    }
    static func main() async throws {
        check(CodexAuth.usesLuna, "missing plan uses Luna")
        CodexAuth.defaults.set(true, forKey: CodexAuth.assertedPlusKey)
        check(CodexAuth.usesLuna, "legacy upgrade flag does not change automatic selection")
        CodexAuth.plan = .init(raw: "  ")
        check(CodexAuth.usesLuna, "blank plan uses Luna")
        for raw in ["free", "go", "FREE"] {
            CodexAuth.plan = .init(raw: raw)
            check(CodexAuth.usesLuna, "known limited plan uses Luna despite legacy upgrade flag")
        }
        for raw in ["plus", "promax", "ProMax", "business-premium", "future-plan"] {
            CodexAuth.plan = .init(raw: raw)
            check(!CodexAuth.usesLuna, "paid and unrecognized plans retain selected model")
        }
        CodexAuth.planChoice = .free
        check(CodexAuth.usesLuna, "explicit limited plan overrides detection")
        CodexAuth.plan = nil
        CodexAuth.planChoice = .paid
        check(!CodexAuth.usesLuna, "manual paid plan works when detection fails")
        CodexAuth.plan = .init(raw: "free")
        CodexRuntime.accountIdentity = "account-b"
        check(CodexAuth.usesLuna, "override cannot cross accounts")
        CodexRuntime.accountIdentity = "account-a"
        CodexAuth.useLunaAfterRejection(account: "account-b")
        check(!CodexAuth.usesLuna, "late failure from prior account is ignored")
        CodexAuth.useLunaAfterRejection(account: "account-a")
        check(CodexAuth.usesLuna, "rejection overrides a mistaken paid choice")
        CodexAuth.retrySelectedModel()
        check(!CodexAuth.usesLuna, "explicit retry restores chosen policy")
        CodexAuth.clearAccountPreferences()
        check(CodexAuth.planChoice == .automatic && CodexAuth.usesLuna, "logout clears account choices")

        let rejected = CodexCLI.ExecResult(status: 1, stdout: #"{"type":"error","error":{"code":"model_not_found","message":"Unavailable"}}"#, stderr: "")
        let success = CodexCLI.ExecResult(status: 0, stdout: #"{"type":"turn.completed"}"#, stderr: "")
        let args = ["exec", "-m", "gpt-6-sol", "-c", "service_tier=\"fast\"", "--json"]
        var calls = [[String]]()
        let result = try await CodexCLI.withModelFallback(args: args, timeout: 30) { argv, remaining in
            calls.append(argv)
            check(remaining > 0 && remaining <= 30, "retry shares time budget")
            return calls.count == 1 ? rejected : success
        }
        check(result.status == 0 && calls.count == 2, "real rejected start retries once")
        check(calls[1] == ["exec", "-m", "gpt-6-luna", "--json"], "fallback only changes model and service")
        check(CodexAuth.usingModelFallback, "successful fallback is retained for account")
        calls = []
        _ = try await CodexCLI.withModelFallback(args: args, timeout: 30) { argv, _ in calls.append(argv); return rejected }
        check(calls.count == 2, "persistent failure cannot loop")
        let unsafeOutputs = [
            #"{"type":"item.started","item":{"type":"mcp_tool_call"}}"#,
            #"{"type":"item.completed","item":{"type":"command_execution"}}"#,
            #"{"type":"turn.completed"}"#,
            #"{"type":"unknown_future_event"}"#,
            "unstructured output"
        ]
        for output in unsafeOutputs {
            calls = []
            let partial = CodexCLI.ExecResult(status: 1, stdout: output + "\n" + rejected.stdout, stderr: "")
            _ = try await CodexCLI.withModelFallback(args: args, timeout: 30) { argv, _ in calls.append(argv); return partial }
            check(calls.count == 1, "work or unknown activity is never replayed")
        }
        for backend in [ModelBackend.claude, .custom] {
            ModelBackend.current = backend; calls = []
            _ = try await CodexCLI.withModelFallback(args: args, timeout: 30) { argv, _ in calls.append(argv); return rejected }
            check(calls.count == 1, "other providers retain original failure")
        }
        ModelBackend.current = .chatgpt; calls = []
        _ = try await CodexCLI.withModelFallback(args: ["exec", "-m", "gpt-6-luna"], timeout: 30) { argv, _ in calls.append(argv); return rejected }
        check(calls.count == 1, "Luna rejection is not retried")
        calls = []
        _ = try await CodexCLI.withModelFallback(args: args, timeout: 30) { argv, _ in
            calls.append(argv); CodexRuntime.accountIdentity = "new-account"; return rejected
        }
        check(calls.count == 1, "account change prevents replay")
        check(ChatGPTProviderFailure.classify(detail: "workspace routing discovery unauthorized (401)") == .loginRequired, "workspace login error recognized")
        check(ChatGPTProviderFailure.classify(detail: "permission denied") == nil, "permissions do not request login")
        check(!ChatGPTProviderFailure.rejectedBeforeWork(.init(status: 0, stdout: rejected.stdout, stderr: "")), "successful execution wins over logged error")
        print("PASS \(count) ChatGPT policy and recovery assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-chatgpt-recovery-') as tmp:
    root = Path(tmp)
    (root/'Fixture.swift').write_text(fixture)
    (root/'Tests.swift').write_text(tests)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(root/'Fixture.swift'), str(APP/'Cloud/ChatGPTRecovery.swift'), str(root/'Tests.swift'), '-o', str(root/'tests')], check=True)
    subprocess.run([str(root/'tests')], check=True)
