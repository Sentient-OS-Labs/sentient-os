#!/usr/bin/env python3
"""Compile Sidekick's complete production diagnostics type against inert SDK sinks.
Exercise actual shared repeat gating, Sentry consent dispatch and analytics tier dispatch.
No account, network, app data, provider process, or external telemetry is used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"
DIAGNOSTICS = APP / "Diagnostics"


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end]


shared = (DIAGNOSTICS / "Diagnostics.swift").read_text()
crash = (DIAGNOSTICS / "CrashReporting.swift").read_text()
analytics = (DIAGNOSTICS / "Analytics.swift").read_text()
SUPPORT = r'''
import Foundation
import Synchronization

nonisolated enum Fixture {
    struct Event: Sendable {
        let name: String
        let tags: [String: String]
        let extra: [String: String]
        let fingerprint: [String]
    }
    struct State: Sendable {
        var sentry: [Event] = []
        var breadcrumbs: [[String: String]] = []
        var local: [Diagnostics.Payload] = []
        var analytics: [[String: String]] = []
        var durations: [Double?] = []
        var crashEnabled = true
        var crashStarted = true
        var analyticsEnabled = true
        var analyticsStarted = true
    }
    static let state = Mutex(State())
    static func clearSinks() {
        state.withLock { state in
            state.sentry.removeAll(); state.breadcrumbs.removeAll(); state.local.removeAll()
            state.analytics.removeAll(); state.durations.removeAll()
            state.crashEnabled = true; state.crashStarted = true
            state.analyticsEnabled = true; state.analyticsStarted = true
        }
    }
}
nonisolated enum Diagnostics {
    struct Payload: Sendable { let event: String; let tags: [String: String]; let extra: [String: String]; let fingerprint: [String] }
    @TaskLocal static var current: Operation?
    final class Operation: Sendable {
        let id = UUID().uuidString
        let name = "fixture_operation"
        let parentID: String? = nil
        let began = Date()
        private let claims = Mutex<Set<String>>([])
        func claim(_ key: String, marksFailure: Bool) -> Bool { claims.withLock { $0.insert(key).inserted } }
    }
    struct RepeatState: Sendable { var sent: Date; var suppressed = 0 }
    private static let repeats = Mutex<[String: RepeatState]>([:])
    static func resetRepeats() { repeats.withLock { $0.removeAll() } }
    __REAL_REPEAT_KEY__
    __REAL_REPEAT_CLAIM__
}
nonisolated enum DiagnosticHistory {
    static func recordError(_ payload: Diagnostics.Payload) { Fixture.state.withLock { $0.local.append(payload) } }
}
nonisolated final class Scope {
    var tags: [String: String] = [:], extra: [String: String] = [:]
    var fingerprint: [String] = []
    func setLevel(_ value: CrashReporting.DiagLevel) { }
    func setTag(value: String, key: String) { tags[key] = value }
    func setExtras(_ value: [String: String]) { extra = value }
    func setFingerprint(_ value: [String]) { fingerprint = value }
}
nonisolated final class Breadcrumb {
    let category: String
    var message: String?
    var data: [String: String]?
    init(level: CrashReporting.DiagLevel, category: String) { self.category = category }
}
nonisolated enum SentrySDK {
    static func capture(message: String, configure: (Scope) -> Void) {
        let scope = Scope(); configure(scope)
        Fixture.state.withLock { $0.sentry.append(.init(name: message, tags: scope.tags, extra: scope.extra, fingerprint: scope.fingerprint)) }
    }
    static func addBreadcrumb(_ crumb: Breadcrumb) { Fixture.state.withLock { $0.breadcrumbs.append(crumb.data ?? [:]) } }
}
nonisolated enum CrashReporting {
    enum DiagLevel { case info, warning, error, fatal }
    static var diagnosticsEnabled: Bool { Fixture.state.withLock { $0.crashEnabled } }
    static var started: Bool { Fixture.state.withLock { $0.crashStarted } }
    static var correlationFields: [String: String] { [:] }
    static let osVersion = "fixture", appVersion = "fixture"
    static func sentryLevel(_ value: DiagLevel) -> DiagLevel { value }
    __REAL_CAPTURE_EVENT__
    __REAL_BREADCRUMB__
}
nonisolated func Log(_ value: String) { }
nonisolated enum TelemetryDeck {
    static func signal(_ name: String, parameters: [String: String], floatValue: Double?) {
        Fixture.state.withLock { state in
            state.analytics.append(parameters.merging(["event_name": name]) { _, new in new })
            state.durations.append(floatValue)
        }
    }
}
@MainActor enum Analytics {
    enum Tier { case core, extended }
    static var started: Bool { Fixture.state.withLock { $0.analyticsStarted } }
    static var analyticsEnabled: Bool { Fixture.state.withLock { $0.analyticsEnabled } }
    __REAL_ANALYTICS_SIGNAL__
}
'''
SUPPORT = SUPPORT.replace("__REAL_REPEAT_KEY__", declaration(shared, "static func repeatKey("))
SUPPORT = SUPPORT.replace("__REAL_REPEAT_CLAIM__", declaration(shared, "static func claim(event:"))
SUPPORT = SUPPORT.replace("__REAL_CAPTURE_EVENT__", declaration(crash, "nonisolated static func captureEvent("))
SUPPORT = SUPPORT.replace("__REAL_BREADCRUMB__", declaration(crash, "nonisolated static func diagnosticBreadcrumb("))
SUPPORT = SUPPORT.replace("__REAL_ANALYTICS_SIGNAL__", declaration(analytics, "static func signal("))

TESTS = r'''
import Foundation

@main @MainActor struct Tests {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError(label) }
        assertions += 1
    }
    static func drainAnalytics() async throws { try await Task.sleep(for: .milliseconds(20)) }
    static func reset() { Fixture.clearSinks(); Diagnostics.resetRepeats() }
    static func main() async throws {
        typealias D = SidekickDiagnostics
        let task = UUID(), attempt = UUID()
        let payload = D.payload(.context, outcome: .completed, taskID: task, attemptID: attempt,
                                backend: .claude, source: .notchTyped,
                                counts: [.retainedTurns: 15, .budgetTokens: 20_000, .messages: 31], duration: 0.1234)!
        check(payload.extra["duration_ms"] == "123", "duration has bounded millisecond precision")
        check(payload.extra["task_id"] == task.uuidString && payload.extra["attempt_id"] == attempt.uuidString, "diagnostics correlate logical task and attempt")
        check(payload.analytics["task_id"] == nil && payload.analytics["attempt_id"] == nil, "analytics never carries task identities")
        check(!payload.fingerprint.contains(task.uuidString) && !payload.fingerprint.contains(attempt.uuidString), "issue grouping never contains task IDs")
        check(Set(payload.tags.keys) == ["phase", "outcome", "reason", "backend", "source", "diagnostic_schema"], "closed categorical payload")
        check(Set(payload.extra.keys) == ["retained_turns", "budget_tokens", "messages", "duration_ms", "task_id", "attempt_id"], "closed numeric/UUID payload")
        let secret = "PRIVATE body person@example.com /Users/private/draft.md token=secret"
        check(D.Stage(rawValue: secret) == nil && D.Reason(rawValue: secret) == nil, "content cannot become a stage or reason")
        check(D.Source(rawValue: secret) == nil && D.Backend(rawValue: secret) == nil && D.Count(rawValue: secret) == nil, "content cannot become source/backend/count keys")
        let encoded = try JSONSerialization.data(withJSONObject: payload.tags.merging(payload.extra) { _, new in new })
        check(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE"), "no content reaches serialized payload")
        for duration in [Double.nan, Double.infinity, -Double.infinity, -0.001, D.maximumDuration + 1] {
            check(D.payload(.task, outcome: .completed, duration: duration) == nil, "reject nonfinite/negative/excessive durations")
        }
        for count in [-1, Int.min, Int.max, D.maximumCount + 1] {
            check(D.payload(.storeWrite, outcome: .completed, counts: [.events: count]) == nil, "reject invalid counters")
        }
        check(D.payload(.storeWrite, outcome: .completed, counts: [.events: D.maximumCount], duration: D.maximumDuration) != nil, "boundary numbers remain supported")
        check(!D.failure(.storeWrite, reason: .none), "failure must have a diagnostic category")
        check(!D.event(.task, outcome: .failed, reason: .persistence, counts: [.messages: -1]), "invalid event rejected before any sink")
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.isEmpty && $0.local.isEmpty && $0.breadcrumbs.isEmpty && $0.analytics.isEmpty }, "rejected input never emits")

        reset()
        check(D.event(.messageDelivery, taskID: task, attemptID: attempt, backend: .chatgpt, source: .promptBar, counts: [.messages: 1]), "valid delivery accepted")
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.isEmpty && $0.local.isEmpty }, "successes are not defects")
        check(Fixture.state.withLock { $0.breadcrumbs.count == 1 && $0.analytics.count == 1 }, "success gets bounded structure-only health observations")
        check(Fixture.state.withLock { $0.analytics[0]["event_name"] == "Sidekick.backend" && $0.analytics[0]["messages"] == "1" }, "health counts survive analytics dispatch")
        check(Fixture.state.withLock { $0.analytics[0]["task_id"] == nil && $0.analytics[0]["attempt_id"] == nil }, "sink-level analytics IDs excluded")

        reset()
        Fixture.state.withLock { $0.analyticsEnabled = false; $0.crashEnabled = false }
        D.failure(.storeOpen, reason: .corruptStore, taskID: task)
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.isEmpty && $0.breadcrumbs.isEmpty && $0.analytics.isEmpty }, "independent opt-outs honored by actual dispatch guards")
        check(Fixture.state.withLock { $0.local.count == 1 }, "content-free local failure remains available without upload consent")
        Fixture.state.withLock { $0.crashEnabled = true }
        D.failure(.storeRead, reason: .readFailed)
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.count == 1 && $0.analytics.isEmpty }, "crash consent does not enable extended analytics")

        reset()
        Fixture.state.withLock { $0.crashStarted = false; $0.analyticsStarted = false }
        D.failure(.storeWrite, reason: .writeFailed)
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.isEmpty && $0.analytics.isEmpty && $0.breadcrumbs.isEmpty }, "unstarted/debug SDK state cannot upload")

        reset()
        for reason: D.Reason in [.cancelled, .stopped, .interrupted, .staleGeneration, .staleAttempt, .duplicate,
                                  .foregroundBusy, .sourceChanged, .alreadyCurrent, .quota, .unavailable, .budgetExceeded] {
            D.failure(.compaction, reason: reason, taskID: task)
        }
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.isEmpty && $0.local.isEmpty }, "expected races/stops/limits do not create defects")
        check(Fixture.state.withLock { $0.analytics.count == 12 }, "expected outcomes still observable under extended consent")

        reset()
        D.failure(.messageDelivery, reason: .deliveryFailed, taskID: task, attemptID: attempt, backend: .claude, source: .voice)
        D.failure(.messageDelivery, reason: .deliveryFailed, taskID: UUID(), attemptID: UUID(), backend: .claude, source: .voice)
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.count == 1 }, "same failure mode across task IDs shares global cooldown")
        check(Fixture.state.withLock { $0.local.count == 2 }, "cooldown never suppresses local evidence")
        D.failure(.messageDelivery, reason: .deliveryFailed, backend: .chatgpt, source: .voice)
        D.failure(.messageDelivery, reason: .deliveryFailed, backend: .claude, source: .promptBar)
        D.failure(.messageDelivery, reason: .missingFinalMessage, backend: .claude, source: .voice)
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.count == 4 }, "provider/source/reason retain distinct failure groups")

        reset()
        let operation = Diagnostics.Operation()
        Diagnostics.$current.withValue(operation) {
            D.failure(.memoryWrite, reason: .writeFailed, taskID: task)
            Diagnostics.resetRepeats() // operation-level dedup must still hold without the global gate
            D.failure(.memoryWrite, reason: .writeFailed, taskID: task)
        }
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.count == 1 }, "same operation reports a backend defect once")

        reset()
        let now = Date(timeIntervalSince1970: 1_000)
        let first = D.payload(.compaction, outcome: .failed, reason: .invalidSummary, backend: .custom)!
        let key = first.fingerprint
        check(Diagnostics.claim(event: first.event, fingerprint: key, tags: first.tags, cooldown: D.failureCooldown, now: now) == 0, "initial failure accepted")
        check(Diagnostics.claim(event: first.event, fingerprint: key, tags: first.tags, cooldown: D.failureCooldown, now: now.addingTimeInterval(1)) == nil, "repeat suppressed")
        check(Diagnostics.claim(event: first.event, fingerprint: key, tags: first.tags, cooldown: D.failureCooldown, now: now.addingTimeInterval(899)) == nil, "cooldown enforced at boundary")
        check(Diagnostics.claim(event: first.event, fingerprint: key, tags: first.tags, cooldown: D.failureCooldown, now: now.addingTimeInterval(900)) == 2, "suppressed repeat count returned after cooldown")

        reset()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { D.failure(.migration, reason: .persistence, backend: .chatgpt, source: .startup) }
            }
        }
        try await drainAnalytics()
        check(Fixture.state.withLock { $0.sentry.count == 1 && $0.local.count == 32 }, "concurrent duplicate callbacks cannot bypass shared limiter")
        print("Sidekick diagnostics: \(assertions) assertions passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-sidekick-diagnostics-") as directory:
    tmp = Path(directory)
    support = tmp / "Support.swift"
    support.write_text(SUPPORT)
    tests = tmp / "Tests.swift"
    tests.write_text(TESTS)
    binary = tmp / "diagnostics-tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
        str(DIAGNOSTICS / "SidekickDiagnostics.swift"), str(support), str(tests),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
