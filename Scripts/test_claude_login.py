#!/usr/bin/env python3
"""Exercise production Claude login lifecycle with delayed URL/exit/status callbacks."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
source = (APP / 'Cloud/ClaudeSetup.swift').read_text()
start = source.index('    private(set) var loggedIn = false')
end = source.index('    // MARK: Diagnostics', start)

fixture = r'''
import Foundation
final class Process: @unchecked Sendable {
    var isRunning = true
    var onURL: (@Sendable (URL) -> Void)?
    var onExit: (@Sendable () -> Void)?
    func terminate() { isRunning = false }
}
@MainActor enum ClaudeAuth {
    struct Status { var loggedIn: Bool }
    static var status: () async -> Bool = { false }
    static var planDisplayName: String? { "Pro" }
    static func refresh() async -> Status { Status(loggedIn: await status()) }
}
@MainActor enum ClaudeCLI {
    enum Failure: Error { case launch }
    static var launchFails = false
    static var processes: [Process] = []
    static func startLogin(onURL: @escaping @Sendable (URL) -> Void,
                           onExit: @escaping @Sendable () -> Void) throws -> Process {
        if launchFails { throw Failure.launch }
        let process = Process(); process.onURL = onURL; process.onExit = onExit
        processes.append(process); return process
    }
}
@MainActor final class Setup {
    var installed = true
    var failures = 0
    enum Step { case login }
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
        let first = ClaudeCLI.processes.last!
        first.onURL?(firstLink); await settle()
        check(setup.loggingIn && setup.loginURL == firstLink, "URL arrival preserves waiting state")
        await setup.refreshLoginStatus()
        check(setup.loggingIn && setup.loginURL == firstLink, "Signed-out status while waiting preserves current link")
        setup.startLogin(force: true)
        let second = ClaudeCLI.processes.last!
        check(!first.isRunning && setup.loginURL == nil, "Restart stops previous process and clears link")
        second.onURL?(secondLink); first.onURL?(firstLink); first.onExit?(); await settle()
        check(setup.loginURL == secondLink && setup.loggingIn, "Old URL and exit cannot touch replacement")
        setup.cancelLogin()
        second.onURL?(secondLink); second.onExit?(); await settle()
        check(setup.loginURL == nil && !setup.loggingIn && !second.isRunning,
              "Cancellation clears link and ignores late callbacks")

        let gate = Gate()
        ClaudeAuth.status = { await gate.wait(); return true }
        let stale = Task { await setup.refreshLoginStatus() }
        await wait(gate)
        setup.startLogin()
        gate.release(); await stale.value
        check(!setup.loggedIn && setup.loggingIn, "Old successful status cannot complete a newer attempt")

        let oldGate = Gate()
        ClaudeAuth.status = { await oldGate.wait(); return true }
        let old = Task { await setup.refreshLoginStatus() }
        await wait(oldGate)
        ClaudeAuth.status = { false }; await setup.refreshLoginStatus()
        oldGate.release(); await old.value
        check(!setup.loggedIn, "Newest status probe wins")

        let process = ClaudeCLI.processes.last!
        process.onURL?(firstLink); await settle()
        process.isRunning = false; process.onExit?(); await settle()
        check(setup.loginURL == nil && !setup.loggingIn && setup.loginStatusLine?.contains("try again") == true,
              "Process failure clears link and restores retry without a visible panel")
        setup.startLogin()
        check(setup.loggingIn, "Failed attempt can be retried")
        let success = ClaudeCLI.processes.last!
        success.onURL?(secondLink); await settle()
        ClaudeAuth.status = { true }
        success.isRunning = false; success.onExit?(); await settle()
        check(setup.loggedIn && !setup.loggingIn && setup.loginURL == nil,
              "Successful exit clears link after checking ground truth")
        success.onURL?(secondLink); await settle()
        check(setup.loginURL == nil, "Late output cannot restore a finished link")
        let count = ClaudeCLI.processes.count
        setup.startLogin()
        check(ClaudeCLI.processes.count == count, "Already signed in does not start another attempt")
        setup.cancelLogin()
        check(setup.loggedIn, "Cleanup does not discard saved authentication")

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
