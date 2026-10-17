// Content-free evidence for hosted connector classification. Failure preserves the stage and
// reviewed-policy differences; record owns the final report after retries, payload is testable.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation

nonisolated enum ConnectorClassificationDiagnostics {
    /// Lower layers keep their breadcrumbs; this owner reports once after classification retries.
    @TaskLocal static var ownsFailures = false

    enum Stage: String, Sendable { case version, inventory, classify, parse, validate }
    enum Kind: String, Sendable {
        case setupRequired = "setup_required", readinessUnknown = "readiness_unknown"
        case outputInvalid = "output_invalid", policyDisagreement = "policy_disagreement"
        case executionFailed = "execution_failed"
        var event: String { "connector.classification." + rawValue }
    }
    enum NativeState: String, Sendable {
        case unobserved, snapshotMissing = "snapshot_missing", serverMissing = "server_missing"
        case connected, pending, failed, disabled, needsAuth = "login_required", unknown
    }
    enum Reason: String, Sendable {
        case authenticationRequired = "login_required"
        case inventoryNotReady = "inventory_not_ready", nativeToolsMissing = "native_tools_missing"
        case invalidNativeInventory = "invalid_native_inventory"
        case invalidJSON = "invalid_json", invalidEnvelope = "invalid_envelope", noMatchingNames = "no_matching_names"
        case conflictingVerdicts = "conflicting_verdicts", invalidNames = "invalid_names"
        case duplicateNames = "duplicate_names", observedInventoryMismatch = "observed_inventory_mismatch"
        case reviewedInventoryMismatch = "reviewed_inventory_mismatch", missingCuratedRead = "missing_curated_read"
        case missingReviewedTool = "missing_reviewed_tool", categoryMismatch = "category_mismatch"
        case unreviewedRead = "unreviewed_read", missingIdentity = "missing_identity"
        case versionUnavailable = "version_unavailable", runtimeFailure = "runtime_failure"

        var kind: Kind {
            switch self {
            case .authenticationRequired: .setupRequired
            case .inventoryNotReady, .nativeToolsMissing, .invalidNativeInventory: .readinessUnknown
            case .invalidJSON, .invalidEnvelope, .noMatchingNames, .conflictingVerdicts, .invalidNames, .duplicateNames,
                 .observedInventoryMismatch: .outputInvalid
            case .reviewedInventoryMismatch, .missingCuratedRead, .missingReviewedTool,
                 .categoryMismatch, .unreviewedRead: .policyDisagreement
            case .missingIdentity, .versionUnavailable, .runtimeFailure: .executionFailed
            }
        }
    }
    enum Rule: String, Sendable { case slack, microsoft365, curatedReads = "curated_reads", destructive, drive }
    enum Metric: String, Sendable {
        case observed = "observed_count", classified = "classified_count", expected = "expected_count"
        case missing = "missing_count", extra = "extra_count", duplicate = "duplicate_count"
        case invalid = "invalid_count", mismatched = "category_mismatch_count", probes = "inventory_probes"
    }
    struct Mismatch: Sendable {
        let tool: String
        let expected: ConnectorRegistry.ToolCategory
        let observed: ConnectorRegistry.ToolCategory
        // A tool ID must come from a static reviewed list, never a provider-defined name.
        init(tool: String, slug: String, expected: ConnectorRegistry.ToolCategory, observed: ConnectorRegistry.ToolCategory) {
            let known = Set(ConnectorRegistry.pack(forSlug: slug)?.readTools ?? [])
                .union(ConnectorClassifier.reviewedDestructiveTools(slug: slug))
                .union(slug == "slack" ? Set(SlackConnector.categories(backend: .claude).keys) : [])
                .union(Microsoft365Connector.contains(slug) ? Set(Microsoft365Connector.categories.keys) : [])
            self.tool = known.contains(tool) ? tool : "other"
            self.expected = expected; self.observed = observed
        }
    }
    struct Failure: Error, Sendable {
        let stage: Stage
        let reason: Reason
        var nativeState: NativeState = .unobserved
        var metrics: [Metric: Int] = [:]
        var rule: Rule?
        var mismatches: [Mismatch] = []
        var runtimeReason: CodexFailureReason?
        var runtimeExpected = false
        var errorFields: [String: String] = [:]
        var kind: Kind { runtimeExpected ? .setupRequired : reason.kind }
        var reasonCode: String {
            if (errorFields["error_domain"] == NSCocoaErrorDomain && errorFields["error_code"] == "640")
                || (errorFields["error_domain"] == NSPOSIXErrorDomain && errorFields["error_code"] == "28") { return "disk_full" }
            return runtimeReason?.rawValue ?? reason.rawValue
        }

        static func execution(_ error: Error, stage: Stage) -> Self {
            if let failure = error as? Self { return failure }
            let runtimeReason = CodexFailureReason.classify(error)
            if case CodexCLI.CLIError.badEnvelope = error, runtimeReason == .unknown {
                return Self(stage: stage, reason: .invalidEnvelope, errorFields: Diagnostics.errorFields(error))
            }
            return Self(stage: stage, reason: .runtimeFailure,
                        runtimeReason: runtimeReason, runtimeExpected: Diagnostics.isExpected(error),
                        errorFields: Diagnostics.errorFields(error))
        }
    }

    /// Shared by Slack and Microsoft 365; acceptance still requires the exact reviewed surface.
    static func validateReviewed(_ tools: [ConnectorRegistry.ClassifiedTool], expected: [String: ConnectorRegistry.ToolCategory],
                                 prefix: String, slug: String, rule: Rule) throws {
        let names = tools.map(\.name)
        let wanted = Set(expected.keys.map { prefix + $0 })
        let actual = Set(names)
        var metrics: [Metric: Int] = [.classified: tools.count, .expected: wanted.count,
            .missing: wanted.subtracting(actual).count, .extra: actual.subtracting(wanted).count,
            .duplicate: tools.count - actual.count]
        guard tools.count == wanted.count, actual == wanted else {
            throw Failure(stage: .validate, reason: .reviewedInventoryMismatch, metrics: metrics, rule: rule)
        }
        let mismatches = tools.sorted { $0.name < $1.name }.compactMap { tool -> Mismatch? in
            let name = String(tool.name.dropFirst(prefix.count))
            guard let category = expected[name], category != tool.category else { return nil }
            return Mismatch(tool: name, slug: slug, expected: category, observed: tool.category)
        }
        guard mismatches.isEmpty else {
            metrics[.mismatched] = mismatches.count
            throw Failure(stage: .validate, reason: .categoryMismatch, metrics: metrics, rule: rule,
                          mismatches: Array(mismatches.prefix(8)))
        }
    }

    static func payload(_ failure: Failure, slug: String, version: String?, attempt: Int,
                        inventoryCount: Int? = nil) -> Diagnostics.Payload {
        let source = Diagnostics.source(ConnectorRegistry.telemetrySlug(slug))
        // CLI versions are technical data, but an unexpected command response is not a version.
        let version = version.flatMap { $0.range(of: #"^[0-9]{1,6}(\.[0-9]{1,6}){1,3}$"#, options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        var tags = failure.errorFields
        tags.merge(["phase": failure.stage.rawValue, "reason": failure.reasonCode, "source": source,
                    "backend": "claude", "diagnostic_schema": "2", "classification_kind": failure.kind.rawValue,
                    "native_state": inventoryCount == nil ? failure.nativeState.rawValue : NativeState.connected.rawValue,
                    "claude_version": version]) { _, new in new }
        if let rule = failure.rule { tags["rule"] = rule.rawValue }
        var extra = Dictionary(uniqueKeysWithValues: failure.metrics.map { ($0.key.rawValue, String($0.value)) })
        extra["attempted"] = String(attempt)
        if let inventoryCount { extra[Metric.observed.rawValue] = String(inventoryCount) }
        for (index, mismatch) in failure.mismatches.prefix(8).enumerated() {
            extra["mismatch_\(index + 1)_tool"] = mismatch.tool
            extra["mismatch_\(index + 1)_expected"] = mismatch.expected.rawValue
            extra["mismatch_\(index + 1)_observed"] = mismatch.observed.rawValue
        }
        // Versions/counts/tool names stay out of grouping. Distinct stages, rules and OS failures don't collapse.
        let fingerprint = [failure.kind.event, source, failure.stage.rawValue, failure.reasonCode,
                           failure.rule?.rawValue ?? "none", tags["native_state"] ?? "unobserved", tags["error_domain"] ?? "none",
                           tags["exit_code"] ?? tags["error_code"] ?? "none"]
        return Diagnostics.Payload(event: failure.kind.event, tags: tags, extra: extra, fingerprint: fingerprint)
    }

    @MainActor static func record(_ failure: Failure, slug: String, version: String?, attempt: Int,
                       inventoryCount: Int? = nil, terminal: Bool) {
        let value = payload(failure, slug: slug, version: version, attempt: attempt, inventoryCount: inventoryCount)
        CrashReporting.diagnosticBreadcrumb("connector.classification.attempt", data: value.tags.merging(value.extra) { _, new in new })
        Log("classifier: \(value.tags["source"]!) attempt=\(attempt) stage=\(failure.stage.rawValue) kind=\(failure.kind.rawValue) reason=\(failure.reasonCode)")
        guard terminal else { return }
        Diagnostics.current?.finish(outcome: failure.kind == .setupRequired ? "blocked" : "failed")
        // An explicit setup/auth state is context, not a recurring defect. Missing evidence is still reported.
        guard failure.kind != .setupRequired else { return }
        DiagnosticHistory.recordError(value)
        CrashReporting.captureEvent(value.event, tags: value.tags, extra: value.extra,
                                    fingerprint: value.fingerprint, cooldown: 900)
    }
}
