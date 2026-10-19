#!/usr/bin/env python3
"""Exercise the actual legacy converter and SQLite import with isolated preferences.

No app singleton, telemetry, network, model, Keychain, or production defaults. Export-only
collaborators are inert; migration and persistence are complete production Swift files.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import Foundation

// These collaborators belong only to diagnosticEntries(), never legacyEvents().
@MainActor enum SidekickConversation {
    struct Unused { let store: SidekickConversationStore? = nil }
    static let shared = Unused()
    enum Failure: Error { case unavailable }
}
nonisolated enum CrashReporting { static func scrub(text: String) -> String { fatalError("Migration cannot export diagnostics") } }

typealias Event = SidekickConversationEvent
typealias Store = SidekickConversationStore

@main private struct MigrationChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try condition() else { fatalError(description) }
        count += 1
    }
    @MainActor static func expectFailure(_ description: String, _ work: () throws -> Void) {
        do { try work() }
        catch { count += 1; return }
        fatalError(description)
    }
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "test.sentient.sidekick-migration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func entry(_ text: String, id: UUID? = UUID(), card: Bool = false, outcome: String? = nil,
                   result: (String, String)? = nil, error: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["text": text, "card": card, "at": 765432100.125]
            if let id { value["id"] = id.uuidString }
            if let outcome { value["outcome"] = outcome }
            if let result { value["result"] = ["outcome": result.0, "notchMessage": result.1] }
            if let error { value["lastRecoveryError"] = error }
            return value
        }
        let doneID = UUID(), stoppedID = UUID(), failedID = UUID(), unfinishedID = UUID()
        let exact = "# Research café ☃️\n\nA quoted prompt: \"when am I free?\"\nline two\u{0}tail"
        let expected: [(String, Event.Outcome)] = [
            (exact, .success), ("Stopped modern", .stopped), ("Failed modern", .failed), ("Pending modern", .interrupted),
            ("Legacy completed", .success), ("Legacy stopped", .stopped), ("Legacy failed", .failed),
            ("Legacy custom summary", .interrupted), ("Modern result wins", .success), ("Unknown modern outcome", .interrupted)
        ]
        let raw = try encode([
            entry(exact, id: doneID, result: ("success", "✓ done")),
            entry("Stopped modern", id: stoppedID, card: true, result: ("stopped", "■ stopped"), error: "Calendar permission denied"),
            entry("Failed modern", id: failedID, result: ("failed", "Could not finish"), error: "Account unavailable"),
            entry("Pending modern", id: unfinishedID),
            entry("Legacy completed", id: nil, outcome: "you completed it"),
            entry("Legacy stopped", id: nil, card: true, outcome: "I stopped you before it finished"),
            entry("Legacy failed", id: nil, outcome: "you couldn't finish it (connection failed)"),
            entry("Legacy custom summary", id: nil, outcome: "Prepared a draft; outcome was never classified"),
            entry("Modern result wins", outcome: "I stopped you before it finished", result: ("success", "Actually completed")),
            entry("Unknown modern outcome", result: ("future_status", "Original status retained"))
        ])
        defaults.set(raw, forKey: SidekickHistory.key)
        let converted = try SidekickHistory.legacyEvents(defaults: defaults)
        let storeURL = root.appendingPathComponent("variants/Conversation.sqlite")
        let store = try Store(url: storeURL)
        try check(try store.importLegacy(events: converted), "First import did not commit")
        let records = try store.records(limit: 500)
        try check(records.count == expected.count * 3 + 2, "Imported event count lost requests, outcomes or errors")
        try check(!records.contains { $0.event.kind == .assistantMessage }, "Migration invented historical assistant answers")
        try check(defaults.data(forKey: SidekickHistory.key) == raw, "Converter/store mutated migration source before caller cleanup")
        for (text, outcome) in expected {
            let request = records.first { $0.event.kind == .userMessage && $0.event.text == text }!
            let task = records.filter { $0.event.taskID == request.event.taskID }
            try check(task.filter { $0.event.kind == .taskStarted }.count == 1, "Task start missing or duplicated")
            try check(task.filter { $0.event.kind == .taskFinished }.count == 1, "Terminal event missing or duplicated")
            try check(task.last?.event.outcome == outcome, "Wrong migrated status for " + text)
            try check(request.event.createdAt == Date(timeIntervalSinceReferenceDate: 765432100.125), "Original request date changed")
        }
        try check(try store.record(id: "legacy-request:\(doneID)")?.event.text.utf8.elementsEqual(exact.utf8) == true,
                  "Prompt Markdown, Unicode or NUL changed")
        try check(try store.record(id: "legacy-request:\(stoppedID)")?.event.source == "proactive_card", "Card origin lost")
        try check(try store.record(id: "legacy-request:\(doneID)")?.event.source == "command", "Command origin lost")
        try check(try store.record(id: "legacy-end:\(stoppedID)")?.event.text == "■ stopped", "Stopped status changed")
        try check(try store.record(id: "legacy-end:\(unfinishedID)")?.event.text.contains("Interrupted") == true,
                  "Unfinished task lacks honest interruption note")
        let blockers = records.filter { $0.event.kind == .checkpoint }.map(\.event.text)
        try check(blockers.contains("Last reported blocker: Calendar permission denied") && blockers.contains("Last reported blocker: Account unavailable"),
                  "Legacy recovery errors were lost")
        try check(records.contains { $0.event.text == "Prepared a draft; outcome was never classified" }, "Unknown legacy summary discarded")
        try check(records.contains { $0.event.text == "Original status retained" }, "Unknown modern outcome lost status text")
        print("PASS: legacy and modern variants preserve prompts, origins, dates, stopped/failed outcomes and blockers without inventing answers")

        // Legacy entries without UUIDs acquire new generated IDs on conversion, so the durable
        // import marker must do the idempotency work, including after reopening the database.
        let before = try store.latestSequence
        let convertedAgain = try SidekickHistory.legacyEvents(defaults: defaults)
        try check(try store.importLegacy(events: convertedAgain) == false, "Repeated conversion duplicated ID-less legacy tasks")
        let reopened = try Store(url: storeURL)
        try check(try reopened.importLegacy(events: convertedAgain) == false, "Restart repeated migration")
        try check(try reopened.latestSequence == before, "Restart import changed committed records")
        try check(try reopened.records(limit: 500) == records, "Reopen changed migrated contents")
        print("PASS: repeated conversion and reopen remain idempotent, including old records without UUIDs")

        // Decoding malformed legacy bytes must leave both the source and prior database intact.
        let malformed: [Data] = [
            Data("not JSON".utf8),
            try encode(["unexpected": "object"]),
            try encode([["text": "missing required card/date"]]),
            try encode([entry("valid first"), ["text": "bad second", "card": true, "at": "not a date"]]),
            try encode([["text": "bad identifier", "card": false, "at": 1, "id": "broken-uuid"]]),
            try encode([entry("bad completion", result: ("success", "done")).merging(["result": ["outcome": "success"]]) { _, new in new }])
        ]
        for data in malformed {
            defaults.set(data, forKey: SidekickHistory.key)
            expectFailure("Malformed migration accepted") { _ = try SidekickHistory.legacyEvents(defaults: defaults) }
            try check(defaults.data(forKey: SidekickHistory.key) == data, "Malformed source was deleted or changed")
            try check(try store.latestSequence == before, "Failed decoding changed committed history")
        }
        print("PASS: malformed migration data is reported and preserved without partial database mutation")

        // The store's import marker and events must roll back together when one converted
        // record is invalid; a later corrected source must still be importable.
        let atomic = try Store(url: root.appendingPathComponent("atomic/Conversation.sqlite"))
        let oversized = try encode([entry("First valid task"), entry(String(repeating: "x", count: Store.maximumMessageBytes + 1))])
        defaults.set(oversized, forKey: SidekickHistory.key)
        let oversizedEvents = try SidekickHistory.legacyEvents(defaults: defaults)
        expectFailure("Invalid converted event committed") { _ = try atomic.importLegacy(events: oversizedEvents) }
        try check(try atomic.latestSequence == 0, "Invalid import left a partial task")
        try check(defaults.data(forKey: SidekickHistory.key) == oversized, "Failed import lost legacy data")
        defaults.set(raw, forKey: SidekickHistory.key)
        try check(try atomic.importLegacy(events: SidekickHistory.legacyEvents(defaults: defaults)), "Failed import marked itself complete")
        try check(try atomic.records(limit: 500).count == records.count, "Corrected migration lost records")
        print("PASS: failed transactional migration leaves the source intact and retries cleanly")

        // Reset must not resurrect even if an old preferences backup is present afterward.
        let generation = try store.generation
        try store.reset()
        try check(try store.generation != generation, "Reset failed to invalidate old writers")
        try check(try store.importLegacy(events: convertedAgain) == false, "Reset allowed legacy history resurrection")
        try check(try Store(url: storeURL).importLegacy(events: convertedAgain) == false, "Reopen after reset allowed legacy resurrection")
        try check(try store.latestSequence == 0, "Reset is not empty")
        defaults.set(Data("old errors".utf8), forKey: "sidekick.errors")
        SidekickHistory.reset(defaults: defaults)
        try check(defaults.object(forKey: SidekickHistory.key) == nil && defaults.object(forKey: "sidekick.errors") == nil,
                  "Legacy reset left reimportable inputs")
        try check(try SidekickHistory.legacyEvents(defaults: defaults).isEmpty, "Absent legacy data is not an empty conversion")
        print("PASS: reset blocks legacy reimport and removes its old preferences inputs")
        print("Checked \(count) legacy migration assertions; failures=0")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-sidekick-migration-") as temporary:
    directory = Path(temporary)
    fixture = directory / "MigrationChecks.swift"
    fixture.write_text(FIXTURE)
    binary = directory / "migration-checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
        str(APP / "Notch Magic/SidekickConversationStore.swift"),
        str(APP / "Notch Magic/SidekickHistory.swift"),
        str(fixture), "-o", str(binary),
    ], check=True, timeout=60)
    subprocess.run([str(binary), str(directory)], check=True, timeout=30)
