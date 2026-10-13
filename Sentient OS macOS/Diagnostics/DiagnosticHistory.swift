// Bounded local technical history for user-requested diagnostic exports, independent of telemetry.
// begin/finish pair Double Tap and overnight attempts; recordError accepts structured failures only.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import Synchronization

nonisolated enum DiagnosticHistory {
    static let key = "diagnostics.export.history.v1"
    static let processID = UUID()
    private static let lock = Mutex(())

    enum Kind: String, Codable, Sendable { case doubleTap, overnight }
    enum Outcome: String, Codable, Sendable {
        case running, pasteDispatched, notAMessage, stopped, failed, blocked, timedOut
        case completed, partial, offline, degraded, stalled, interrupted
    }

    struct Run: Codable, Sendable {
        let id: UUID
        let processID: UUID
        let beganAt: Date
        var finishedAt: Date?
        var outcome: Outcome = .running
        var reason: String?
        var phase: String?
        var provider: String?
        var model: String?
        var measurements: [String: Int] = [:]
        var stages: [String: String] = [:]
    }

    struct Failure: Codable, Sendable {
        let at: Date
        let event: String
        let fields: [String: String]
    }

    struct State: Codable, Sendable {
        var recordingStartedAt: Date?
        var firstOvernightAttemptAt: Date?
        var lastOvernightSuccessAt: Date?
        var doubleTap: [Run] = []
        var overnight: [Run] = []
        var errors: [Failure] = []
    }

    /// Snapshot marks an unfinished attempt from an earlier launch honestly. Nothing is uploaded.
    static func snapshot(defaults: UserDefaults = .standard) throws -> State {
        try lock.withLock { _ in
            var state = try load(defaults)
            for kind in [Kind.doubleTap, .overnight] {
                var runs = kind == .doubleTap ? state.doubleTap : state.overnight
                for i in runs.indices where runs[i].outcome == .running && runs[i].processID != processID {
                    runs[i].outcome = .interrupted
                }
                if kind == .doubleTap { state.doubleTap = runs } else { state.overnight = runs }
            }
            return state
        }
    }

    @discardableResult
    static func begin(_ kind: Kind, provider: String? = nil, model: String? = nil,
                      defaults: UserDefaults = .standard) -> UUID {
        let run = Run(id: UUID(), processID: processID, beganAt: Date(),
                      provider: provider, model: model.map { safe($0) })
        update(defaults) { state in
            if kind == .doubleTap {
                state.doubleTap.append(run)
                state.doubleTap = Array(state.doubleTap.suffix(50))
            } else {
                state.firstOvernightAttemptAt = state.firstOvernightAttemptAt ?? run.beganAt
                state.overnight.append(run)
                state.overnight = Array(state.overnight.suffix(30))
            }
        }
        return run.id
    }

    /// Once closed, late work cannot overwrite a timeout/stall, or resurrect a reset/evicted run.
    static func finish(_ kind: Kind, id: UUID, outcome: Outcome, reason: String? = nil,
                       phase: String? = nil, measurements: [String: Int] = [:],
                       stages: [String: String] = [:], defaults: UserDefaults = .standard) {
        update(defaults) { state in
            var runs = kind == .doubleTap ? state.doubleTap : state.overnight
            guard let i = runs.firstIndex(where: { $0.id == id }), runs[i].outcome == .running else { return }
            runs[i].finishedAt = Date()
            runs[i].outcome = outcome
            runs[i].reason = reason.map { safe($0) }
            runs[i].phase = phase
            runs[i].measurements.merge(measurements) { _, new in new }
            runs[i].stages = stages.mapValues { safe($0) }
            if kind == .doubleTap { state.doubleTap = runs } else {
                state.overnight = runs
                if outcome == .completed { state.lastOvernightSuccessAt = runs[i].finishedAt }
            }
        }
    }

    static func doubleTapTiming(id: UUID, model: String, measurements: [String: Int],
                                defaults: UserDefaults = .standard) {
        update(defaults) { state in
            guard let i = state.doubleTap.firstIndex(where: { $0.id == id }),
                  state.doubleTap[i].outcome == .running else { return }
            state.doubleTap[i].model = safe(model)
            state.doubleTap[i].measurements = measurements
        }
    }

    static func recordError(_ payload: Diagnostics.Payload, defaults: UserDefaults = .standard) {
        // No raw errors, breadcrumbs, tool events, stderr, arguments, or output cross this seam.
        let allowed: Set<String> = ["phase", "reason", "backend", "source", "error_type", "error_case",
            "error_domain", "error_code", "http_status", "exit_code"]
        var fields = payload.tags.filter { allowed.contains($0.key) }.mapValues { safe($0) }
        fields.merge(payload.extra.filter { Int($0.value) != nil || ["true", "false"].contains($0.value) }) { _, new in new }
        update(defaults) { state in
            state.errors.append(Failure(at: Date(), event: payload.event, fields: fields))
            state.errors = Array(state.errors.suffix(100))
        }
    }

    static func reset(defaults: UserDefaults = .standard) {
        lock.withLock { _ in defaults.removeObject(forKey: key) }
    }

    private static func safe(_ value: String) -> String {
        String(CrashReporting.scrub(text: value).prefix(160))
    }

    private static func load(_ defaults: UserDefaults) throws -> State {
        guard let data = defaults.data(forKey: key) else { return State() }
        return try JSONDecoder().decode(State.self, from: data)
    }

    private static func update(_ defaults: UserDefaults, _ body: (inout State) -> Void) {
        lock.withLock { _ in
            var state = (try? load(defaults)) ?? State()
            body(&state)
            if state.recordingStartedAt == nil && (!state.doubleTap.isEmpty || !state.overnight.isEmpty || !state.errors.isEmpty) {
                state.recordingStartedAt = Date()
            }
            // Never report storage errors through Diagnostics: that would recurse into this sink.
            if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
        }
    }
}
