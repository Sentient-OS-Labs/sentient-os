// Runs Sentient-funded work under one server-authorized lease, including cancellation and waits.
// withRun joins a task's existing scope; validate refreshes the independently stored entitlement.
// Doc: Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md

import Foundation
import os

nonisolated enum HostedInference {
    enum Purpose: String, Codable, Sendable {
        case sidekick
        case background = "knowledge_update"
        case bootstrap = "knowledge_bootstrap"
    }

    struct Usage: Codable, Sendable, Equatable {
        let dailyLimitSeconds: TimeInterval
        let usedSeconds: TimeInterval
        let remainingSeconds: TimeInterval
        let resetAt: Date
        let policyVersion: String

        enum CodingKeys: String, CodingKey {
            case dailyLimitSeconds = "daily_limit_seconds", usedSeconds = "used_seconds"
            case remainingSeconds = "remaining_seconds", resetAt = "reset_at", policyVersion = "policy_version"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            dailyLimitSeconds = try values.decode(TimeInterval.self, forKey: .dailyLimitSeconds)
            usedSeconds = try values.decode(TimeInterval.self, forKey: .usedSeconds)
            remainingSeconds = try values.decode(TimeInterval.self, forKey: .remainingSeconds)
            resetAt = try values.decode(Date.self, forKey: .resetAt)
            if let text = try? values.decode(String.self, forKey: .policyVersion) { policyVersion = text }
            else { policyVersion = String(try values.decode(Int.self, forKey: .policyVersion)) }
        }
    }

    enum Failure: LocalizedError, Sendable, Equatable {
        case notConfigured, identity, keychain, unavailable, invalidResponse
        case rejected(code: String, resetAt: Date?)

        var isUsageLimit: Bool {
            guard case .rejected(let code, _) = self else { return false }
            return ["daily_allowance_exhausted", "daily_limit", "time_limit", "budget_exhausted", "user_budget_exhausted",
                    "global_budget_exhausted", "bootstrap_exhausted", "background_budget_exhausted", "quota_exhausted", "daily_time_exhausted", "usage_limit_reached", "service_budget_reached", "connector_usage_limit", "connector_service_budget"].contains(code)
        }

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sentient-hosted intelligence is not available in this build yet. Your existing AI options still work."
            case .identity: return "Your saved Sentient access could not be restored. Try again or contact support; your allowance has not been reset."
            case .keychain: return "Unlock your Mac and try again. Sentient could not access its saved credential."
            case .unavailable: return "Sentient-hosted intelligence is temporarily unavailable. Your work has been preserved."
            case .invalidResponse: return "Sentient could not verify its hosted connection. No further work was started."
            case .rejected(let code, _):
                if code == "connection_required" { return "This service needs a fresh sign-in. Reconnect it in Knowledge Sources; your reading choice is still saved." }
                if code == "connection_changed" { return "The connected account changed. Start a new task with the intended account." }
                if ["connector_usage_limit", "connector_service_budget"].contains(code) { return "The cloud-connection allowance is used up for now. Your saved read progress will resume when the allowance resets." }
                if code == "connector_rate_limited" { return "The connected service is receiving too many requests. Wait a moment, then try again." }
                if ["connectors_disabled", "connectors_not_configured", "connector_not_configured"].contains(code) { return "This hosted connection is not available in this build yet." }
                if code == "connector_contract_changed" { return "The service’s tool contract changed. Sentient needs a connector update before this task can continue." }
                if code == "cursor_expired" { return "The service’s saved read cursor expired. Retry analysis to restart the unfinished window." }
                if code == "resolution_not_ready" { return "This action is still settling. Stop its task and wait two minutes before reviewing the outcome." }
                if ["service_budget_reached", "global_budget_exhausted"].contains(code) {
                    return "Sentient's shared hosted allowance is currently unavailable. Try again later or choose your own AI."
                }
                if code == "request_rate_limited" { return "Too many hosted requests arrived at once. Wait a moment and try again." }
                if code == "service_disabled" { return "Sentient-hosted intelligence is temporarily unavailable. Choose your own AI in Settings to continue." }
                if isUsageLimit { return "Your included hosted usage is used up for now. Your work is saved. Check Sentient Settings for the next reset, or choose your own AI." }
                if ["run_busy", "concurrent_run", "request_in_flight"].contains(code) {
                    return "Another hosted task is still running. Stop it or wait for it to finish."
                }
                if ["run_expired", "lease_expired", "run_not_active"].contains(code) {
                    return "The hosted connection expired. Your task has stopped; check any unfinished action before continuing."
                }
                if ["authentication_required", "invalid_token", "identity_invalid"].contains(code) { return Failure.identity.errorDescription }
                return "Sentient cannot start more hosted work right now. Your work has been preserved."
            }
        }
    }

    @TaskLocal static var currentRun: Run?
    @TaskLocal static var clientOverride: HostedInferenceClient?
    static var isConfigured: Bool { HostedInferenceConfiguration.current != nil }

    static func validate() async throws -> Usage {
        try await (clientOverride ?? HostedInferenceClient.shared).usage()
    }

    /// A foreground scope spans routing, connector attempts and computer fallback. A background
    /// caller may join that scope, but a separate worker must clear currentRun before launching.
    static func withRun<T: Sendable>(purpose: Purpose,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard ModelBackend.current == .sentient else { return try await operation() }
        if currentRun != nil { return try await operation() }
        let client = clientOverride ?? HostedInferenceClient.shared
        let run = try await client.start(purpose: purpose)
        let interaction = SidekickInteraction.current
        interaction?.attachHostedRun(run)
        defer { interaction?.attachHostedRun(nil) }
        do {
            let value = try await $currentRun.withValue(run) {
                try await withThrowingTaskGroup(of: WorkResult<T>.self) { group in
                    group.addTask { .value(try await operation()) }
                    group.addTask {
                        try await run.monitor()
                        throw CancellationError()
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next(), case .value(let result) = first else {
                        throw Failure.unavailable
                    }
                    return result
                }
            }
            await run.finish()
            return value
        } catch {
            await run.finish()
            throw error
        }
    }

    private enum WorkResult<T: Sendable>: Sendable { case value(T) }

    /// Credentials are intentionally not Codable, printable or stored in defaults. The only
    /// consumer is the isolated Claude inference child; the provider key never reaches the Mac.
    final class Run: Sendable {
        let id: String
        let gatewayURL: URL
        let token: String
        let model: String
        let maximumOutputTokens: Int
        let remainingSeconds: TimeInterval
        let purpose: Purpose
        private let client: HostedInferenceClient
        private let state = OSAllocatedUnfairLock(initialState: (finished: false, paused: false, deadline: 0.0))

        init(id: String, gatewayURL: URL, token: String, model: String,
             remainingSeconds: TimeInterval, purpose: Purpose, client: HostedInferenceClient,
             deadline: TimeInterval, maximumOutputTokens: Int) {
            self.id = id; self.gatewayURL = gatewayURL; self.token = token; self.model = model
            self.remainingSeconds = remainingSeconds; self.purpose = purpose; self.client = client
            self.maximumOutputTokens = maximumOutputTokens
            state.withLock { $0.deadline = deadline }
        }

        func monitor() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    while true {
                        try await Task.sleep(for: .seconds(8))
                        try Task.checkCancellation()
                        if state.withLock({ $0.finished }) { return }
                        try await client.control(self, action: "heartbeat")
                    }
                }
                group.addTask { [self] in
                    while true {
                        let deadline = state.withLock { $0.deadline }
                        let remaining = deadline - ProcessInfo.processInfo.systemUptime
                        guard remaining > 0 else { throw Failure.rejected(code: "lease_expired", resetAt: nil) }
                        try await Task.sleep(for: .seconds(min(0.25, remaining)))
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }

        func renew(deadline: TimeInterval, paused: Bool) {
            state.withLock { $0.deadline = deadline; $0.paused = paused }
        }

        func pause() async throws {
            guard purpose == .sidekick, !state.withLock({ $0.finished || $0.paused }) else { return }
            // A completed tool block can reach Claude just before the gateway settles the
            // enclosing stream. Wait for that receipt, without excluding this active time.
            let retryUntil = ProcessInfo.processInfo.systemUptime + 5
            while true {
                do { try await client.control(self, action: "pause"); break }
                catch Failure.rejected(let code, _) where code == "run_busy"
                    && ProcessInfo.processInfo.systemUptime < retryUntil {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            state.withLock { $0.paused = true }
        }

        func resume() async throws {
            guard purpose == .sidekick, state.withLock({ $0.paused && !$0.finished }) else { return }
            try await client.control(self, action: "resume")
            state.withLock { $0.paused = false }
        }

        func finish() async {
            guard state.withLock({ state in
                guard !state.finished else { return false }; state.finished = true; return true
            }) else { return }
            // Cleanup must still run after the owning task is cancelled. Each HTTP request
            // has its own short timeout; a failed cleanup leaves a bounded expiring lease.
            let cleanup = Task.detached { [self] in try? await client.control(self, action: "finish") }
            await cleanup.value
        }
    }
}
