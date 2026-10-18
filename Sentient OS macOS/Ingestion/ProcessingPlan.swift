// Durable analysis intent, independent of onboarding and window lifetime. A single record
// survives relaunch; ingestion checkpoints remain in CycleStore. Doc: Documentation - Ingestion Pipeline.md

import Foundation

enum ProcessingPlan {
    static let key = "processing.plan"
    // Retain the shipped key so existing installations keep their first-analysis milestone.
    static let initialCompletedKey = "scheduler.firstCycleCompletedAt"

    enum Status: String, Codable, Sendable { case idle, scheduled, requested, running, paused, failed, completed }
    enum Trigger: String, Codable, Sendable {
        case onboarding, manual, overnight, developer
        var diagnostic: CodexTrigger {
            switch self {
            case .onboarding: .onboarding
            case .manual, .developer: .analyzeNow
            case .overnight: .overnight
            }
        }
    }
    struct Record: Codable, Equatable, Sendable {
        var status: Status = .idle
        var trigger: Trigger = .manual
        var due: Date?
        var notice: String?
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

    /// Interrupted foreground work resumes. Unattended work stays in its overnight schedule.
    static func recovered(_ record: Record) -> Record {
        guard record.status == .running else { return record }
        var recovered = record
        recovered.status = record.trigger == .overnight ? .scheduled : .requested
        recovered.notice = "Analysis was interrupted. Your progress is saved."
        return recovered
    }
}
