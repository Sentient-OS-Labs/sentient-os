// Explicit, content-free support reports. Never derived from a conversation export.
// Schemas contain fixed labels/enums/codes; no screenshots, prompts, account details or paths.
import Foundation

nonisolated struct ComputerUseCheckReport: Codable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable { case settings, agent }
    enum Outcome: String, Codable, Sendable { case running, passed, repaired, permissionsNeeded, needsAttention, interrupted, cancelled, busy }
    enum Check: String, Codable, Sendable, CaseIterable {
        case runtime, permissions, connection, accessibility, capture, click, textEntry, repair
        var title: String {
            switch self {
            case .runtime: "Computer-use tools"
            case .permissions: "macOS permissions"
            case .connection: "Connecting to computer use"
            case .accessibility: "Reading the test window"
            case .capture: "Capturing the test window"
            case .click: "Clicking a test button"
            case .textEntry: "Entering test text"
            case .repair: "Repairing computer use"
            }
        }
    }
    enum Status: String, Codable, Sendable { case running, passed, needsAttention, interrupted, skipped }
    struct Step: Codable, Sendable, Identifiable {
        var id: Check { check }
        let check: Check
        var status: Status
        var detail: String? // NativeComputerUseFailure.Detail only, validated by the report boundary.
        var code: Int?
        var evidence: [String: String] = [:]
    }
    struct Environment: Codable, Sendable {
        let appVersion: String
        let appBuild: String
        let binaryID: String
        let macOS: String
        let backend: String
        let helperVersion: String
        let helperBuild: Int
        let cliVersion: String
    }
    struct TechnicalEvent: Codable, Sendable {
        let at: Date
        let event: String
        let fields: [String: String]

        init?(at: Date, event: String, fields: [String: String]) {
            guard ["computer_use.capture", "agent.tool_failed", "agent.run_diagnostic"].contains(event) else { return nil }
            if event == "computer_use.capture" {
                guard fields["capture_source"] == "native",
                      ["failed", "skipped", "recovered"].contains(fields["capture_outcome"] ?? "") else { return nil }
            } else { guard fields["feature"] == "computer" else { return nil } }
            let enums: [String: Set<String>] = [
                "native_kind": ["capture", "no_windows", "permission", "connection", "timeout", "unknown"],
                "capture_source": ["native"], "capture_outcome": ["failed", "skipped", "recovered"],
                "backend": ["chatgpt", "claude", "custom"], "feature": ["computer"],
                "tool_family": ["native", "recovery", "shell", "web", "builtin", "connector"],
                "tool": ["get_app_state", "list_apps", "click", "perform_secondary_action", "set_value", "select_text", "scroll", "drag", "press_key", "type_text", "diagnose_computer_use", "other"],
                "reason": ["unknown", "app_unavailable", "stale_target", "permission", "login_required", "quota", "timeout", "connection", "invalid_arguments", "unavailable_tool", "output_schema", "cancelled", "screen_capture", "no_windows"],
                "outcome": ["cancelled", "blocked", "failed", "done_claimed", "could_not", "unconfirmed", "not_applicable"],
                "model_outcome": ["done_claimed", "could_not", "unconfirmed", "not_applicable"],
                "runtime_outcome": ["completed", "failed", "cancelled"],
                "tool_recovery": ["not_needed", "stopped", "runtime_failed", "recovered", "unconfirmed"]
            ]
            let numbers: Set<String> = ["native_error_code", "error_code", "rpc_error_code", "system_error_code", "exit_code",
                "duration_ms", "capture_attempt", "tool_calls", "tool_completed", "tool_failed", "tool_omitted", "process_exit_code"]
            var safe: [String: String] = [:]
            for (key, value) in fields {
                if enums[key]?.contains(value) == true { safe[key] = value }
                else if numbers.contains(key), value.count <= 16, Int64(value) != nil { safe[key] = value }
                else if key == "native_detail", NativeComputerUseFailure.Detail(rawValue: value) != nil { safe[key] = value }
                else if key == "failure_stage", NativeComputerUseFailure.Stage(rawValue: value) != nil { safe[key] = value }
                else if ["task_id", "operation_id", "root_operation_id", "capture_id"].contains(key), UUID(uuidString: value) != nil { safe[key] = value }
                else if key == "system_error_domain", ["SCStreamErrorDomain", "com.apple.ScreenCaptureKit.SCStreamErrorDomain", "NSOSStatusErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSURLErrorDomain", "application"].contains(value) { safe[key] = value }
            }
            self.at = at; self.event = event; self.fields = safe
        }
    }
    let schemaVersion: Int
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    let source: Source
    let environment: Environment
    var outcome: Outcome = .running
    var permissions: [String: String] = [:]
    var steps: [Step] = []
    var recentEvents: [TechnicalEvent] = []
    var repairAttempted = false
    var repairVerified = false

    init(source: Source, environment: Environment) {
        schemaVersion = 1; id = UUID(); startedAt = Date()
        self.source = source; self.environment = environment
    }

    mutating func update(_ check: Check, _ status: Status, failure: NativeComputerUseFailure? = nil) {
        var step = Step(check: check, status: status, detail: failure?.detail.rawValue, code: failure?.code,
                        evidence: failure?.fields ?? [:])
        if let index = steps.firstIndex(where: { $0.check == check }) {
            if check == .repair, failure == nil {
                step.detail = steps[index].detail; step.code = steps[index].code; step.evidence = steps[index].evidence
            }
            steps[index] = step
        }
        else { steps.append(step) }
    }

    mutating func finish() {
        finishedAt = Date()
        for i in steps.indices where steps[i].status == .running {
            steps[i].status = outcome == .cancelled || outcome == .interrupted ? .interrupted : .needsAttention
        }
    }

    var title: String {
        switch outcome {
        case .running: "Checking computer use"
        case .passed: "Your computer tools are ready"
        case .repaired: "Repaired and checked"
        case .permissionsNeeded: "Permissions need attention"
        case .interrupted: "The check was interrupted"
        case .needsAttention: "Let’s take a closer look"
        case .cancelled: "Check cancelled"
        case .busy: "Sidekick is working"
        }
    }
    var explanation: String {
        switch outcome {
        case .running: "A few small checks in this window. Your apps and work stay yours."
        case .passed, .repaired: "Window reading, screenshots, clicks and text entry passed. Your AI account is checked separately in Health."
        case .permissionsNeeded: "Check the permission rows in Health, then run this check again. Nothing was reset."
        case .interrupted: "The window or focus changed during the check. That can happen while you use your Mac. Try again when convenient."
        case .needsAttention: "The check couldn’t finish. You can review and send its technical report to the Sentient team."
        case .cancelled: "You can run this again anytime. Your conversation is still here."
        case .busy: "Finish the current task before running a separate repair. Sidekick can also check its tools during the task."
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Never restart the helper for focus changes, unsupported inputs or missing permissions.
    static func allowsConnectionRepair(_ failure: NativeComputerUseFailure) -> Bool {
        failure.kind == .connection || failure.detail == .requestTimedOut || failure.detail == .senderNotAuthenticated
            || [.screenshotCaptureFailed, .screenCaptureFailed, .unknownCaptureFailed].contains(failure.detail)
    }
    static func outcome(for failure: NativeComputerUseFailure) -> Outcome {
        if [.senderNotAuthenticated, .approvalDenied, .blockedByPolicy].contains(failure.detail) { return .needsAttention }
        if failure.kind == .permission { return .permissionsNeeded }
        if failure.kind == .noWindows || [.focusChanged, .inputInterrupted, .elementUnavailable,
            .staleState, .testWindowNotObserved].contains(failure.detail) { return .interrupted }
        return .needsAttention
    }
}
