// Durable analysis intent, independent of onboarding and window lifetime. A single record
// survives relaunch; ingestion checkpoints remain in CycleStore. Doc: Documentation - Ingestion Pipeline.md

import Foundation

enum ProcessingPlan {
    static let key = "processing.plan"
    // Retain the shipped key so existing installations keep their first-analysis milestone.
    static let initialCompletedKey = "scheduler.firstCycleCompletedAt"
    static let cadenceKey = "processing.cadence"

    enum Status: String, Codable, Sendable { case idle, scheduled, requested, running, awaitingIdle, paused, failed, completed }
    enum Trigger: String, Codable, Sendable {
        case onboarding, manual, overnight, pluggedInIdle, developer
        var isAutomatic: Bool { self == .overnight || self == .pluggedInIdle }
        var diagnostic: CodexTrigger {
            switch self {
            case .onboarding: .onboarding
            case .manual, .developer: .analyzeNow
            case .overnight: .overnight
            case .pluggedInIdle: .pluggedInIdle
            }
        }
    }
    struct Record: Codable, Equatable, Sendable {
        var status: Status = .idle
        var trigger: Trigger = .manual
        var due: Date?
        var notice: String?
        // Optional fields keep records from older releases decodable. Resumed segments retain
        // their original start and accumulated active time; waiting never consumes the budget.
        var startedAt: Date?
        var activeSeconds: TimeInterval?
    }

    struct Cadence: Codable, Equatable {
        var lastStartedAt: Date?
        var lastSuccessfulStart: Date?
        var retryAfter: Date?

        /// A corrected wall clock must not strand analysis behind a future timestamp. Retain
        /// a conservative interval from the correction rather than replaying overdue windows.
        func adjustingFutureDates(to now: Date, maximumDelay: TimeInterval) -> Self {
            var adjusted = self
            if let lastStartedAt, lastStartedAt > now { adjusted.lastStartedAt = now }
            if let lastSuccessfulStart, lastSuccessfulStart > now { adjusted.lastSuccessfulStart = now }
            if let retryAfter, retryAfter > now.addingTimeInterval(maximumDelay) {
                adjusted.retryAfter = now.addingTimeInterval(maximumDelay)
            }
            return adjusted
        }
    }

    static func cadence(_ defaults: UserDefaults = .standard) -> Cadence {
        if let data = defaults.data(forKey: cadenceKey),
           let saved = try? JSONDecoder().decode(Cadence.self, from: data) { return saved }
        // Older installations only have a completion stamp. Seed conservatively once; all new
        // full runs record their actual start at the shared coordinator boundary.
        let legacy = (defaults.object(forKey: ProactiveCycle.lastCycleKey) as? Date) ?? initialCompletedAt(defaults)
        return Cadence(lastStartedAt: legacy, lastSuccessfulStart: legacy)
    }

    static func saveCadence(_ cadence: Cadence, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(cadence) { defaults.set(data, forKey: cadenceKey) }
    }

    static func read(_ defaults: UserDefaults = .standard) -> Record {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
        return record
    }

    static func save(_ record: Record, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key) }
    }

    static func initialCompletedAt(_ defaults: UserDefaults = .standard) -> Date? {
        let epoch = defaults.double(forKey: initialCompletedKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }

    static func completeInitial(_ defaults: UserDefaults = .standard, at date: Date = Date()) {
        if initialCompletedAt(defaults) == nil { defaults.set(date.timeIntervalSince1970, forKey: initialCompletedKey) }
    }

    /// Initial creation waits for explicit resume after relaunch. Later unattended work keeps
    /// its schedule; later foreground work retains the existing recovery behavior.
    static func recovered(_ record: Record, initialComplete: Bool = true) -> Record {
        if !initialComplete, [.running, .scheduled, .requested, .awaitingIdle].contains(record.status) {
            var recovered = record
            recovered.status = .paused
            recovered.due = nil
            recovered.notice = "Analysis is paused. Resume when you’re ready; saved on-device work is kept and unfinished cloud steps restart safely."
            return recovered
        }
        if record.trigger == .pluggedInIdle, [.running, .requested].contains(record.status) {
            var recovered = record
            recovered.status = .awaitingIdle
            recovered.due = nil
            return recovered
        }
        guard record.status == .running else { return record }
        var recovered = record
        recovered.status = record.trigger == .overnight ? .scheduled : .requested
        recovered.notice = "Analysis was interrupted. Your progress is saved."
        return recovered
    }
}
