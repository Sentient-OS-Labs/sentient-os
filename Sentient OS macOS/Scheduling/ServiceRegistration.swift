// Serial, off-main access to macOS service registration for the wake helper and login item.
// Coalesces requests, bounds caller waits, caches status and backs off failures without queueing
// more work behind a system call that has not returned. Doc: Documentation - Overnight Scheduler & Wake Helper.md

import Foundation
import ServiceManagement
import Observation

@MainActor @Observable
final class ServiceRegistration {
    nonisolated enum Kind: Sendable { case wakeHelper, loginItem }
    nonisolated enum Action: Sendable { case status, register, unregister }
    nonisolated struct Result: Sendable {
        let rawStatus: Int?
        var error: (any Error)?
        static let unavailable = Result(rawStatus: nil)
    }

    private(set) var cachedStatus: SMAppService.Status?
    @ObservationIgnored private let kind: Kind
    @ObservationIgnored private let timeout: TimeInterval
    @ObservationIgnored private let worker = DispatchQueue(label: "sentient.service-registration", qos: .utility)
    @ObservationIgnored private let execute: @Sendable (Action) -> Result
    @ObservationIgnored private var validUntil: TimeInterval = 0
    @ObservationIgnored private var retryAfter: TimeInterval = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var deadline: Task<Void, Never>?
    private struct Active {
        let id: UUID
        let action: Action
        let began: TimeInterval
        var timedOut = false
        var waiters: [CheckedContinuation<Result, Never>] = []
    }
    @ObservationIgnored private var active: Active?

    init(kind: Kind, timeout: TimeInterval = 5, execute: (@Sendable (Action) -> Result)? = nil) {
        self.kind = kind
        self.timeout = timeout
        self.execute = execute ?? { Self.execute($0, kind: kind) }
    }

    func refresh(force: Bool = false) async -> SMAppService.Status? {
        let result = await perform(.status, force: force)
        return result.rawStatus.flatMap(SMAppService.Status.init(rawValue:))
    }

    func perform(_ action: Action, force: Bool = false) async -> Result {
        if let current = active {
            if current.timedOut { return .unavailable }
            let result = await join()
            // Read callers can share a mutation's resulting status. Different mutations wait
            // for actual completion; timeout never permits another queued system operation.
            if action == .status || current.action == action { return result }
            guard active == nil else { return .unavailable }
            return await perform(action, force: true)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if action == .status {
            guard now >= retryAfter else { return .unavailable }
            if !force, now < validUntil, let cachedStatus { return Result(rawStatus: cachedStatus.rawValue) }
        } else {
            cachedStatus = nil
            validUntil = 0
        }
        let id = UUID()
        active = Active(id: id, action: action, began: now)
        let execute = execute
        worker.async { [self] in
            let result = execute(action)
            Task { @MainActor in self.complete(id, result: result) }
        }
        let seconds = action == .status ? timeout : max(timeout, 30)
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.expire(id, seconds: seconds)
        }
        return await join()
    }

    private func join() async -> Result {
        guard active?.timedOut == false else { return .unavailable }
        return await withCheckedContinuation { active?.waiters.append($0) }
    }

    private func expire(_ id: UUID, seconds: TimeInterval) {
        guard var current = active, current.id == id else { return }
        current.timedOut = true
        let waiters = current.waiters
        current.waiters.removeAll()
        active = current // Keep the slot occupied until the uncancellable OS call actually returns.
        cachedStatus = nil
        backOff()
        waiters.forEach { $0.resume(returning: .unavailable) }
        Diagnostics.report(.serviceFailed, phase: .probe, reason: "service_response_timeout",
                           source: kind == .wakeHelper ? "wakeHelper" : "app", counts: [.deadlineMS: Int(seconds * 1000)])
    }

    private func complete(_ id: UUID, result: Result) {
        guard let current = active, current.id == id else { return }
        deadline?.cancel(); deadline = nil
        active = nil
        let now = ProcessInfo.processInfo.systemUptime
        cachedStatus = result.rawStatus.flatMap(SMAppService.Status.init(rawValue:))
        if let status = cachedStatus, status != .notFound {
            failures = 0; retryAfter = 0
            validUntil = now + (status == .requiresApproval ? 2 : (status == .enabled ? 10 : 30))
        } else { backOff() }
        if current.timedOut {
            CrashReporting.diagnosticBreadcrumb("service.response_recovered", data: [
                "source": kind == .wakeHelper ? "wakeHelper" : "app",
                "elapsed_ms": String(Int(max(0, now - current.began) * 1000)),
                "status": result.rawStatus.map(String.init) ?? "unavailable"])
        }
        current.waiters.forEach { $0.resume(returning: result) }
    }

    private func backOff() {
        failures = min(failures + 1, 5)
        retryAfter = ProcessInfo.processInfo.systemUptime + min(300, 15 * pow(2, Double(failures - 1)))
        validUntil = 0
    }

    /// Called exclusively on the serial utility queue. Never transfer an SMAppService across executors.
    nonisolated private static func execute(_ action: Action, kind: Kind) -> Result {
        let service = kind == .wakeHelper ? SMAppService.daemon(plistName: WakeHelperConfig.daemonPlistName) : .mainApp
        let status = service.status
        do {
            switch action {
            case .status: return Result(rawStatus: status.rawValue)
            case .register:
                if status == .enabled || status == .requiresApproval { return Result(rawStatus: status.rawValue) }
                try service.register()
            case .unregister:
                if status == .notRegistered { return Result(rawStatus: status.rawValue) }
                try service.unregister()
            }
            return Result(rawStatus: service.status.rawValue)
        } catch {
            return Result(rawStatus: service.status.rawValue, error: error)
        }
    }
}
