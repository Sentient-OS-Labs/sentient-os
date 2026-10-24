#!/usr/bin/env python3
"""Compile the production Claude login state and envelope parser against an inert CLI.

Only UserDefaults is redirected to a unique fixture suite. No Claude executable, real
credentials, browser, network, app startup, or telemetry is used.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
auth = (APP / "Cloud/ClaudeAuth.swift").read_text().replace("UserDefaults.standard", "Fixture.defaults")
cli = (APP / "Cloud/ClaudeCLI.swift").read_text()
parser = cli[cli.index("    static func parseEnvelope("):cli.index("    /// Reduce one stream-json line")]
markers = cli[cli.index("    private static let usageLimitMarkers"):cli.index("    /// The latest `rate_limit_event`")]
validation = cli[cli.index("    func validate(force:"):cli.index("    // MARK: Run (the structured spine)")]
support = r'''
import Foundation

nonisolated enum Fixture {
    static var suite: String { ProcessInfo.processInfo.environment["CLAUDE_LOGIN_FIXTURE_SUITE"]! }
    static var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    static let status = CodexCLI.ExecResult(status: 0, stdout: #"{"loggedIn":true,"subscriptionType":"max"}"#, stderr: "")
    static let ok = CodexCLI.ExecResult(status: 0, stdout: #"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"#, stderr: "")
    static let rejection = "Failed to authenticate. API Error: 401 OAuth access token is invalid."
    static func output(_ text: String, failed: Bool = true, status: Int32? = nil) throws -> CodexCLI.ExecResult {
        let json = try JSONSerialization.data(withJSONObject: ["type":"result", "subtype":failed ? "error_during_execution" : "success", "is_error":failed, "result":text])
        return .init(status: status ?? (failed ? 1 : 0), stdout: String(decoding: json, as: UTF8.self), stderr: "")
    }
}
nonisolated enum CodexFailureReason: Sendable { case notLoggedIn, tokenExpired, refreshFailed }
nonisolated enum AgentStatus { case none, done }
nonisolated enum CodexCLI {
    enum Availability: Sendable { case notInstalled, notWorking(String), available(path: String) }
    enum CLIError: Error { case notAvailable(Availability), usageLimit(message: String, sessionID: String?), exitFailure(code: Int32, message: String), badEnvelope(String) }
    struct ExecResult: Sendable { let status: Int32; let stdout: String; let stderr: String }
    struct Envelope { let result: String; let sessionID: String?; let numTurns: Int?; let durationMS: Int?; let inputTokens: Int?; let cachedInputTokens: Int?; let outputTokens: Int?; let raw: String }
    static func executeAsync(binary: String, args: [String], stdinText: String?, cwd: String?, timeout: TimeInterval, extraEnv: [String: String] = [:], includeCustomProviderKey: Bool = true) async throws -> ExecResult {
        try await FakeCLI.shared.run(args: args, input: stdinText, cwd: cwd, environment: extraEnv, includeKey: includeCustomProviderKey)
    }
}
actor FakeCLI {
    static let shared = FakeCLI()
    struct Call: Sendable { let args: [String]; let input: String?; let cwd: String?; let environment: [String: String]; let includeKey: Bool }
    var calls: [Call] = []
    var status = Fixture.status, verification = Fixture.ok
    var statusDelay: Duration = .zero, verificationDelay: Duration = .zero
    func configure(status: CodexCLI.ExecResult = Fixture.status, verification: CodexCLI.ExecResult = Fixture.ok, statusDelay: Duration = .zero, verificationDelay: Duration = .zero) {
        self.status = status; self.verification = verification
        self.statusDelay = statusDelay; self.verificationDelay = verificationDelay
    }
    func run(args: [String], input: String?, cwd: String?, environment: [String: String], includeKey: Bool) async throws -> CodexCLI.ExecResult {
        calls.append(.init(args: args, input: input, cwd: cwd, environment: environment, includeKey: includeKey))
        let probe = args.contains("--max-turns")
        let result = probe ? verification : status
        let delay = probe ? verificationDelay : statusDelay
        // Deliberately ignore cancellation so production must reject late completions itself.
        if delay != .zero { try? await Task.sleep(for: delay) }
        return result
    }
    func count() -> Int { calls.count }
    func last() -> Call { calls.last! }
}
@MainActor enum ClaudeSetup { static let shared = SelfMock(); final class SelfMock { func authenticationRejected() {} } }
func Log(_ message: String) {}
actor ClaudeCLI {
    static let shared = ClaudeCLI()
    private var cachedAvailability: CodexCLI.Availability?
    private var availabilityRevision: UUID?
    private var cachedVersion: String?
    static func installedVersion() async -> String? { "2.1.306" }
__VALIDATION__
    enum Model: String { case sonnet = "fixture-sonnet" }
    static func locateBinary() -> String? { "/fixture/claude" }
    static let baseEnv: [String: String] = [:]
    static let rateLimitResetsAtKey = "fixture.limitAt", rateLimitTypeKey = "fixture.limitType"
    static func noteRateLimit(_ info: [String: Any]) {}
__MARKERS__
__PARSER__
}
'''.replace("__MARKERS__", markers).replace("__PARSER__", parser).replace("__VALIDATION__", validation)
tests = r'''
@main struct Tests {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label); count += 1
    }
    static func parse(_ result: CodexCLI.ExecResult) -> Error? {
        do { _ = try ClaudeCLI.parseEnvelope(result, durationMS: 1); return nil } catch { return error }
    }
    static func waitForCall(after before: Int) async {
        for _ in 0..<1000 { if await FakeCLI.shared.count() > before { return }; await Task.yield() }
        preconditionFailure("CLI did not start")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("relaunch") {
            check(ClaudeAuth.requiresVerification, "rejection survives new process")
            check(await !ClaudeAuth.refresh().loggedIn, "status cannot clear persisted rejection")
            Fixture.defaults.removePersistentDomain(forName: Fixture.suite)
            print("PASS: \(count) Claude login persistence checks"); return
        }
        defer { print("PASS: \(count) Claude parser and login-state checks") }
        ClaudeAuth.destroy()
        for (text, reason) in [(Fixture.rejection, CodexFailureReason.notLoggedIn),
            ("API Error: 401 OAuth token has expired.", .tokenExpired),
            ("API Error: 401 {\"type\":\"authentication_error\"}", .notLoggedIn),
            ("OAuth token refresh failed: invalid_grant", .refreshFailed),
            ("Failed to authenticate. OAuth token refresh failed: revoked", .refreshFailed),
            ("Not logged in · Please run /login", .notLoggedIn)] {
            let failure = parse(try Fixture.output(text)) as? ClaudeAuth.LoginRequired
            check(failure?.reason == reason, "terminal rejection retains its reason")
        }
        for text in ["Gmail OAuth token is invalid: 401", "Not logged in to Gmail", "Failed to authenticate to Gmail: OAuth token invalid", "OAuth token refresh failed: network is unreachable", "OAuth token refresh failed: timeout", "401 Unauthorized", "API Error: 500 OAuth service unavailable", "The user quoted: " + Fixture.rejection] {
            check(!(parse(try Fixture.output(text)) is ClaudeAuth.LoginRequired), "unrelated error must not revoke Claude login")
        }
        check(parse(try Fixture.output(Fixture.rejection, failed: false)) == nil, "successful model text is not an error")
        check(!(parse(try Fixture.output(Fixture.rejection, failed: false, status: 1)) is ClaudeAuth.LoginRequired), "failed exit does not turn successful text into login evidence")
        check(parse(.init(status: 1, stdout: "", stderr: Fixture.rejection)) is ClaudeAuth.LoginRequired, "fatal stderr")
        check(parse(.init(status: 1, stdout: Fixture.rejection, stderr: "")) is ClaudeAuth.LoginRequired, "fatal plain stdout")
        if case CodexCLI.CLIError.usageLimit = parse(try Fixture.output("API Error: 429 usage limit"))! { check(true, "quota stays quota") }
        else { preconditionFailure("quota misclassified") }
        check(await ClaudeAuth.refresh().loggedIn, "healthy initial status")
        if case .available = await ClaudeCLI.shared.validate() { check(true, "initial availability") } else { preconditionFailure("missing availability") }
        await FakeCLI.shared.configure(status: .init(status: 1, stdout: #"{"loggedIn":false}"#, stderr: ""))
        _ = await ClaudeAuth.refresh()
        if case .notWorking = await ClaudeCLI.shared.validate() { check(true, "known local sign-out overrides cached availability") } else { preconditionFailure("stale available cache") }
        await FakeCLI.shared.configure()
        if case .available = await ClaudeCLI.shared.validate() { check(true, "local login without runtime rejection remains usable") } else { preconditionFailure("missing availability") }
        let working = ClaudeAuth.revision
        ClaudeAuth.rejected(CodexCLI.CLIError.badEnvelope("401"), after: working)
        check(!ClaudeAuth.requiresVerification, "untyped error cannot revoke login")
        ClaudeAuth.rejected(ClaudeAuth.LoginRequired(), after: working)
        check(ClaudeAuth.requiresVerification && !ClaudeAuth.cachedLoggedIn, "runtime invalidates cached identity")
        check(await !ClaudeAuth.refresh().loggedIn, "local status cannot erase rejection")
        if case .notWorking = await ClaudeCLI.shared.validate() { check(true, "runtime rejection overrides cached availability") } else { preconditionFailure("stale runtime availability") }
        do { _ = try ClaudeAuth.usableRevision(); preconditionFailure("rejected request allowed") }
        catch is ClaudeAuth.LoginRequired { check(true, "request blocked before process") }
        let attempt = ClaudeAuth.beginLogin()
        try await ClaudeAuth.verifyLogin(revision: attempt)
        check(!ClaudeAuth.requiresVerification && ClaudeAuth.cachedLoggedIn, "verification repairs identity")
        let probe = await FakeCLI.shared.last()
        check(probe.input == "Reply with OK." && !probe.includeKey, "fixed prompt and no unrelated provider key")
        check(probe.args.contains("--strict-mcp-config") && probe.args.contains("{\"mcpServers\":{}}"), "no connector configuration")
        check(probe.args[probe.args.firstIndex(of: "--tools")! + 1] == "", "no built-in tools")
        check(probe.args.contains("--no-session-persistence") && probe.environment["CLAUDE_CODE_SAFE_MODE"] == "1", "no saved session or customizations")
        check(!FileManager.default.fileExists(atPath: probe.cwd!), "scratch directory removed")
        if case .available = await ClaudeCLI.shared.validate() { check(true, "verified login restores availability") } else { preconditionFailure("unavailable after repair") }
        ClaudeAuth.rejected(ClaudeAuth.LoginRequired(), after: working)
        check(!ClaudeAuth.requiresVerification, "late old failure cannot revoke repaired identity")
        await FakeCLI.shared.configure(statusDelay: .milliseconds(150))
        let beforeStatus = await FakeCLI.shared.count()
        let staleStatus = Task { await ClaudeAuth.refresh() }
        await waitForCall(after: beforeStatus)
        ClaudeAuth.rejected(ClaudeAuth.LoginRequired(), after: ClaudeAuth.revision)
        check(await !staleStatus.value.loggedIn, "status begun before rejection cannot overwrite it")
        for output in [try Fixture.output("OAuth token refresh failed: network is unreachable"), try Fixture.output("usage limit"), try Fixture.output(Fixture.rejection)] {
            await FakeCLI.shared.configure(verification: output)
            let attempt = ClaudeAuth.beginLogin()
            do { try await ClaudeAuth.verifyLogin(revision: attempt); preconditionFailure("invalid verification accepted") } catch {}
            check(ClaudeAuth.requiresVerification && !ClaudeAuth.cachedLoggedIn, "unsuccessful verification never restores ready")
        }
        await FakeCLI.shared.configure(verificationDelay: .milliseconds(150))
        let canceledRevision = ClaudeAuth.beginLogin()
        let beforeCancel = await FakeCLI.shared.count()
        let canceled = Task { try await ClaudeAuth.verifyLogin(revision: canceledRevision) }
        await waitForCall(after: beforeCancel)
        canceled.cancel(); ClaudeAuth.cancelLogin(revision: canceledRevision)
        do { try await canceled.value; preconditionFailure("canceled verification accepted") } catch {}
        check(ClaudeAuth.requiresVerification, "canceled success cannot restore ready")
        await FakeCLI.shared.configure(verificationDelay: .milliseconds(150))
        let oldRevision = ClaudeAuth.beginLogin()
        let beforeOld = await FakeCLI.shared.count()
        let oldCheck = Task { try await ClaudeAuth.verifyLogin(revision: oldRevision) }
        await waitForCall(after: beforeOld + 1)
        await FakeCLI.shared.configure()
        let newRevision = ClaudeAuth.beginLogin()
        try await ClaudeAuth.verifyLogin(revision: newRevision)
        do { try await oldCheck.value; preconditionFailure("stale verification accepted") } catch {}
        check(!ClaudeAuth.requiresVerification && ClaudeAuth.cachedLoggedIn, "newer verified identity wins")
        ClaudeAuth.rejected(ClaudeAuth.LoginRequired(), after: ClaudeAuth.revision)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-claude-state-") as tmp:
    folder = Path(tmp)
    source = folder / "Fixture.swift"
    source.write_text(auth + support + tests)
    binary = folder / "fixture"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    env = dict(os.environ, CLAUDE_LOGIN_FIXTURE_SUITE="ai.sentient.claude-fixture." + str(uuid.uuid4()))
    subprocess.run([str(binary)], env=env, check=True, timeout=30)
    subprocess.run([str(binary), "relaunch"], env=env, check=True, timeout=30)
