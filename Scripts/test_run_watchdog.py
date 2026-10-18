#!/usr/bin/env python3
"""Exercise real process/watchdog timeout and cancellation without a provider or network.

Compiles the complete RunWatchdog and ClaudeSubscriptionTimeouts production types plus
the exact CodexCLI process methods shared by Codex and Claude. Runtime/auth/telemetry
dependencies are inert. Children are local Python fixtures, never a real CLI or app.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    depth = 0
    for opening in range(start, len(source)):
        depth += (source[opening] == "(") - (source[opening] == ")")
        if source[opening] == "{" and depth == 0:
            break
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


cli = (APP / "Cloud/CodexCLI.swift").read_text()
production = "import Foundation\nimport Darwin\nimport os\nnonisolated enum CodexCLI {\n"
production += "enum CLIError: Error { case launchFailed(String), timedOut(after: TimeInterval) }\n"
production += "\n".join(declaration(cli, name) for name in [
    "struct ExecResult:", "static func richEnvironment(", "private final class PipeDrain:",
    "private final class ProcHolder:", "private final class LineSink:",
    "static func executeAsync(", "private static func execute(", "static func executeStreaming(",
]) + "\n}\n"
direct = (APP / "Connectors/DirectMCPRuntime.swift").read_text()
production += "nonisolated enum DirectMCPRuntime {\n" + declaration(direct, "static func authorizationLeaseDuration(") + "\n}\n"

SUPPORT = r'''
import Foundation
import os

nonisolated enum CustomProvider {
    static let apiKeyEnvName = "FIXTURE_KEY", apiKeyEnvValue = "unused"
}
nonisolated enum CodexRuntime {
    final class FileLock: Sendable { func unlock() { } }
    static let executable = URL(fileURLWithPath: "/fixture-no-real-codex")
    static func executionLease(for binary: String, cancelled: @Sendable () -> Bool) throws -> FileLock? {
        if cancelled() { throw CancellationError() }; return nil
    }
    static func verifyCLIForLaunch() throws { fatalError("No real CLI should launch") }
    static func arguments(_ args: [String], binary: String) -> [String] { args }
    static func environment(_ env: [String:String], binary: String) -> [String:String] { env }
}
nonisolated enum ChildProcessDiagnostics {
    final class Stops: Sendable { func record(_ pid: Int32) { } }
    static let environmentKey = "FIXTURE_DIAGNOSTIC_DIRECTORY"
    @TaskLocal static var directory: URL?
    @TaskLocal static var intentionalStops: Stops?
}
nonisolated final class AgentRunDiagnostics: Sendable {
    static let current: AgentRunDiagnostics? = nil
    func observe(_ line: String) { }
}
nonisolated final class SidekickInteraction: Sendable {
    @TaskLocal static var current: SidekickInteraction?
    private let waiting = OSAllocatedUnfairLock(initialState: (total: TimeInterval(0), began: TimeInterval?.none))
    var waitingSeconds: TimeInterval {
        waiting.withLock { $0.total + ($0.began.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0) }
    }
    func setWaiting(_ active: Bool) {
        waiting.withLock { state in
            if active, state.began == nil { state.began = ProcessInfo.processInfo.systemUptime }
            else if !active, let began = state.began {
                state.total += ProcessInfo.processInfo.systemUptime - began; state.began = nil
            }
        }
    }
    func observeToolEvent(_ line: String, streamID: UUID) throws { }
    func endExecution(streamID: UUID) { }
}
actor Latch {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signaled = true
        let old = waiters; waiters.removeAll()
        old.forEach { $0.resume() }
    }
}
'''

TESTS = r'''
import Foundation
import Darwin
import os

@main struct Tests {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        let unlimited = ClaudeSubscriptionTimeouts(execution: 0, waitingAllowance: 0)
        check(unlimited.childExecution == 0 && unlimited.helperExecution == 0,
              "Bridge cleanup grace must not turn unlimited into a five-second cap")
        check(unlimited.transport == 1800 && unlimited.transportMilliseconds == 1_800_000,
              "Unlimited execution must retain a finite individual transport budget")
        let question = ClaudeSubscriptionTimeouts(execution: 0, waitingAllowance: 86_400)
        check(question.childExecution == 0 && question.helperExecution == 0,
              "Question allowance must not create a 24-hour total execution cap")
        check(question.transportMilliseconds == 88_200_000,
              "Question transport keeps the existing finite reply allowance")
        let bounded = ClaudeSubscriptionTimeouts(execution: 60, waitingAllowance: 86_400)
        check(bounded.childExecution == 86_460 && bounded.helperExecution == 65,
              "Bounded helper and child budgets retain existing grace semantics")
        check(bounded.transportMilliseconds == 86_460_000,
              "Positive background budget remains unchanged")
        let huge = ClaudeSubscriptionTimeouts(execution: 1e20, waitingAllowance: 0)
        check(huge.transportMilliseconds == Int(Int32.max), "Timer milliseconds do not overflow an integer")
        let encoded = try JSONEncoder().encode(["timeout": unlimited.childExecution])
        check(String(decoding: encoded, as: UTF8.self).contains("0"), "Unlimited helper execution survives JSON without infinity")
        check(DirectMCPRuntime.authorizationLeaseDuration(executionTimeout: 0) == 21_630,
              "Unlimited execution retains the existing finite connector credential lease")
        check(DirectMCPRuntime.authorizationLeaseDuration(executionTimeout: 300) == 330,
              "Bounded connector credential leases remain unchanged")
        check(DirectMCPRuntime.authorizationLeaseDuration(executionTimeout: 86_400) == 21_630,
              "Long finite execution never extends connector authorization past the existing cap")

        // A zero watchdog is completely dormant, with or without a live interaction.
        let callbacks = OSAllocatedUnfairLock(initialState: 0)
        let idle = RunWatchdog(timeout: 0, interaction: nil) { callbacks.withLock { $0 += 1 } }
        let interactive = RunWatchdog(timeout: 0, interaction: SidekickInteraction()) { callbacks.withLock { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(350))
        check(callbacks.withLock { $0 } == 0, "Zero budget must never schedule elapsed-time termination")
        idle.cancel(); interactive.cancel(); idle.cancel()
        check(callbacks.withLock { $0 } == 0, "Cancelling dormant watchdog is safe and idempotent")

        let positiveFired = Latch()
        let positive = RunWatchdog(timeout: 0.06, interaction: nil) {
            callbacks.withLock { $0 += 1 }; Task { await positiveFired.signal() }
        }
        await positiveFired.wait()
        try await Task.sleep(for: .milliseconds(100))
        check(callbacks.withLock { $0 } == 1, "Positive budget still expires exactly once")
        positive.cancel()
        let suppressed = RunWatchdog(timeout: 0.1, interaction: nil) { callbacks.withLock { $0 += 100 } }
        suppressed.cancel()
        try await Task.sleep(for: .milliseconds(160))
        check(callbacks.withLock { $0 } == 1, "Explicit cancellation suppresses later watchdog callback")

        let interaction = SidekickInteraction()
        interaction.setWaiting(true)
        let resumedFired = Latch()
        let paused = RunWatchdog(timeout: 0.08, interaction: interaction) {
            callbacks.withLock { $0 += 1 }; Task { await resumedFired.signal() }
        }
        try await Task.sleep(for: .milliseconds(350))
        check(callbacks.withLock { $0 } == 1, "Bounded execution still excludes waiting-for-user time")
        interaction.setWaiting(false)
        await resumedFired.wait()
        check(callbacks.withLock { $0 } == 2, "Positive budget resumes after the user responds")
        paused.cancel()

        let python = ProcessInfo.processInfo.environment["FIXTURE_PYTHON"]!
        let finite = ["-c", "import time; print('ready', flush=True); time.sleep(0.3); print('completed café', flush=True)"]
        let slow = ["-c", "import time; print('ready', flush=True); time.sleep(60)"]
        for streaming in [false, true] {
            let label = streaming ? "streaming computer runner" : "structured Codex/Claude runner"
            let result: CodexCLI.ExecResult
            if streaming {
                result = try await CodexCLI.executeStreaming(binary: python, args: finite, timeout: 0) { _ in }
            } else {
                result = try await CodexCLI.executeAsync(binary: python, args: finite, stdinText: nil, cwd: nil, timeout: 0)
            }
            check(result.status == 0 && result.stdout.contains("completed café"), "\(label) survives elapsed time with zero budget")
            do {
                if streaming { _ = try await CodexCLI.executeStreaming(binary: python, args: slow, timeout: 0.08) { _ in } }
                else { _ = try await CodexCLI.executeAsync(binary: python, args: slow, stdinText: nil, cwd: nil, timeout: 0.08) }
                preconditionFailure("\(label) ignored a finite budget")
            } catch CodexCLI.CLIError.timedOut(let timeout) {
                check(timeout == 0.08, "\(label) preserves bounded timeout classification")
            }
            let started = Latch()
            let run = Task {
                if streaming {
                    return try await CodexCLI.executeStreaming(binary: python, args: slow, timeout: 0) { line in
                        if line == "ready" { Task { await started.signal() } }
                    }
                } else {
                    return try await CodexCLI.executeAsync(binary: python, args: slow, stdinText: nil, cwd: nil, timeout: 0,
                        onStdoutLine: { line in if line == "ready" { Task { await started.signal() } } })
                }
            }
            await started.wait()
            let began = ContinuousClock.now
            run.cancel()
            let stopped = try await run.value
            check(stopped.status != 0, "\(label) still terminates the actual child on explicit cancellation")
            check(began.duration(to: .now) < .seconds(4), "\(label) cancellation drains without awaiting the fixture's 60 seconds")
        }
        print("Run watchdog and shared process execution: \(checks) assertions passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-watchdog-tests-") as directory:
    root = Path(directory)
    (root / "Process.swift").write_text(production)
    (root / "Support.swift").write_text(SUPPORT)
    (root / "Tests.swift").write_text(TESTS)
    binary = root / "watchdog-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
        str(APP / "Cloud/RunWatchdog.swift"), str(APP / "Cloud/ClaudeSubscriptionTimeouts.swift"),
        str(root / "Process.swift"), str(root / "Support.swift"), str(root / "Tests.swift"),
        "-o", str(binary),
    ], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30,
                   env={**os.environ, "FIXTURE_PYTHON": sys.executable})
