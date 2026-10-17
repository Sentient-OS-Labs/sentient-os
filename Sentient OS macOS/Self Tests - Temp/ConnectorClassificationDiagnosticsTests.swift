// Synthetic regressions for classification evidence, reporting ownership and privacy.
// run exercises the production parsers and validators without connecting to a provider.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
#if DEBUG
import Foundation
import Synchronization

enum ConnectorClassificationDiagnosticsTests {
    private typealias D = ConnectorClassificationDiagnostics
    private static var passed = 0
    private static func check(_ condition: Bool, _ message: String) throws {
        try FullAcceptanceTests.require(condition, message)
        passed += 1
    }
    private static func failure(_ body: () throws -> Void) throws -> D.Failure {
        do { try body() } catch let error as D.Failure { return error }
        throw FullAcceptanceTests.Failure(message: "Expected a typed classification failure")
    }
    private static func snapshot(_ status: String?, tools: [String]?, server: String = "claude.ai Slack") throws -> String {
        var event: [String: Any] = ["type": "system", "subtype": "init",
            "mcp_servers": status.map { [["name": server, "status": $0]] } ?? []]
        if let tools { event["tools"] = tools }
        return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    static func run() async {
        do {
            try inventory()
            try policies()
            try reporting()
            try await runtime()
            Log("CLASSIFICATION DIAGNOSTICS: PASS \(passed) checks")
        } catch {
            Log("CLASSIFICATION DIAGNOSTICS: FAIL \(String(describing: error))")
            exit(1)
        }
    }

    private static func inventory() throws {
        let prefix = SlackConnector.claudePrefix
        let names = [prefix + "read_fixture"]
        func observe(_ raw: String) -> (names: [String]?, failure: D.Failure) {
            ConnectorClassifier.nativeObservation(raw: raw, prefix: prefix, serverName: "claude.ai Slack")
        }
        for (status, state): (String?, D.NativeState) in [
            ("pending", .pending), (nil, .serverMissing), ("failed", .failed),
            ("disabled", .disabled), ("arbitrary-private-status", .unknown)] {
            let result = try observe(snapshot(status, tools: names))
            try check(result.names == nil && result.failure.kind == .readinessUnknown && result.failure.nativeState == state,
                      "Unverified \(state.rawValue) inventory is not proof of missing setup")
        }
        let login = try observe(snapshot("needs-auth", tools: names))
        try check(login.names == nil && login.failure.kind == .setupRequired && Diagnostics.isExpected(login.failure),
                  "Explicit native login state remains a setup blocker")
        let missing = observe(#"{"type":"result","result":"User has not connected Slack; please log in"}"#)
        try check(missing.failure.nativeState == .snapshotMissing && missing.failure.kind == .readinessUnknown,
                  "Model prose cannot diagnose the user's connection")
        let ready = try observe(snapshot("connected", tools: names + ["Read"]))
        try check(ready.names == names && ready.failure.metrics[.observed] == 1, "Connected native names certify inventory")
        let noTools = try observe(snapshot("connected", tools: nil))
        try check(noTools.failure.reason == .nativeToolsMissing, "Missing native tools are distinguished from an empty list")
        for tools in [[], names + names, [prefix + "invalid name"]] {
            let result = try observe(snapshot("connected", tools: tools))
            try check(result.names == nil && result.failure.reason == .invalidNativeInventory, "Malformed native inventory remains blocked")
        }
        let other = try observe(snapshot("connected", tools: names, server: "claude.ai Unrelated"))
        try check(other.names == nil && other.failure.nativeState == .serverMissing, "Other servers cannot certify this connector")
        let later = try snapshot("pending", tools: []) + "\n" + #"{"type":"result","tools":["read_fixture"],"status":"connected"}"#
        try check(observe(later).names == nil, "Later model results do not relax the existing native completeness gate")

        let invalid = try failure { _ = try ConnectorClassifier.parse("not JSON", prefix: prefix) }
        try check(invalid.stage == .parse && invalid.reason == .invalidJSON, "Malformed classification is identified at parse")
        let conflict = try failure {
            _ = try ConnectorClassifier.parse(#"{"tools":[{"name":"read_fixture","category":"read"},{"name":"read_fixture","category":"write"}]}"#, prefix: prefix)
        }
        try check(conflict.reason == .conflictingVerdicts, "Conflicting verdicts retain their own reason")
        let same = try ConnectorClassifier.parse(#"{"tools":[{"name":"read_fixture","category":"read"},{"name":"read_fixture","category":"read"}]}"#, prefix: prefix)
        try check(same.count == 1, "Existing same-category normalization remains unchanged")
        let foreign = try failure {
            _ = try ConnectorClassifier.parse(#"{"tools":[{"name":"mcp__unrelated__private_name","category":"read"}]}"#, prefix: prefix)
        }
        try check(foreign.reason == .noMatchingNames, "Foreign namespaces cannot become connector classifications")
    }

    private static func policies() throws {
        for (slug, prefix, categories) in [
            ("slack", SlackConnector.claudePrefix, SlackConnector.categories(backend: .claude)),
            (OutlookMailConnector.slug, Microsoft365Connector.prefix, Microsoft365Connector.categories),
            (OutlookCalendarConnector.slug, Microsoft365Connector.prefix, Microsoft365Connector.categories)] {
            let tools = categories.keys.sorted().map { ConnectorRegistry.ClassifiedTool(name: prefix + $0, category: categories[$0]!) }
            try ConnectorClassifier.validate(tools, slug: slug, inventory: tools.map(\.name))
            try check(true, "Reviewed \(slug) classification still passes")
            let short = Array(tools.dropLast())
            let incomplete = try failure { try ConnectorClassifier.validate(short, slug: slug, inventory: tools.map(\.name)) }
            try check(incomplete.kind == .outputInvalid && incomplete.metrics[.missing] == 1, "Missing model verdict is distinct from reviewed-policy drift")
            let drift = try failure { try ConnectorClassifier.validate(short, slug: slug, inventory: short.map(\.name)) }
            try check(drift.kind == .policyDisagreement && drift.reason == .reviewedInventoryMismatch
                      && drift.metrics[.missing] == 1 && drift.metrics[.extra] == 0, "Complete but changed native surface reports reviewed difference counts")
            let extra = tools + [.init(name: prefix + "unreviewed_private_name", category: .write)]
            let added = try failure { try ConnectorClassifier.validate(extra, slug: slug, inventory: extra.map(\.name)) }
            try check(added.metrics[.extra] == 1 && added.metrics[.expected] == tools.count, "New native tool counts are retained without its name")
            let unsafe = tools.map { ConnectorRegistry.ClassifiedTool(name: $0.name, category: $0.category == .destructive ? .read : $0.category) }
            let disagreement = try failure { try ConnectorClassifier.validate(unsafe, slug: slug, inventory: tools.map(\.name)) }
            try check(disagreement.reason == .categoryMismatch && disagreement.metrics[.mismatched] == tools.count { $0.category == .destructive },
                      "All category differences are counted")
            try check(disagreement.mismatches.allSatisfy { $0.expected == .destructive && $0.observed == .read && $0.tool != "other" },
                      "Reviewed IDs and expected/observed categories identify the policy disagreement")
            let duplicate = try failure { try ConnectorClassifier.validate(tools + [tools[0]], slug: slug) }
            try check(duplicate.reason == .duplicateNames && duplicate.metrics[.duplicate] == 1, "Duplicate output has an explicit reason")
        }
        let drivePrefix = "mcp__claude_ai_Google_Drive__"
        let reads = ConnectorRegistry.pack(forSlug: "google-drive")!.readTools!
        let drive = reads.map { ConnectorRegistry.ClassifiedTool(name: drivePrefix + $0, category: .read) }
            + ["copy_file", "create_file", "share_file", "update_file"].map { .init(name: drivePrefix + $0, category: .write) }
            + [.init(name: drivePrefix + "trash_file", category: .destructive)]
        try ConnectorClassifier.validate(drive, slug: "google-drive", inventory: drive.map(\.name))
        let unsafe = drive.dropLast() + [ConnectorRegistry.ClassifiedTool(name: drivePrefix + "trash_file", category: .write)]
        let denied = try failure { try ConnectorClassifier.validate(Array(unsafe), slug: "google-drive", inventory: drive.map(\.name)) }
        try check(denied.rule == .destructive && denied.mismatches.first?.tool == "trash_file", "Drive destructive gate and reviewed ID survive reporting changes")
    }

    private static func reporting() throws {
        let disk = D.Failure.execution(NSError(domain: NSCocoaErrorDomain, code: 640,
            userInfo: [NSFilePathErrorKey: "/Users/private-person/sensitive-file"]), stage: .inventory)
        let timeout = D.Failure.execution(CodexCLI.CLIError.timedOut(after: 300), stage: .classify)
        let login = D.Failure.execution(CodexCLI.CLIError.exitFailure(code: 1, message: "not logged in"), stage: .inventory)
        let forbidden = D.Failure.execution(CodexCLI.CLIError.exitFailure(code: 1, message: "HTTP 403"), stage: .inventory)
        let refresh = D.Failure.execution(CodexCLI.CLIError.exitFailure(code: 1, message: "refresh failed"), stage: .inventory)
        try check(disk.reasonCode == "disk_full" && disk.kind == .executionFailed, "Disk-full is an environment failure")
        try check(timeout.reasonCode == "timeout_ours" && timeout.stage == .classify, "Timeout retains the actual classification stage")
        try check(login.kind == .setupRequired, "Explicit provider login is expected setup")
        try check(forbidden.kind == .executionFailed && refresh.kind == .executionFailed, "403 and refresh failures do not prove the user is disconnected")
        let bad = D.Failure.execution(CodexCLI.CLIError.badEnvelope("private output"), stage: .classify)
        try check(bad.kind == .outputInvalid && bad.reason == .invalidEnvelope, "Invalid CLI envelopes are separate from process failures")
        let pending = D.Failure(stage: .inventory, reason: .inventoryNotReady, nativeState: .pending)
        let values = [disk, timeout, login, forbidden, refresh, bad, pending].map {
            D.payload($0, slug: "slack", version: "2.1.300", attempt: 2)
        }
        try check(Set(values.map { $0.fingerprint.joined(separator: ":") }).count == values.count, "Distinct causes produce distinct Sentry groups")
        let anotherVersion = D.payload(pending, slug: "slack", version: "2.1.301", attempt: 1)
        try check(anotherVersion.fingerprint == values.last?.fingerprint, "Version and retry changes do not split one issue")
        let anotherConnector = D.payload(pending, slug: "outlook-mail", version: "2.1.300", attempt: 2)
        try check(anotherConnector.fingerprint != values.last?.fingerprint, "Different connectors do not collapse into one issue")
        let privateMismatch = D.Mismatch(tool: "private_tool_name", slug: "slack", expected: .read, observed: .write)
        let privacy = D.payload(.init(stage: .validate, reason: .categoryMismatch, mismatches: [privateMismatch]),
                                slug: "private_connector_name", version: "private_version", attempt: 2)
        let serialized = (values + [privacy]).map { String(describing: $0) }.joined()
        try check(!serialized.contains("private") && !serialized.contains("sensitive-file") && privacy.extra["mismatch_1_tool"] == "other",
                  "Raw errors, arbitrary tool/connector names and invalid versions never enter telemetry")
        let now = Date(timeIntervalSince1970: 1_000)
        let value = values.last!
        try check(Diagnostics.claim(event: value.event, fingerprint: value.fingerprint, tags: value.tags, cooldown: 900, now: now) == 0,
                  "First final failure is eligible")
        try check(Diagnostics.claim(event: value.event, fingerprint: value.fingerprint, tags: value.tags, cooldown: 900, now: now.addingTimeInterval(1)) == nil,
                  "Repeated failure is rate-limited")
        try check(Diagnostics.claim(event: value.event, fingerprint: value.fingerprint, tags: value.tags, cooldown: 900, now: now.addingTimeInterval(901)) == 1,
                  "Next report includes suppressed repeat count")
        let suite = "classification-diagnostics-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DiagnosticHistory.recordError(values[0], defaults: defaults)
        let history = try DiagnosticHistory.snapshot(defaults: defaults)
        try check(history.errors.last?.fields["reason"] == "disk_full" && history.errors.last?.fields["classification_kind"] == "execution_failed",
                  "Local technical export retains the same distinction")
    }

    private static func runtime() async throws {
        try await ModelBackend.$runOverride.withValue(.claude) {
            try await D.$ownsFailures.withValue(true) {
                try await Diagnostics.withOperation("classification_fixture") {
                    let attempts = Mutex(0)
                    let pending = try snapshot("pending", tools: [])
                    do {
                        _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in
                            attempts.withLock { $0 += 1 }
                            try await FullAcceptanceTests.require(invocation.mcpActionServer == nil && invocation.mcpAttachServer == "slack", "Fixture must stay tool-free")
                            return await FullAcceptanceTests.envelope(#"{"tools":[]}"#, raw: pending)
                        }) { try await ConnectorClassifier.listTools(slug: "slack") }
                        throw FullAcceptanceTests.Failure(message: "Pending inventory unexpectedly passed")
                    } catch let error as D.Failure {
                        try check(error.kind == .readinessUnknown && error.metrics[.probes] == 2 && attempts.withLock({ $0 }) == 2,
                                  "Actual inventory path retains both probes and final readiness evidence")
                    }
                    do {
                        _ = try await FrontierRun.$acceptanceRun.withValue({ _ in throw CodexCLI.CLIError.timedOut(after: 300) }) {
                            try await ConnectorClassifier.classify(slug: "slack", inventory: [SlackConnector.claudePrefix + "fixture"])
                        }
                        throw FullAcceptanceTests.Failure(message: "Timeout unexpectedly passed")
                    } catch let error as D.Failure {
                        try check(error.stage == .classify && error.kind == .executionFailed, "Runtime wrapper preserves execution stage")
                    }
                    try check(Diagnostics.current?.hasFailure == false, "Lower wrappers leave terminal reporting to the retry owner")
                    do {
                        _ = try await FrontierRun.$acceptanceRun.withValue({ _ in throw CancellationError() }) {
                            try await ConnectorClassifier.listTools(slug: "slack")
                        }
                        throw FullAcceptanceTests.Failure(message: "Cancellation unexpectedly passed")
                    } catch is CancellationError { try check(true, "Cancellation propagates without becoming a classification defect") }
                }
            }
        }
        try check(!D.ownsFailures, "Reporting ownership is restored after the classifier scope")
    }
}
#endif
