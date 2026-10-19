#!/usr/bin/env python3
"""Compile the full production runtime with fake Launch Services to test startup races."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

STUBS = r'''
import Foundation
import Observation
func Log(_ value: String) {}
enum CrashReporting { static func diagnosticBreadcrumb(_ name: String, data: [String: String]) {} }
enum Diagnostics {
    enum Kind { case readinessFailed }; enum Phase { case probe }
    static func isExpected(_ error: Error) -> Bool { true }
    static func report(_ kind: Kind, phase: Phase, error: Error) {}
}
final class AgentRunDiagnostics {
    static var current: AgentRunDiagnostics?
    func recordHelper(running: Bool, atStart: Bool) {}
}
enum Permissions {
    enum State { case granted }
    static func nativeAutomationState() async -> State { .granted }
}
enum CodexRuntime {
    enum Failure: Error { case busy }
    static let executable = URL(fileURLWithPath: "/private-codex")
    static var exclusiveBusy = false
    struct Lease { func unlock() {} }
    struct Helper { let version = "fixture" }
    struct Release { let helper = Helper(); let helperBuild = 1 }
    static let release = Release()
    static func sharedRuntimeLease() async throws -> Lease { Lease() }
    static func executionLease(for binary: String, exclusive: Bool) throws -> Lease? {
        if exclusiveBusy { throw Failure.busy }; return Lease()
    }
}
final class NSRunningApplication {
    static var apps: [NSRunningApplication] = []
    static var nextPID: Int32 = 1
    let processIdentifier: Int32
    let bundleURL: URL?
    var isTerminated = false
    init(_ url: URL?) { bundleURL = url; processIdentifier = Self.nextPID; Self.nextPID += 1 }
    static func runningApplications(withBundleIdentifier: String) -> [NSRunningApplication] { apps.filter { !$0.isTerminated } }
    func terminate() -> Bool { isTerminated = true; return true }
    func forceTerminate() -> Bool { isTerminated = true; return true }
}
final class NSWorkspace {
    final class OpenConfiguration {
        var activates = false
        var allowsRunningApplicationSubstitution = false
        var environment: [String: String] = [:]
    }
    static let shared = NSWorkspace()
    var launches = 0
    var failLaunches = 0
    var dieOnLaunches = 0
    func openApplication(at url: URL, configuration: OpenConfiguration) async throws -> NSRunningApplication {
        launches += 1
        if failLaunches > 0 { failLaunches -= 1; throw OpenAIComputerUse.RuntimeError.launchFailed }
        let app = NSRunningApplication(url)
        if dieOnLaunches > 0 { dieOnLaunches -= 1; app.isTerminated = true }
        NSRunningApplication.apps.append(app)
        return app
    }
}
enum OpenAIComputerUse {
    static let bundleID = "fixture.helper"
    struct Configuration: Equatable, Sendable {
        let appURL = URL(fileURLWithPath: "/private-helper.app")
        let environment = ["CODEX_HOME": "/private"]
        func afterRuntimeLease() throws -> Self { self }
    }
    enum RuntimeError: Error, Equatable {
        case helperRunning, conflictingHelper, restartRequired, launchFailed, permissionRequired
    }
    static var validationHeld = false
    static var validations = 0
    static var takeovers = 0
    static var exitDuringReuse = false
    static func validate(at app: URL) async throws -> Bool {
        validations += 1
        while validationHeld { try await Task.sleep(for: .milliseconds(5)) }
        return true
    }
    static func acceptsRunningHelper(at url: URL, configuration: Configuration) async -> Bool {
        if exitDuringReuse {
            exitDuringReuse = false
            NSRunningApplication.apps.first { $0.bundleURL == url }?.isTerminated = true
        }
        return url == configuration.appURL
    }
    static func stopConflictingHelpers(configuration: Configuration) async throws {
        takeovers += 1
        for app in NSRunningApplication.apps where app.bundleURL != configuration.appURL { app.isTerminated = true }
    }
}
enum OpenAIComputerUseProbe { static func check(_ configuration: OpenAIComputerUse.Configuration) async throws {} }
'''

TESTS = r'''
extension OpenAIComputerUseRuntime {
    static func fixture() -> OpenAIComputerUseRuntime { OpenAIComputerUseRuntime() }
}
@main enum Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAIL: " + label) }; checks += 1
    }
    static func fresh() -> OpenAIComputerUseRuntime {
        NSRunningApplication.apps = []; NSWorkspace.shared.launches = 0
        NSWorkspace.shared.failLaunches = 0; NSWorkspace.shared.dieOnLaunches = 0
        OpenAIComputerUse.validations = 0; OpenAIComputerUse.takeovers = 0
        OpenAIComputerUse.validationHeld = false
        OpenAIComputerUse.exitDuringReuse = false
        CodexRuntime.exclusiveBusy = false
        return .fixture()
    }
    static func waitForValidation() async throws {
        for _ in 0..<100 {
            if OpenAIComputerUse.validations > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("No startup")
    }
    static func main() async throws {
        let configuration = OpenAIComputerUse.Configuration()
        let runtime = fresh()
        let foreign = NSRunningApplication(URL(fileURLWithPath: "/foreign-helper.app"))
        NSRunningApplication.apps = [foreign]
        OpenAIComputerUse.validationHeld = true
        let passive = Task { try await runtime.start(configuration: configuration) }
        try await waitForValidation()
        let foreground = Task { try await runtime.start(configuration: configuration, stoppingConflictingHelpers: true) }
        try await Task.sleep(for: .milliseconds(10)); OpenAIComputerUse.validationHeld = false
        do { _ = try await passive.value; fatalError("Passive start should refuse foreign helper") }
        catch OpenAIComputerUse.RuntimeError.conflictingHelper {}
        let own = try await foreground.value
        check(foreign.isTerminated && own.bundleURL == configuration.appURL, "foreground recovers a shared passive conflict")
        check(NSWorkspace.shared.launches == 1, "concurrent handoff launches once")
        let repeated = try await runtime.start(configuration: configuration, stoppingConflictingHelpers: true)
        check(repeated.processIdentifier == own.processIdentifier && !own.isTerminated, "healthy private helper reused")
        OpenAIComputerUse.exitDuringReuse = true
        let replacement = try await runtime.start(configuration: configuration, stoppingConflictingHelpers: true)
        check(!replacement.isTerminated && replacement.processIdentifier != own.processIdentifier,
              "private helper exiting during reuse gets a fresh startup")

        let failedLaunch = fresh(); NSWorkspace.shared.failLaunches = 1
        _ = try await failedLaunch.start(configuration: configuration, stoppingConflictingHelpers: true)
        check(NSWorkspace.shared.launches == 2, "one transient launch failure retries before task starts")
        let earlyExit = fresh(); NSWorkspace.shared.dieOnLaunches = 1
        let live = try await earlyExit.start(configuration: configuration, stoppingConflictingHelpers: true)
        check(!live.isTerminated && NSWorkspace.shared.launches == 2, "helper exiting during startup is replaced")
        let persistentFailure = fresh(); NSWorkspace.shared.failLaunches = 10
        do {
            _ = try await persistentFailure.start(configuration: configuration, stoppingConflictingHelpers: true)
            fatalError("Unbounded launch failure")
        } catch OpenAIComputerUse.RuntimeError.launchFailed {}
        check(NSWorkspace.shared.launches == 3, "startup retry budget is bounded")

        let leased = fresh()
        let lease = try await leased.beginTask(configuration: configuration)
        do { try await leased.restart(configuration: configuration); fatalError("Active task was restarted") }
        catch OpenAIComputerUse.RuntimeError.helperRunning {}
        check(!NSRunningApplication.apps[0].isTerminated, "repair preserves active Sentient task")
        check(leased.reserveDiagnostic() == nil, "a separate diagnostic cannot take over an active agent")
        leased.endTask(lease)
        let other = NSRunningApplication(URL(fileURLWithPath: "/other-helper.app"))
        NSRunningApplication.apps.append(other)
        try await leased.restart(configuration: configuration)
        check(other.isTerminated && NSRunningApplication.apps.allSatisfy(\.isTerminated), "explicit idle repair handles competing helper too")
        let diagnosing = fresh()
        let reservation = diagnosing.reserveDiagnostic()!
        check(diagnosing.reserveDiagnostic() == nil, "only one idle diagnostic owns the runtime")
        var taskBegan = false
        let pending = Task { let id = try await diagnosing.beginTask(configuration: configuration); taskBegan = true; return id }
        try await Task.sleep(for: .milliseconds(150))
        check(!taskBegan && NSWorkspace.shared.launches == 0, "new work waits for the check instead of competing for controls")
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancelled waiter started") } catch is CancellationError { checks += 1 }
        diagnosing.endDiagnostic(reservation)
        let next = try await diagnosing.beginTask(configuration: configuration)
        check(diagnosing.reserveDiagnostic() == nil, "normal task owns runtime after the check")
        diagnosing.endTask(next)
        let repair = fresh()
        let repairOwn = NSRunningApplication(configuration.appURL)
        let repairForeign = NSRunningApplication(URL(fileURLWithPath: "/another-app.app"))
        NSRunningApplication.apps = [repairOwn, repairForeign]
        CodexRuntime.exclusiveBusy = true
        do { try await repair.restart(configuration: configuration); fatalError("Cross-process task was restarted") }
        catch CodexRuntime.Failure.busy {}
        check(!repairOwn.isTerminated && !repairForeign.isTerminated, "restart also respects another process's runtime lease")
        do { try await repair.prepareForReinstall(configuration: configuration); fatalError("Another process's lease was ignored") }
        catch CodexRuntime.Failure.busy {}
        check(!repairOwn.isTerminated && !repairForeign.isTerminated, "a busy runtime prevents reinstall teardown")
        CodexRuntime.exclusiveBusy = false
        try await repair.prepareForReinstall(configuration: configuration)
        check(repairOwn.isTerminated && !repairForeign.isTerminated, "reinstall teardown stops only the private helper")
        print("PASS: \(checks) native startup race, retry and ownership checks")
    }
}
'''


def main():
    runtime = (APP / "Driver/OpenAIComputerUseRuntime.swift").read_text().replace("import AppKit", "")
    with tempfile.TemporaryDirectory(prefix="sentient-helper-startup-") as directory:
        root = Path(directory)
        source = root / "Startup.swift"
        source.write_text(STUBS + runtime + TESTS)
        binary = root / "startup"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-parse-as-library", str(source), "-o", str(binary)], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
