#!/usr/bin/env python3
"""Read real scratch folders through FilesSource/FilesConnector and the listing health sensor.
Compile actual diagnostic operation and completion policy; only telemetry and health storage are
in-memory fixtures. No real preferences, model, network or personal files are accessed.
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


fixture = r'''
import Foundation
import Synchronization
enum ModelBackend: String { case fixture; static var current: Self { .fixture } }
enum DoubleTapProvider: String { case fixture }
enum Verdict { case survivor, junk, sensitive }
enum AppleCalendarSource { struct Snapshot: Sendable {} }
struct CycleFailure: Error {}
enum Diagnostics {
    enum Phase: String { case enumerate }
    enum Event { case sourceReadFailed, sourceReadDegraded }
    enum Count { case skipped }
    @TaskLocal static var current: Operation?
    static func source(_ value: String) -> String { value }
    static func causeKey(_ error: Error) -> String { "fixture" }
    static func report(_ event: Event, phase: Phase, reason: String, source: String, counts: [Count: Int] = [:]) {
        _ = current?.claim(reason)
    }
    // OPERATION
}
enum CrashReporting {
    enum Level { case info, warning, error }
    static var reported = 0
    static func captureEvent(_ message: String, level: Level = .warning, tags: [String: String] = [:],
        extra: [String: String] = [:], fingerprint: [String] = [], cooldown: Double = 900,
        affectsOperation: Bool = true) {
        // Same operation-marking contract as the production telemetry boundary.
        _ = Diagnostics.current?.claim(message, marksFailure: affectsOperation)
        reported += 1
    }
}
enum SourceHealth {
    private static let lock = Mutex(())
    private static var values: [String: Int] = [:]
    private static func dict() -> [String: Int] { values }
    private static func save(_ value: [String: Int]) { values = value }
    static func seed(_ key: String, count: Int) { values["listing:" + key] = count }
    // LISTING
}
enum ProcessingRun {
    // RESULT
}
@main enum Test {
    static func main() throws {
        var checks = 0
        func check(_ pass: Bool, _ label: String) { precondition(pass, label); checks += 1; print("PASS " + label) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        let empty = root.appendingPathComponent("Empty"), healthy = root.appendingPathComponent("Healthy")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try fm.createDirectory(at: healthy, withIntermediateDirectories: true)
        try "Project context that can be analyzed.".write(to: healthy.appendingPathComponent("Project.md"), atomically: true, encoding: .utf8)
        let connector = FilesConnector(roots: [.custom(empty), .custom(healthy)])
        let first = Diagnostics.Operation("processing")
        let buckets = try Diagnostics.$current.withValue(first) { try connector.buckets(since: [:]) }
        check(buckets.count == 2 && buckets[0].items.isEmpty && buckets[1].items.count == 1,
              "an empty folder preserves the healthy folder's work in the same connector")
        check(!first.hasFailure && ProcessingRun.Result(progress: RunProgress(), hadDiagnostics: first.hasFailure).complete,
              "new empty folders are successful reads, never incomplete analysis")
        let emptyKey = FileRoot.custom(empty).source!.cursorKey
        SourceHealth.seed(emptyKey, count: 25)
        let previouslyPopulated = Diagnostics.Operation("processing")
        let retried = try Diagnostics.$current.withValue(previouslyPopulated) { try connector.buckets(since: [:]) }
        check(retried.count == 2 && retried[1].items.count == 1 && CrashReporting.reported == 1,
              "an emptied folder still reports its listing anomaly without discarding other sources")
        check(!previouslyPopulated.hasFailure
              && ProcessingRun.Result(progress: RunProgress(), hadDiagnostics: previouslyPopulated.hasFailure).complete,
              "listing-count heuristics cannot turn a successful empty read into an analysis failure")
        let second = Diagnostics.Operation("processing")
        _ = try Diagnostics.$current.withValue(second) { try connector.buckets(since: [:]) }
        check(!second.hasFailure, "a no-change retry has the same successful completion as the first pass")
        let unavailable = Diagnostics.Operation("processing")
        _ = Diagnostics.$current.withValue(unavailable) {
            FilesSource(root: root.appendingPathComponent("DoesNotExist"), label: "Missing").eligibleFiles()
        }
        check(unavailable.hasFailure && !ProcessingRun.Result(progress: RunProgress(), hadDiagnostics: unavailable.hasFailure).complete,
              "a genuinely missing folder still reports a read failure")
        print("PASS \(checks) empty-folder analysis assertions")
    }
}
'''

fixture = fixture.replace("// OPERATION", member((APP / "Diagnostics/Diagnostics.swift").read_text(), "final class Operation:"))
fixture = fixture.replace("// LISTING", member((APP / "Diagnostics/SourceHealth.swift").read_text(), "static func checkListingCollapse("))
fixture = fixture.replace("// RESULT", member((APP / "Ingestion/ProcessingRun.swift").read_text(), "struct Result"))
with tempfile.TemporaryDirectory(prefix="sentient-empty-folder-") as directory:
    root = Path(directory)
    (root / "Fixture.swift").write_text(fixture)
    sources = ["Sources/DataSource.swift", "Sources/FilesSource.swift", "Ingestion/ItemKey.swift",
               "Ingestion/Connector.swift", "Ingestion/Connectors/FilesConnector.swift", "Ingestion/RunProgress.swift"]
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", *[str(APP / path) for path in sources],
                    str(root / "Fixture.swift"), "-o", str(root / "check")], check=True, timeout=60)
    subprocess.run([str(root / "check"), str(root)], check=True, timeout=20)
