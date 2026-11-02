#!/usr/bin/env python3
"""Compile the production registration worker against an injected, controllable macOS reply.
No login-item registration, privileged helper, Sentry transport or application launch occurs.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
SUPPORT = r'''
import Foundation
import Synchronization
import ServiceManagement
nonisolated enum WakeHelperConfig { static let daemonPlistName = "fixture.invalid.plist" }
@MainActor enum Diagnostics {
    enum Event { case serviceFailed }; enum Phase { case probe }; enum Count { case deadlineMS }
    static var timeouts = 0
    static func report(_ event: Event, phase: Phase, reason: String, source: String, counts: [Count: Int]) {
        precondition(reason == "service_response_timeout"); timeouts += 1
    }
}
@MainActor enum CrashReporting {
    static var recovered = 0
    static func diagnosticBreadcrumb(_ name: String, data: [String: String]) { recovered += 1 }
}
nonisolated final class Reply: Sendable {
    let gate = DispatchSemaphore(value: 0)
    let calls = Mutex<[ServiceRegistration.Action]>([])
    let status: Int
    let blocked: Bool
    init(_ status: Int, blocked: Bool = true) { self.status = status; self.blocked = blocked }
    func execute(_ action: ServiceRegistration.Action) -> ServiceRegistration.Result {
        precondition(!Thread.isMainThread, "ServiceManagement must never run on the main thread")
        calls.withLock { $0.append(action) }
        if blocked { gate.wait() }
        return .init(rawStatus: status)
    }
}
@MainActor final class WakeHealth {
    enum DaemonHealth { case ready, requiresApproval, notSetUp, unavailable }
    final class Helper { func prepare(withReply: (Bool) -> Void) {} }
    let registration: ServiceRegistration
    var removing = false
    var probing: Task<DaemonHealth, Never>?
    var healthRetryAfter: TimeInterval = 0
    var healthFailures = 0
    var replies = 0
    var pending: CheckedContinuation<Bool, Never>?
    init(_ registration: ServiceRegistration) { self.registration = registration }
    func call(quiet: Bool, _ body: (Helper, @escaping (Bool) -> Void) -> Void) async -> Bool {
        replies += 1
        return await withCheckedContinuation { pending = $0 }
    }
    __HEALTH_PROBE__
    __CHECK_HEALTH__
}
'''


def declaration(source, marker):
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


client = (APP / "Scheduling/WakeHelperClient.swift").read_text()
SUPPORT = SUPPORT.replace("__HEALTH_PROBE__", declaration(client, "func healthProbe("))
SUPPORT = SUPPORT.replace("__CHECK_HEALTH__", declaration(client, "private func checkHealth("))
TESTS = r'''
import Foundation
import ServiceManagement
@main @MainActor struct Tests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(20)) }
    static func main() async throws {
        let reply = Reply(SMAppService.Status.enabled.rawValue)
        let service = ServiceRegistration(kind: .wakeHelper, timeout: 0.08, execute: reply.execute)
        let tasks = (0..<40).map { _ in Task { await service.refresh() } }
        try await settle()
        check(reply.calls.withLock { $0.count } == 1, "40 callers share one blocking system query")
        check(service.cachedStatus == nil, "a pending query never claims readiness")
        // Executing here while the worker is blocked proves the main actor remains responsive.
        for task in tasks { check(await task.value == nil, "every waiter gets a bounded unavailable result") }
        check(Diagnostics.timeouts == 1, "one stalled query produces one diagnostic")
        for _ in 0..<40 {
            check(await service.refresh(force: true) == nil, "force cannot queue behind a timed-out system call")
        }
        check(await service.perform(.register).rawStatus == nil, "mutation cannot pile up behind a stalled read")
        check(reply.calls.withLock { $0.count } == 1, "timeouts never spawn replacement blocked workers")
        reply.gate.signal()
        try await settle()
        check(service.cachedStatus == .enabled && CrashReporting.recovered == 1, "late replies restore readiness once")
        check(await service.refresh() == .enabled, "successful status is cached")
        check(reply.calls.withLock { $0.count } == 1, "cached reads do not touch macOS")
        let forced = Task { await service.refresh(force: true) }
        try await settle()
        check(reply.calls.withLock { $0.count } == 2, "new work starts only after actual completion")
        reply.gate.signal()
        check(await forced.value == .enabled, "forced refresh receives fresh status")

        let unavailable = Reply(SMAppService.Status.notFound.rawValue, blocked: false)
        let failing = ServiceRegistration(kind: .loginItem, execute: unavailable.execute)
        check(await failing.refresh() == .notFound, "unavailable registration is preserved")
        check(await failing.refresh(force: true) == nil, "passive errors back off even for force refresh")
        check(unavailable.calls.withLock { $0.count } == 1, "backoff suppresses repeated OS calls")
        _ = await failing.perform(.register)
        check(unavailable.calls.withLock { $0.count } == 2, "explicit setup can retry after a completed failure")

        let ordered = Reply(SMAppService.Status.requiresApproval.rawValue)
        let serial = ServiceRegistration(kind: .loginItem, execute: ordered.execute)
        let read = Task { await serial.refresh() }
        try await settle()
        let register = Task { await serial.perform(.register) }
        try await settle()
        check(ordered.calls.withLock { $0 == [.status] }, "mutation waits for current status query")
        ordered.gate.signal()
        check(await read.value == .requiresApproval, "approval remains a distinct state")
        try await settle()
        check(ordered.calls.withLock { $0 == [.status, .register] }, "different action runs after completion")
        let anotherRegister = Task { await serial.perform(.register) }
        let concurrentRead = Task { await serial.refresh() }
        try await settle()
        ordered.gate.signal()
        check(await register.value.rawStatus == SMAppService.Status.requiresApproval.rawValue, "registration result is authoritative")
        check(await anotherRegister.value.rawStatus == SMAppService.Status.requiresApproval.rawValue, "duplicate mutation coalesces")
        check(await concurrentRead.value == .requiresApproval, "read shares mutation result")
        check(ordered.calls.withLock { $0.count } == 2, "no redundant mutation or follow-up query")

        let ready = Reply(SMAppService.Status.enabled.rawValue, blocked: false)
        let health = WakeHealth(ServiceRegistration(kind: .wakeHelper, execute: ready.execute))
        let probes = (0..<40).map { _ in Task { await health.healthProbe() } }
        try await settle()
        check(health.replies == 1, "concurrent health callers share one helper XPC probe")
        health.pending?.resume(returning: false); health.pending = nil
        for probe in probes { check(await probe.value == .unavailable, "failed helper response never claims readiness") }
        for _ in 0..<40 { check(await health.healthProbe() == .unavailable, "failed helper probes back off") }
        check(health.replies == 1, "passive health polling does not hammer an unavailable helper")
        health.healthRetryAfter = 0
        let first = Task { await health.healthProbe() }
        let second = Task { await health.healthProbe() }
        try await settle()
        health.removing = true
        health.pending?.resume(returning: true); health.pending = nil
        let firstResult = await first.value
        let secondResult = await second.value
        check(firstResult == .unavailable && secondResult == .unavailable, "late success cannot restore readiness during removal")
        let approvalReply = Reply(SMAppService.Status.requiresApproval.rawValue, blocked: false)
        let approval = WakeHealth(ServiceRegistration(kind: .wakeHelper, execute: approvalReply.execute))
        check(await approval.healthProbe() == .requiresApproval && approval.replies == 0, "unapproved helpers never receive XPC readiness probes")
        print("PASS \(checks) service registration checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-service-tests-") as directory:
    folder = Path(directory)
    (folder / "Support.swift").write_text(SUPPORT)
    (folder / "Tests.swift").write_text(TESTS)
    binary = folder / "tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    str(APP / "Scheduling/ServiceRegistration.swift"), str(folder / "Support.swift"),
                    str(folder / "Tests.swift"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
