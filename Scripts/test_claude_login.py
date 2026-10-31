#!/usr/bin/env python3
"""Exercise production Claude login lifecycle with delayed URL/exit/status callbacks."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
source = (APP / 'Cloud/ClaudeSetup.swift').read_text()
start = source.index('    private var statusLoggedIn = false')
end = source.index('    // MARK: Diagnostics', start)

fixture = r'''
import Foundation
final class Process: @unchecked Sendable {
    var isRunning = true
    var onURL: (@Sendable (URL) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    func terminate() { isRunning = false }
}
enum FixtureFailure: Error { case quota, network }
@MainActor enum CodexFailureReason { case usageLimit, unknown
    static func classify(_ error: Error) -> Self { (error as? FixtureFailure) == .quota ? .usageLimit : .unknown }
}
@MainActor enum ClaudeAuth {
    struct Status { var loggedIn: Bool }
    struct LoginRequired: Error {}
    static var requiresVerification = false
    static var cachedLoggedIn = false
    static var revision = UUID()
    static var status: () async -> Bool = { false }
    static var verification: () async throws -> Void = {}
    static var planDisplayName: String? { "Pro" }
    static var accountChanges = 0
    static func beginAccountChange() { accountChanges += 1 }
    static func refresh() async -> Status { Status(loggedIn: await status() && !requiresVerification) }
    static func beginLogin() -> UUID { revision = UUID(); requiresVerification = true; cachedLoggedIn = false; return revision }
    static func cancelLogin(revision old: UUID) { if old == revision { revision = UUID() } }
    static func rejected(_ error: Error, after old: UUID) { if error is LoginRequired, old == revision { _ = beginLogin() } }
    static func verifyLogin(revision old: UUID) async throws {
        try await verification(); try Task.checkCancellation()
        guard revision == old else { throw CancellationError() }
        requiresVerification = false; cachedLoggedIn = true; revision = UUID()
    }
}
@MainActor enum ClaudeCLI {
    enum Failure: Error { case launch }
    static var launchFails = false
    static var processes: [Process] = []
    static func startLogin(onURL: @escaping @Sendable (URL) -> Void,
                           onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        if launchFails { throw Failure.launch }
        let process = Process(); process.onURL = onURL; process.onExit = onExit
        processes.append(process); return process
    }
}
@MainActor final class Setup {
    var installed = true
    var failures = 0
    enum Step { case login, verify }
    func stepFailed(_ step: Step, _ error: Error) { failures += 1 }
__METHODS__
}
@MainActor final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    @MainActor static func settle() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func wait(_ gate: Gate) async {
        for _ in 0..<10_000 { if gate.entered { return }; await Task.yield() }
        preconditionFailure("Status probe never suspended")
    }
    @MainActor static func main() async {
        let setup = Setup(), firstLink = URL(string: "https://example.com/first")!
        let secondLink = URL(string: "https://example.com/second")!
        setup.startLogin()
        check(ClaudeAuth.accountChanges == 1, "Starting login invalidates earlier connector readiness immediately")
        let first = ClaudeCLI.processes.last!
        first.onURL?(firstLink); await settle()
        check(setup.loggingIn && setup.loginURL == firstLink, "URL arrival preserves waiting state")
        ClaudeAuth.status = { true }
        await setup.refreshLoginStatus()
        check(!setup.loggedIn && setup.loggingIn && setup.loginURL == firstLink,
              "Old signed-in status cannot finish browser OAuth")
        setup.startLogin()
        check(ClaudeCLI.processes.last === first, "Repeated tap does not launch concurrent OAuth")
        setup.cancelLogin(); setup.startLogin(force: true)
        let second = ClaudeCLI.processes.last!
        check(!first.isRunning && setup.loginURL == nil, "Restart stops previous process and clears link")
        second.onURL?(secondLink); first.onURL?(firstLink); first.onExit?(0); await settle()
        check(setup.loginURL == secondLink && setup.loggingIn, "Old URL and exit cannot touch replacement")
        setup.cancelLogin()
        second.onURL?(secondLink); second.onExit?(0); await settle()
        check(setup.loginURL == nil && !setup.loggingIn && !second.isRunning,
              "Cancellation clears link and ignores late callbacks")

        let gate = Gate()
        ClaudeAuth.status = { await gate.wait(); return true }
        let stale = Task { await setup.refreshLoginStatus() }
        await wait(gate)
        setup.startLogin()
        gate.release(); await stale.value
        check(!setup.loggedIn && setup.loggingIn, "Old successful status cannot complete a newer attempt")
        setup.cancelLogin()
        let oldGate = Gate()
        ClaudeAuth.status = { await oldGate.wait(); return true }
        let old = Task { await setup.refreshLoginStatus() }
        await wait(oldGate)
        ClaudeAuth.status = { false }; await setup.refreshLoginStatus()
        oldGate.release(); await old.value
        check(!setup.loggedIn, "Newest status probe wins")

        setup.startLogin()
        let process = ClaudeCLI.processes.last!
        process.onURL?(firstLink); await settle()
        process.isRunning = false; process.onExit?(1); await settle()
        check(setup.loginURL == nil && !setup.loggingIn && !setup.loggedIn
              && setup.loginStatusLine?.contains("try again") == true,
              "Failed process exits without trusting an existing credential")
        setup.startLogin()
        let success = ClaudeCLI.processes.last!
        success.onURL?(secondLink); await settle()
        let verification = Gate()
        ClaudeAuth.status = { true }
        ClaudeAuth.verification = { await verification.wait() }
        success.isRunning = false; success.onExit?(0); await wait(verification)
        check(setup.loggingIn && setup.verifyingLogin && !setup.loggedIn && setup.loginURL == nil,
              "OAuth success waits for model verification")
        await setup.refreshLoginStatus()
        check(!setup.loggedIn, "Polling cannot bypass in-flight verification")
        verification.release(); await settle()
        check(setup.loggedIn && !setup.loggingIn && !setup.verificationPending,
              "Verified login enables readiness")
        success.onURL?(secondLink); await settle()
        check(setup.loginURL == nil, "Late output cannot restore a finished link")
        let count = ClaudeCLI.processes.count
        setup.startLogin()
        check(ClaudeCLI.processes.count == count, "Already signed in does not start another attempt")
        setup.cancelLogin()
        check(setup.loggedIn, "Cleanup preserves completed sign-in")

        for failure in [FixtureFailure.network, .quota] {
            ClaudeAuth.verification = { throw failure }
            setup.startLogin(force: true)
            let process = ClaudeCLI.processes.last!
            process.isRunning = false; process.onExit?(0); await settle()
            check(!setup.loggedIn && setup.verificationPending && !setup.loggingIn,
                  "Temporary verification failure offers a check without more OAuth")
            let before = ClaudeCLI.processes.count
            ClaudeAuth.verification = {}
            setup.startLogin(); await settle()
            check(setup.loggedIn && ClaudeCLI.processes.count == before,
                  "Verification retry succeeds without another browser")
        }
        ClaudeAuth.verification = { throw ClaudeAuth.LoginRequired() }
        setup.startLogin(force: true)
        let invalid = ClaudeCLI.processes.last!
        invalid.isRunning = false; invalid.onExit?(0); await settle()
        check(!setup.loggedIn && !setup.verificationPending && !setup.loggingIn,
              "Rejected verification asks for a fresh sign-in")

        let canceledCheck = Gate()
        ClaudeAuth.verification = { await canceledCheck.wait() }
        setup.startLogin()
        let canceledProcess = ClaudeCLI.processes.last!
        canceledProcess.isRunning = false; canceledProcess.onExit?(0); await wait(canceledCheck)
        setup.cancelLogin(); ClaudeAuth.verification = {}
        setup.startLogin()
        let replacement = ClaudeCLI.processes.last!
        replacement.isRunning = false; replacement.onExit?(0); await settle()
        canceledCheck.release(); await settle()
        check(setup.loggedIn && !setup.loggingIn, "Canceled verification cannot overwrite replacement success")

        let failed = Setup()
        ClaudeCLI.launchFails = true; failed.startLogin()
        check(!failed.loggingIn && failed.loginURL == nil && failed.failures == 1,
              "Launch failure exposes no link and remains retryable")
        ClaudeCLI.launchFails = false
        failed.installed = false; failed.startLogin()
        check(!failed.loggingIn && failed.loginStatusLine?.contains("Install") == true,
              "Missing CLI never exposes a copy link")
        print("PASS: \(checks) Claude login state checks")
    }
}
'''.replace('__METHODS__', source[start:end])
with tempfile.TemporaryDirectory(prefix='sentient-claude-login-') as tmp:
    directory = Path(tmp)
    swift = directory / 'Fixture.swift'
    swift.write_text(fixture)
    binary = directory / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
