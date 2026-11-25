// Structure-only evidence for wake-helper connection failures. State bounds observation work;
// payload pairs the original failure with registration evidence without inferring a launch cause.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation

nonisolated enum WakeHelperDiagnostics {
    enum Failure: String, Sendable {
        case xpcError = "xpc_error", timeout = "xpc_timeout"
        case rejected = "helper_rejected", missingProxy = "proxy_unavailable"
        var reason: StaticString {
            switch self {
            case .xpcError: "xpc_error"
            case .timeout: "xpc_timeout"
            case .rejected: "helper_rejected"
            case .missingProxy: "proxy_unavailable"
            }
        }
    }

    enum Registration: String, Sendable {
        case unknown, notRegistered = "not_registered", enabled
        case requiresApproval = "requires_approval", notFound = "not_found"
        init(rawStatus: Int?) {
            switch rawStatus {
            case 0: self = .notRegistered
            case 1: self = .enabled
            case 2: self = .requiresApproval
            case 3: self = .notFound
            default: self = .unknown
            }
        }
    }

    enum Location: String, Sendable {
        case applications, userApplications = "user_applications", translocated, volume, other
        init(bundleURL: URL, homeURL: URL) {
            let path = bundleURL.standardizedFileURL.path
            if path.contains("/AppTranslocation/") { self = .translocated }
            else if path.hasPrefix("/Applications/") { self = .applications }
            else if path.hasPrefix(homeURL.appendingPathComponent("Applications").path + "/") { self = .userApplications }
            else if path.hasPrefix("/Volumes/") { self = .volume }
            else { self = .other }
        }
    }

    struct Context: Sendable {
        let phase: Diagnostics.Phase
        let trigger: CodexTrigger
        let registrationBefore: Registration
        let connectionGeneration: Int
        let reusedConnection: Bool
        let began: TimeInterval
    }

    struct Snapshot: Sendable {
        let everReplied: Bool
        let lastReplyAgeMS: Int?
        let interruptions: Int
        let invalidations: Int
    }

    /// Owned by WakeHelperClient on the main actor. Limiting here also bounds registration
    /// queries and local-history writes, independently of Sentry consent and SDK suppression.
    struct State {
        private var nextObservation: [String: TimeInterval] = [:]
        private var pending = Set<String>()
        private var lastReply: TimeInterval?
        private(set) var interruptions = 0
        private(set) var invalidations = 0

        mutating func recordReply(at now: TimeInterval) -> Bool {
            guard now.isFinite else { return false }
            let first = lastReply == nil
            lastReply = max(lastReply ?? now, now)
            return first
        }
        mutating func interrupted() { interruptions = min(interruptions + 1, 1_000_000) }
        mutating func invalidated() { invalidations = min(invalidations + 1, 1_000_000) }

        mutating func claim(_ phase: Diagnostics.Phase, failure: Failure, now: TimeInterval) -> Bool {
            guard now.isFinite else { return false }
            let key = phase.rawValue + ":" + failure.rawValue
            guard !pending.contains(key), now >= nextObservation[key, default: -.infinity] else { return false }
            pending.insert(key)
            nextObservation[key] = now + 900
            return true
        }
        mutating func finish(_ phase: Diagnostics.Phase, failure: Failure) {
            pending.remove(phase.rawValue + ":" + failure.rawValue)
        }
        func snapshot(at now: TimeInterval) -> Snapshot {
            Snapshot(everReplied: lastReply != nil,
                     lastReplyAgeMS: lastReply.map { milliseconds(now - $0) },
                     interruptions: interruptions, invalidations: invalidations)
        }
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), 7 * 86400) * 1000)
    }

    static func failurePayload(_ failure: Failure, context: Context, error: Error?, elapsed: TimeInterval) -> Diagnostics.Payload {
        let base = Diagnostics.payload(.wakeFailed, phase: context.phase, reason: failure.reason, error: error, source: "wakeHelper")
        var tags = base.tags
        tags["wake_trigger"] = context.trigger.rawValue
        tags["wake_registration_before"] = context.registrationBefore.rawValue
        let extra = base.extra.merging([
            "wake_connection_generation": String(context.connectionGeneration),
            "wake_connection_reused": String(context.reusedConnection),
            "wake_elapsed_ms": String(milliseconds(elapsed))
        ]) { _, new in new }
        // Distinct from the existing operational event; no registration/counter/path value
        // enters its fingerprint. A changing observation cannot evade the existing budget.
        return Diagnostics.Payload(event: "wake.connection_diagnostic", tags: tags, extra: extra,
            fingerprint: ["wake.connection_diagnostic", context.phase.rawValue, failure.rawValue])
    }

    static func enriched(_ base: Diagnostics.Payload, observed: Registration,
                         snapshot: Snapshot, location: Location) -> Diagnostics.Payload {
        var tags = base.tags
        tags["wake_registration_observed"] = observed.rawValue
        tags["wake_app_location"] = location.rawValue
        var extra = base.extra
        extra["wake_helper_replied_this_process"] = String(snapshot.everReplied)
        extra["wake_interruptions_seen"] = String(snapshot.interruptions)
        extra["wake_invalidations_seen"] = String(snapshot.invalidations)
        if let age = snapshot.lastReplyAgeMS { extra["wake_last_reply_age_ms"] = String(age) }
        return Diagnostics.Payload(event: base.event, tags: tags, extra: extra, fingerprint: base.fingerprint)
    }

    static func emit(_ payload: Diagnostics.Payload) {
        DiagnosticHistory.recordError(payload)
        // Observation must not change the outcome of a run that continued or recovered while
        // the off-main registration query was pending. Existing operation failures own that.
        CrashReporting.captureEvent(payload.event, tags: payload.tags, extra: payload.extra,
                                    fingerprint: payload.fingerprint, affectsOperation: false)
    }
}
