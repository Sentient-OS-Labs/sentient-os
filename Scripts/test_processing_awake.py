#!/usr/bin/env python3
"""Exercise production awake-hold recovery with inert, controllable helper replies.

No daemon registration, power changes, app launch or real preferences are involved.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def member(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


coordinator = (APP / "Ingestion/ProcessingCoordinator.swift").read_text()
helper = (APP / "Scheduling/WakeHelper.swift").read_text()
assert "await maintainAwake(for: id)" in member(coordinator, "private func perform(")
assert "await maintainAwake(for: runID)" in member(coordinator, "private func checkRunningWork(")
assert "SuspendingClock.now" in coordinator

fixture = r'''
import Foundation

@MainActor final class WakeHelperClient {
    static let shared = WakeHelperClient()
    var active = false
    var begins = 0, ends = 0, heartbeats = 0
    var blockBegin = false, blockHeartbeat = false, beginResult = true
    var beginPending: CheckedContinuation<Bool, Never>?
    var heartbeatPending: CheckedContinuation<Bool, Never>?
    func beginAwake(timeout: Int) async -> Bool {
        begins += 1
        active = true // The daemon can receive a request even if its reply times out.
        if blockBegin { return await withCheckedContinuation { beginPending = $0 } }
        return beginResult
    }
    func heartbeat() async -> Bool {
        heartbeats += 1
        if blockHeartbeat { return await withCheckedContinuation { heartbeatPending = $0 } }
        return active
    }
    func endAwake() async -> Bool { ends += 1; active = false; return true }
    func reset() {
        active = false; begins = 0; ends = 0; heartbeats = 0
        blockBegin = false; blockHeartbeat = false; beginResult = true
        beginPending = nil; heartbeatPending = nil
    }
}

@MainActor final class Coordinator {
    enum Trigger { case manual, onboarding, overnight }
    enum Status { case running, paused }
    struct Record { var trigger = Trigger.onboarding; var status = Status.running }
    struct Request { var fullCycle = true }
    struct Power { var onAC = true }
    var record = Record()
    var activeRequest: Request? = Request()
    var power = Power()
    var initialComplete = false
    var runID = UUID()
    var stopReason: String?
    var lastHeartbeatAt = Date.distantPast
    var helperHeld = false
    var helperRelease: Task<Void, Never>?
    var awakeUpdate: Task<Bool, Never>?
    __COORDINATOR__
    var needsHold: Bool { needsAwakeProtection }
    func maintain() async -> Bool { await maintainAwake(for: runID) }
    func release() async { await releaseAwake() }
}

final class RootHeartbeat {
    let queue = DispatchQueue(label: "fixture.heartbeat")
    var prepared = true, removing = false, holdingAwake = false
    var lastTimeout = 1800, timerStarts = 0
    func startDeadman(seconds: Int) { timerStarts += 1 }
    __HEARTBEAT__
    func check() async -> Bool {
        await withCheckedContinuation { continuation in
            heartbeat { continuation.resume(returning: $0) }
        }
    }
}

@main @MainActor struct Tests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
    }
    static func until(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Fixture did not reach its expected await")
    }
    static func main() async throws {
        let helper = WakeHelperClient.shared
        let first = Coordinator()
        check(first.needsHold, "first full analysis on power requests closed-lid protection")
        check(await first.maintain(), "initial awake hold succeeds")
        check(helper.begins == 1 && helper.active, "one initial acquire")
        check(await first.maintain(), "live heartbeat succeeds")
        check(helper.begins == 1, "heartbeat preserves the original awake ceiling")
        helper.active = false // Model a daemon restart that restored normal sleep.
        check(await first.maintain(), "lost hold recovers")
        check(helper.begins == 2 && helper.active, "recovery actually reacquires sleep protection")
        await first.release()
        check(!helper.active && !first.helperHeld, "completion releases the hold")
        first.power.onAC = false
        check(!first.needsHold, "first analysis does not keep a closed laptop awake on battery")
        first.record.trigger = .overnight
        check(first.needsHold, "scheduled run keeps its separately admitted battery policy")
        first.record.trigger = .manual; first.power.onAC = true; first.initialComplete = true
        check(!first.needsHold, "ordinary later manual analysis retains its idle-sleep policy")
        first.initialComplete = false; first.activeRequest?.fullCycle = false
        check(!first.needsHold, "partial developer passes do not acquire first-analysis protection")

        helper.reset(); helper.blockBegin = true
        let paused = Coordinator()
        let starting = Task { await paused.maintain() }
        try await until { helper.beginPending != nil }
        let joined = Task { await paused.maintain() }
        paused.stopReason = "user"; paused.record.status = .paused
        let cleanup = Task { await paused.release() }
        helper.beginPending?.resume(returning: true); helper.beginPending = nil
        _ = await starting.value; _ = await joined.value; await cleanup.value
        check(helper.begins == 1, "overlapping acquire requests coalesce")
        check(helper.ends == 1 && !helper.active, "Pause drains and releases a late successful acquire")

        helper.reset(); helper.beginResult = false
        let uncertain = Coordinator()
        check(!(await uncertain.maintain()), "failed reply remains a failure")
        await uncertain.release()
        check(helper.ends == 1 && !helper.active, "failed reply still cleans up a possible daemon-side hold")

        helper.reset()
        let stopping = Coordinator()
        check(await stopping.maintain(), "prepare active run")
        helper.blockHeartbeat = true
        let heartbeat = Task { await stopping.maintain() }
        try await until { helper.heartbeatPending != nil }
        stopping.stopReason = "user"; stopping.record.status = .paused
        let stoppedCleanup = Task { await stopping.release() }
        helper.heartbeatPending?.resume(returning: false); helper.heartbeatPending = nil
        _ = await heartbeat.value; await stoppedCleanup.value
        check(helper.begins == 1 && !helper.active, "Pause during failed heartbeat cannot reacquire a hold")

        let root = RootHeartbeat()
        check(!(await root.check()), "restarted helper reports that its awake hold was lost")
        check(root.timerStarts == 0, "idle heartbeat cannot create an awake session")
        root.holdingAwake = true
        check(await root.check(), "existing root awake hold accepts heartbeat")
        check(root.timerStarts == 1, "live heartbeat refreshes the deadman")
        root.removing = true
        check(!(await root.check()), "uninstall cannot revive an awake session")
        print("PASS \(checks) awake-hold lifecycle checks")
    }
}
'''
methods = "\n".join(member(coordinator, name) for name in (
    "private var needsAwakeProtection:", "private func maintainAwake(", "private func releaseAwake("))
fixture = fixture.replace("__COORDINATOR__", methods).replace("__HEARTBEAT__", member(helper, "func heartbeat("))
with tempfile.TemporaryDirectory(prefix="sentient-awake-tests-") as directory:
    root = Path(directory)
    source = root / "AwakeTests.swift"
    source.write_text(fixture)
    binary = root / "awake-tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=15)
