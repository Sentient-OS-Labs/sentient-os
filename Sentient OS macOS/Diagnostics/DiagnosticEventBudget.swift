// Durable, bounded daily allowances for repeated diagnostic messages and app hangs.
// claim retains first examples and carries suppressed totals into the next retained report.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import CryptoKit
import Synchronization

nonisolated final class DiagnosticEventBudget: @unchecked Sendable {
    static let shared = DiagnosticEventBudget()
    static let dailyLimit = 5
    private static let storageKey = "diagnostics.eventBudget.v1"

    struct Entry: Codable, Sendable {
        var day: Int
        var sent: Int
        var suppressed: Int
    }
    struct Decision: Sendable {
        let allowed: Bool
        let suppressed: Int
    }
    private let entries: Mutex<[String: Entry]>
    private let defaults: UserDefaults
    private let writer = DispatchQueue(label: "sentient.diagnostics.budget", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = Mutex(saved.count <= 512 ? saved.filter {
            $0.key.count == 64 && (0...Self.dailyLimit).contains($0.value.sent)
                && (0...1_000_000_000).contains($0.value.suppressed)
                && (0...1_000_000).contains($0.value.day)
        } : [:])
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Keys are local digests, never user content. Each release and process has its own allowance.
    /// At capacity, retain unfamiliar failures instead of collapsing them into an existing key.
    func claim(signature: String, release: String, identity: String, observations: Int = 1, now: Date = Date()) -> Decision {
        let key = Self.digest(identity + "\n" + release + "\n" + signature)
        let day = Int(floor(now.timeIntervalSince1970 / 86_400))
        return entries.withLock { values in
            values = values.filter { day - $0.value.day <= 7 }
            if values[key] == nil && values.count >= 512 { return Decision(allowed: true, suppressed: 0) }
            var entry = values[key] ?? Entry(day: day, sent: 0, suppressed: 0)
            if entry.day < day { entry.day = day; entry.sent = 0 }
            let allowed = entry.sent < Self.dailyLimit
            let suppressed = allowed ? entry.suppressed : 0
            if allowed { entry.sent += 1; entry.suppressed = 0 }
            else { entry.suppressed = min(entry.suppressed + min(max(observations, 1), 1_000_000), 1_000_000_000) }
            values[key] = entry
            let snapshot = values
            // Queue snapshots under the lock so concurrent callers cannot persist out of order.
            // Serialization and preferences I/O never run in the SDK's synchronous capture path.
            writer.async { [self] in
                if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: Self.storageKey) }
            }
            return Decision(allowed: allowed, suppressed: suppressed)
        }
    }

    /// Used at orderly shutdown/testing; normal reporting never waits for disk writes.
    func flush() { writer.sync {} }
}
