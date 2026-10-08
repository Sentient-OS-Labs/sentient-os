#!/usr/bin/env python3
"""Exercise production private-login state and cancellation with inert CLI/process fixtures."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
source = (APP / 'Cloud/CodexSetup.swift').read_text()
assert 'CodexRuntimeMigration' not in source
start = source.index('    private(set) var loggedIn = false')
end = source.index('    private func refreshConnectorsAfterLogin()', start)
methods = source[start:end]
fixture = r'''
import Foundation
final class Process: @unchecked Sendable {
    var isRunning = true
    var terminated = false
    var onURL: (@Sendable (URL) -> Void)?
    var onExit: (@Sendable () -> Void)?
    func terminate() { terminated = true; isRunning = false }
    func waitUntilExit() {}
}
@MainActor enum CodexCLI {
    static var status: () async -> Bool = { false }
    static var launchFails = false
    static var processes: [Process] = []
    enum Failure: Error { case launch }
    static func loginStatus() async -> Bool { await status() }
    static func startLogin(onURL: @escaping @Sendable (URL) -> Void,
                           onExit: @escaping @Sendable () -> Void) throws -> Process {
        if launchFails { throw Failure.launch }
        let process = Process(); process.onURL = onURL; process.onExit = onExit
        processes.append(process); return process
    }
}
@MainActor final class Gate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class Setup {
    var installed = true
    var shuttingDown = false
    var refreshes = 0
    var failures = 0
    enum Step { case login }
    func stepFailed(_ step: Step, _ error: Error) { failures += 1 }
    func refreshConnectorsAfterLogin() { refreshes += 1 }
    func setRefreshTask(_ task: Task<Void, Never>?) { connectorRefreshTask = task }
__METHODS__
}
@main struct Test {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }
    @MainActor static func wait(_ gate: Gate) async {
        for _ in 0..<10_000 { if gate.entered { return }; await Task.yield() }
        fatalError("Fixture didn't reach suspended state")
    }
    @MainActor static func main() async {
        let link = URL(string: "https://example.com/attempt-one")!
        let otherLink = URL(string: "https://example.com/attempt-two")!
        let setup = Setup()
        check(!setup.loggedIn && !setup.loginStatusChecked, "No green state before the private check")
        await setup.refreshLoginStatus()
        check(!setup.loggedIn && setup.loginStatusChecked, "Missing auth is a completed signed-out verdict")
        let gate = Gate()
        CodexCLI.status = { await gate.wait(); return false }
        let stale = Task { await setup.refreshLoginStatus() }
        await wait(gate)
        let first = await setup.startLogin()
        check(first != nil && setup.loggingIn && !setup.loginStatusChecked, "Own login resets verdict and owns callback")
        let firstProcess = CodexCLI.processes.last!
        firstProcess.onURL?(link)
        for _ in 0..<100 { await Task.yield() }
        check(setup.loginURL == link && setup.loggingIn, "Capturing a link preserves the waiting login")
        gate.release(); await stale.value
        check(!setup.loginStatusChecked && setup.loggingIn, "Old check cannot overwrite newer login")

        let second = await setup.startLogin(force: true)
        let secondProcess = CodexCLI.processes.last!
        check(setup.loginURL == nil, "Replacement clears previous link immediately")
        firstProcess.onURL?(link); firstProcess.onExit?()
        secondProcess.onURL?(otherLink)
        for _ in 0..<100 { await Task.yield() }
        check(setup.loginURL == otherLink && setup.loggingIn, "Late URL and exit from old attempt cannot replace current link")
        check(second != nil && second != first && firstProcess.terminated, "Replacement stops only previous own callback")
        await setup.cancelLogin(ifAttempt: first)
        check(setup.loggingIn && !secondProcess.terminated, "Old sheet cannot stop Settings replacement")
        await setup.cancelLogin(ifAttempt: second)
        check(!setup.loggingIn && secondProcess.terminated, "Matching cancellation stops callback")
        secondProcess.onURL?(otherLink)
        for _ in 0..<100 { await Task.yield() }
        check(setup.loginURL == nil, "Cancellation rejects a late URL")

        let lateGate = Gate()
        CodexCLI.status = { await lateGate.wait(); return true }
        let late = Task { await setup.refreshLoginStatus() }
        await wait(lateGate)
        await setup.cancelLogin()
        lateGate.release(); await late.value
        check(!setup.loggedIn && !setup.loginStatusChecked, "Dismissed probe cannot later publish green")

        let oldGate = Gate()
        CodexCLI.status = { await oldGate.wait(); return true }
        let old = Task { await setup.refreshLoginStatus() }
        await wait(oldGate)
        CodexCLI.status = { false }
        await setup.refreshLoginStatus()
        oldGate.release(); await old.value
        check(!setup.loggedIn && setup.loginStatusChecked, "Newest probe wins despite completion order")

        let cancelledGate = Gate()
        CodexCLI.status = { await cancelledGate.wait(); return true }
        let cancelled = Task { await setup.refreshLoginStatus() }
        await wait(cancelledGate); cancelled.cancel(); cancelledGate.release(); await cancelled.value
        check(!setup.loggedIn, "Task cancellation rejects stale status")

        CodexCLI.status = { true }
        await setup.confirmLogin()
        check(setup.loggedIn && setup.loginStatusChecked && setup.refreshes == 1, "Confirmed own auth refreshes connectors")
        check(setup.loginURL == nil, "Successful sign-in exposes no stale copy link")
        let processCount = CodexCLI.processes.count
        let noStart = await setup.startLogin()
        check(noStart == nil && CodexCLI.processes.count == processCount, "Already signed in does not open browser")
        await setup.cancelLogin()
        check(setup.loggedIn, "Cleanup preserves completed saved login")

        let exited = Setup()
        CodexCLI.status = { false }
        let exitedAttempt = await exited.startLogin()
        await exited.refreshLoginStatus()
        check(exited.loggingIn, "Negative check while callback runs keeps browser flow open")
        CodexCLI.processes.last!.isRunning = false
        CodexCLI.processes.last!.onExit?()
        for _ in 0..<100 { await Task.yield() }
        await exited.refreshLoginStatus()
        check(!exited.loggingIn && !exited.loggedIn && exited.loginStatusLine?.contains("try again") == true,
              "Exited callback without auth restores onboarding retry button")
        let restarted = await exited.startLogin()
        check(restarted != nil && restarted != exitedAttempt, "Failed browser flow can start a new attempt")
        await exited.cancelLogin(ifAttempt: restarted)

        let fresh = Setup()
        CodexCLI.launchFails = true
        let failed = await fresh.startLogin()
        check(failed == nil && !fresh.loggingIn && fresh.failures == 1 && fresh.loginStatusLine?.hasPrefix("✗") == true,
              "Launch error visible and retryable")
        CodexCLI.launchFails = false
        fresh.installed = false
        let absent = await fresh.startLogin()
        check(absent == nil && fresh.loginStatusLine?.contains("Install") == true, "No fallback when own runtime missing")
        fresh.installed = true

        let refreshGate = Gate()
        let refresh = Task { await refreshGate.wait() }
        fresh.setRefreshTask(refresh)
        await wait(refreshGate)
        let before = CodexCLI.processes.count
        let starting = Task { await fresh.startLogin() }
        for _ in 0..<100 { await Task.yield() }
        let concurrent = await fresh.startLogin()
        check(concurrent == nil, "Concurrent click cannot duplicate callback")
        starting.cancel(); refreshGate.release()
        let cancelledStart = await starting.value
        check(cancelledStart == nil && CodexCLI.processes.count == before, "Cancelled launch during drain never opens browser")
        fresh.setRefreshTask(nil)
        let retry = await fresh.startLogin()
        check(retry != nil, "Cancelled launch remains retryable")
        await fresh.cancelLogin(ifAttempt: retry)

        fresh.shuttingDown = true
        let afterShutdown = await fresh.startLogin()
        check(afterShutdown == nil, "Shutdown blocks sign-in")
        print("PASS: \(checks) private login state checks")
    }
}
'''.replace('__METHODS__', methods)
with tempfile.TemporaryDirectory(prefix='sentient-private-login-') as tmp:
    path = Path(tmp)
    swift = path / 'Fixture.swift'; swift.write_text(fixture)
    binary = path / 'fixture'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
