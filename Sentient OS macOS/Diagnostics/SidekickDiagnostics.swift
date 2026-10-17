// Content-free observability for Sidekick's conversation backend. No transcript or Error
// argument can cross this API; provider/tool diagnostics retain their existing owners.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation

nonisolated enum SidekickDiagnostics {
    enum Stage: String, CaseIterable, Sendable {
        case storeOpen = "store_open", storeRead = "store_read", storeWrite = "store_write"
        case migration, messageDelivery = "message_delivery", question, answer, attention
        case memoryRead = "memory_read", memoryWrite = "memory_write", context
        case historyRead = "history_read", compaction, task, reset
    }
    enum Outcome: String, CaseIterable, Sendable {
        case started, completed, skipped, stopped, interrupted, failed
    }
    enum Reason: String, CaseIterable, Sendable {
        case none, persistence, corruptStore = "corrupt_store", newerSchema = "newer_schema"
        case invalidInput = "invalid_input", changedDuplicate = "changed_duplicate"
        case staleGeneration = "stale_generation", staleAttempt = "stale_attempt", duplicate
        case interruptedMigration = "interrupted_migration", missingLegacyData = "missing_legacy_data"
        case readFailed = "read_failed", writeFailed = "write_failed", conflict, unavailable
        case missingFinalMessage = "missing_final_message", invalidSummary = "invalid_summary"
        case budgetExceeded = "budget_exceeded", sourceChanged = "source_changed"
        case foregroundBusy = "foreground_busy", alreadyCurrent = "already_current"
        case cancelled, stopped, interrupted, timeout, quota, providerFailure = "provider_failure"
        case deliveryFailed = "delivery_failed", contractViolation = "contract_violation"

        /// Ordinary lifecycle/control-flow outcomes are useful health signals, not defects.
        var expectedOutcome: Outcome? {
            switch self {
            case .stopped: .stopped
            case .interrupted, .interruptedMigration: .interrupted
            case .cancelled, .staleGeneration, .staleAttempt, .duplicate, .sourceChanged,
                 .foregroundBusy, .alreadyCurrent, .quota, .unavailable, .budgetExceeded, .conflict, .invalidInput: .skipped
            default: nil
            }
        }
    }
    enum Backend: String, CaseIterable, Sendable { case chatgpt, claude, custom, unknown }
    enum Source: String, CaseIterable, Sendable {
        case command, promptBar, notchTyped, voice, proactive, compactor, memoryEditor, startup, reset, unknown
    }
    enum Count: String, CaseIterable, Sendable {
        case events, messages, tasks, activities, questions, bytes, before, after, attempts, retries
        case coveredSequence = "covered_sequence", tailEvents = "tail_events"
        case inputTokens = "input_tokens", outputTokens = "output_tokens", budgetTokens = "budget_tokens"
        case retainedTurns = "retained_turns", omittedEvents = "omitted_events"
        case recoveredTasks = "recovered_tasks", migratedTasks = "migrated_tasks", generation
    }

    struct Payload: Sendable {
        let event: String
        let tags: [String: String]
        let extra: [String: String]
        let fingerprint: [String]
        let duration: TimeInterval?

        /// Per-task IDs help diagnose a defect, but add no value to aggregate product analytics.
        var analytics: [String: String] {
            tags.merging(extra.filter { $0.key != "task_id" && $0.key != "attempt_id" }) { _, new in new }
        }
    }

    static let failureCooldown: TimeInterval = 900
    // JSON/analytics numeric values remain exact and bounded even when a caller overflows a counter.
    static let maximumCount = 9_007_199_254_740_991
    static let maximumDuration: TimeInterval = 30 * 24 * 60 * 60

    /// Pure construction, shared by every sink. Invalid numbers reject the entire event;
    /// silently clamping would make performance and data-loss diagnostics misleading.
    static func payload(_ stage: Stage, outcome: Outcome, reason: Reason = .none,
                        taskID: UUID? = nil, attemptID: UUID? = nil,
                        backend: Backend = .unknown, source: Source = .unknown,
                        counts: [Count: Int] = [:], duration: TimeInterval? = nil) -> Payload? {
        guard counts.values.allSatisfy({ $0 >= 0 && $0 <= maximumCount }) else { return nil }
        if let duration {
            guard duration.isFinite, duration >= 0, duration <= maximumDuration else { return nil }
        }
        let name = outcome == .failed ? "sidekick.backend_failed" : "sidekick.backend"
        let tags = ["phase": stage.rawValue, "outcome": outcome.rawValue, "reason": reason.rawValue,
                    "backend": backend.rawValue, "source": source.rawValue, "diagnostic_schema": "1"]
        var extra = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, String($0.value)) })
        if let taskID { extra["task_id"] = taskID.uuidString }
        if let attemptID { extra["attempt_id"] = attemptID.uuidString }
        if let duration { extra["duration_ms"] = String(Int((duration * 1_000).rounded())) }
        return Payload(event: name, tags: tags, extra: extra,
            fingerprint: [name, stage.rawValue, reason.rawValue, backend.rawValue, source.rawValue], duration: duration)
    }

    /// Counts/durations supplement existing task-submission and task-end analytics; these
    /// events are always extended-tier. Call at meaningful commits/boundaries, never per token.
    @discardableResult
    static func event(_ stage: Stage, outcome: Outcome = .completed, reason: Reason = .none,
                      taskID: UUID? = nil, attemptID: UUID? = nil,
                      backend: Backend = .unknown, source: Source = .unknown,
                      counts: [Count: Int] = [:], duration: TimeInterval? = nil) -> Bool {
        if outcome == .failed {
            return failure(stage, reason: reason, taskID: taskID, attemptID: attemptID,
                           backend: backend, source: source, counts: counts, duration: duration)
        }
        guard let value = payload(stage, outcome: outcome, reason: reason, taskID: taskID, attemptID: attemptID,
                                  backend: backend, source: source, counts: counts, duration: duration) else { return false }
        recordHealth(value)
        return true
    }

    /// Deliberately accepts no Error: even an NSError domain or associated enum value can
    /// contain a private path, provider response, or message. Callers select a fixed reason.
    /// Existing Diagnostics/CrashReporting own operation deduplication and repeat cooldown.
    @discardableResult
    static func failure(_ stage: Stage, reason: Reason,
                        taskID: UUID? = nil, attemptID: UUID? = nil,
                        backend: Backend = .unknown, source: Source = .unknown,
                        counts: [Count: Int] = [:], duration: TimeInterval? = nil) -> Bool {
        guard reason != .none else { return false }
        if let expected = reason.expectedOutcome {
            return event(stage, outcome: expected, reason: reason, taskID: taskID, attemptID: attemptID,
                         backend: backend, source: source, counts: counts, duration: duration)
        }
        guard let value = payload(stage, outcome: .failed, reason: reason, taskID: taskID, attemptID: attemptID,
                                  backend: backend, source: source, counts: counts, duration: duration) else { return false }
        recordHealth(value)
        DiagnosticHistory.recordError(Diagnostics.Payload(event: value.event, tags: value.tags,
            extra: value.extra, fingerprint: value.fingerprint))
        CrashReporting.captureEvent(value.event, level: .warning, tags: value.tags, extra: value.extra,
            fingerprint: value.fingerprint, cooldown: failureCooldown)
        return true
    }

    private static func recordHealth(_ value: Payload) {
        // These existing sinks enforce their independent live consent and Release-only gates.
        CrashReporting.diagnosticBreadcrumb(value.event, data: value.tags.merging(value.extra) { _, new in new })
        Task { @MainActor in
            Analytics.signal("Sidekick.backend", parameters: value.analytics, floatValue: value.duration, tier: .extended)
        }
    }
}
