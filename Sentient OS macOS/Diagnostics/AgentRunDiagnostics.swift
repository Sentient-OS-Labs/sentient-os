// Records bounded, content-free tool timelines and distinguishes model outcomes from process exits.
// withRun scopes each frontier invocation; observe consumes structured events without retaining output.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import Synchronization
import AppKit

nonisolated final class AgentRunDiagnostics: Sendable {
    @TaskLocal static var current: AgentRunDiagnostics?

    enum Reason: String, Sendable {
        case unknown, appUnavailable = "app_unavailable", staleTarget = "stale_target"
        case permission, authentication = "login_required", quota, timeout, connection, invalidArguments = "invalid_arguments"
        case unavailableTool = "unavailable_tool", cancelled

        /// A text-derived category is a hint, never proof of an OS or permission state.
        static func classify(_ text: String) -> Self {
            let text = String(text.prefix(8192)).lowercased()
            if text.contains("not running") || text.contains("app not found") || text.contains("application not found") || text.contains("can't be reached") { return .appUnavailable }
            if text.contains("re-query") || text.contains("stale") || text.contains("element not found") { return .staleTarget }
            if text.contains("permission") || text.contains("accessibility") || text.contains("not authorized") { return .permission }
            if text.contains("unauthorized") || text.contains("sign in") || text.contains("not logged in") { return .authentication }
            if text.contains("rate limit") || text.contains("usage limit") || text.contains("quota") { return .quota }
            if text.contains("timed out") || text.contains("timeout") { return .timeout }
            if text.contains("connection") || text.contains("disconnected") { return .connection }
            if text.contains("invalid argument") || text.contains("invalid parameter") { return .invalidArguments }
            if text.contains("unknown tool") || text.contains("tool not found") || text.contains("tool unavailable") { return .unavailableTool }
            if text.contains("cancelled") || text.contains("canceled") { return .cancelled }
            return .unknown
        }
    }

    private struct Call: Sendable {
        let ordinal: Int
        let tool: String
        let family: String
        let began: Date?
        let target: Int?
        var ended = false
    }
    private struct State: Sendable {
        var calls: [String: Call] = [:] // provider IDs are lookup keys only, never emitted
        var targets: [String: Int] = [:] // app selectors stay in memory, represented by per-run ordinals
        var started = 0
        var completed = 0
        var failed = 0
        var unknown = 0
        var omitted = 0
        var exitCode: Int32?
        var helperAtStart: Bool?
        var helperAtEnd: Bool?
        var lastFailure: Reason = .unknown
        var trail: [String] = []
    }
    private let state = Mutex(State())
    private let operation = Diagnostics.current
    private let correlation = CrashReporting.correlationFields
    private let began = Date()
    private let backend = ModelBackend.current.rawValue
    private let trigger = CodexTrigger.current.rawValue
    private let feature: String

    init(feature: String = "computer") {
        let known: Set<String> = ["computer", "sidekick-mcp", "router", "vault", "proactive", "proactive-research", "giftletter", "writingstyle", "mcp-read", "mcp-write", "gmail-write", "calendar-write", "calendar-context", "calendar-proactive", "calendar", "gmail", "classify", "census"]
        self.feature = known.contains(feature) ? feature : "other"
    }

    static func withRun<T>(action: Bool, computer: Bool = false, feature: String = "computer", result: (T) -> String,
                           isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async rethrows -> T {
        let run = AgentRunDiagnostics(feature: feature)
        return try await $current.withValue(run) {
            do {
                let value = try await body()
                run.finish(action ? (computer ? AgentStatus.parse(result(value)) : AgentStatus.parseConnector(result(value))) : nil)
                return value
            } catch {
                run.finish(nil, error: error)
                throw error
            }
        }
    }

    func recordProcess(status: Int32) { state.withLock { $0.exitCode = status } }
    func recordHelper(running: Bool, atStart: Bool) {
        state.withLock { if atStart { $0.helperAtStart = running } else { $0.helperAtEnd = running } }
    }

    /// Only fixed native tool names are emitted. Connector-defined names may contain account labels.
    static func toolIdentity(server: String, tool: String) -> (family: String, tool: String) {
        if server == "sentient_native" {
            let known: Set<String> = ["get_app_state", "list_apps", "list_windows", "get_desktop_state", "click", "double_click", "right_click", "drag", "scroll", "type_text", "set_value", "press_key", "key_press", "launch_app", "open_app", "get_screenshot", "screenshot", "get_app_info", "get_window_state", "select_menu_item", "invoke_menu"]
            return ("native", known.contains(tool) ? tool : "other")
        }
        if server == "sentient_recovery" { return ("recovery", ["ask_user", "update_instructions"].contains(tool) ? tool : "other") }
        if server == "shell" { return ("shell", "command") }
        if server == "web" { return ("web", "search") }
        return ("connector", "other")
    }

    func observe(_ line: String) {
        guard CrashReporting.diagnosticsEnabled else { return }
        guard line.utf8.count <= 16_777_216 else {
            state.withLock { $0.omitted += 1 }
            return
        }
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = event["type"] as? String else { return }
        if let item = event["item"] as? [String: Any], let id = item["id"] as? String,
           let type = item["type"] as? String, ["mcp_tool_call", "command_execution", "web_search"].contains(type) {
            let server = type == "command_execution" ? "shell" : (type == "web_search" ? "web" : item["server"] as? String ?? "")
            let tool = item["tool"] as? String ?? ""
            let args = item["arguments"] as? [String: Any] ?? [:]
            if kind == "item.started" { start(id, server: server, tool: tool, arguments: args) }
            if kind == "item.completed" {
                start(id, server: server, tool: tool, arguments: args, observedStart: false)
                let result = item["result"] as? [String: Any]
                let error = item["error"] as? [String: Any]
                let status = item["status"] as? String
                let exit = item["exit_code"] as? Int
                let failed = error != nil || item["error"] is String || status == "failed" || result?["isError"] as? Bool == true || result?["is_error"] as? Bool == true || (exit != nil && exit != 0)
                let known = failed || status == "completed" || result != nil || exit == 0
                // Read error text only after the protocol explicitly identifies a failure.
                end(id, failed: failed, known: known, reason: failed ? Self.errorReason(error ?? result ?? item) : .unknown,
                    code: error?["code"] as? Int)
            }
        } else if let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                if kind == "assistant", block["type"] as? String == "tool_use", let id = block["id"] as? String {
                    let name = block["name"] as? String ?? ""
                    let parts = name.components(separatedBy: "__")
                    let server = parts.count >= 3 && parts[0] == "mcp" ? parts[1] : (name == "Bash" ? "shell" : "")
                    start(id, server: server, tool: parts.last ?? "", arguments: block["input"] as? [String: Any] ?? [:])
                } else if kind == "user", block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    let failed = block["is_error"] as? Bool == true
                    end(id, failed: failed, known: true, reason: failed ? Self.errorReason(block) : .unknown)
                }
            }
        }
    }

    private static func errorReason(_ value: [String: Any]) -> Reason {
        var text = (value["message"] as? String) ?? (value["error"] as? String) ?? ""
        if let content = value["content"] as? String { text += String(content.prefix(8192)) }
        if let blocks = value["content"] as? [[String: Any]] {
            for block in blocks.prefix(4) where block["type"] as? String == "text" {
                text += String((block["text"] as? String ?? "").prefix(2048))
            }
        }
        return Reason.classify(text)
    }

    private func start(_ id: String, server: String, tool: String, arguments: [String: Any], observedStart: Bool = true) {
        let identity = Self.toolIdentity(server: server, tool: tool)
        let call = state.withLock { state -> Call? in
            guard id.utf8.count <= 256 else { state.omitted += 1; return nil }
            guard state.calls[id] == nil else { return nil }
            guard state.calls.count < 512 else { state.omitted += 1; return nil }
            var target: Int?
            if identity.family == "native", let selector = ["app", "app_path", "bundle_id", "application", "app_name"].compactMap({ arguments[$0] as? String }).first {
                let selector = String(selector.prefix(1024))
                if state.targets[selector] == nil, state.targets.count < 64 { state.targets[selector] = state.targets.count + 1 }
                target = state.targets[selector]
            }
            state.started += 1
            let call = Call(ordinal: state.started, tool: identity.tool, family: identity.family, began: observedStart ? Date() : nil, target: target)
            state.calls[id] = call
            return call
        }
        if let call {
            var details = fields(call)
            if identity.family == "native" {
                details["target_lookup_found"] = "unknown"
                if let selector = ["app", "app_path", "bundle_id", "application", "app_name"].compactMap({ arguments[$0] as? String }).first {
                    // Read-only process lookup. Names and paths are compared locally and discarded.
                    let apps = NSWorkspace.shared.runningApplications
                    let count = apps.filter { app in
                        app.bundleIdentifier == selector || app.bundleURL?.path == selector ||
                        app.localizedName?.caseInsensitiveCompare(selector) == .orderedSame
                    }.count
                    details["target_lookup_found"] = String(count > 0)
                    details["target_matches"] = String(count)
                    details["target_evidence"] = "process_lookup"
                }
            }
            details["start_observed"] = String(observedStart)
            breadcrumb("agent.tool_observed", details)
        }
    }

    private func end(_ id: String, failed: Bool, known: Bool, reason: Reason, code: Int? = nil) {
        // A changed or truncated stream can omit the start. Its explicit failure still counts.
        start(id, server: "", tool: "", arguments: [:], observedStart: false)
        let call = state.withLock { state -> Call? in
            guard var call = state.calls[id], !call.ended else { return nil }
            call.ended = true; state.calls[id] = call
            state.completed += 1
            if failed { state.failed += 1; state.lastFailure = reason }
            if !known { state.unknown += 1 }
            state.trail.append("\(call.ordinal):\(call.family).\(call.tool):\(failed ? reason.rawValue : (known ? "ok" : "unknown"))")
            if state.trail.count > 24 { state.trail.removeFirst() }
            return call
        }
        guard let call else { return }
        var details = fields(call)
        details["result"] = failed ? "failed" : (known ? "completed" : "unknown")
        details["reason"] = reason.rawValue
        if let code { details["error_code"] = String(code) }
        details["duration_ms"] = call.began.map { String(max(0, Int(Date().timeIntervalSince($0) * 1000))) } ?? "unknown"
        breadcrumb("agent.tool_finished", details)
        // Preserve a failure even if the user stops later or no unrelated error follows it.
        if failed {
            emit("agent.tool_failed", tags: ["tool": call.tool, "tool_family": call.family, "reason": reason.rawValue, "evidence": "tool_result"], extra: details, affectsOperation: false)
        }
    }

    private func fields(_ call: Call) -> [String: String] {
        var fields = ["tool": call.tool, "tool_family": call.family, "call_index": String(call.ordinal)]
        if let target = call.target { fields["target_index"] = String(target) }
        return fields
    }

    var summary: [String: String] {
        state.withLock { state in
            ["tool_calls": String(state.started), "tool_completed": String(state.completed),
             "tool_failed": String(state.failed), "tool_unknown": String(state.unknown),
             "tool_incomplete": String(state.started - state.completed), "tool_omitted": String(state.omitted),
             "last_tool_reason": state.lastFailure.rawValue, "tool_sequence": state.trail.joined(separator: ";"),
             "process_exit_code": state.exitCode.map(String.init) ?? "unknown",
             "helper_running_at_start": state.helperAtStart.map(String.init) ?? "unknown",
             "helper_running_at_end": state.helperAtEnd.map(String.init) ?? "unknown",
             "process_outcome": state.exitCode.map { $0 == 0 ? "completed" : "failed" } ?? "unknown"]
        }
    }

    private func finish(_ status: AgentStatus?, error: Error? = nil) {
        var details = summary
        let modelStatus: String
        var reason = Reason.unknown.rawValue
        if let status {
            switch status {
            case .done: modelStatus = "done_claimed"
            case .couldNot(let text): modelStatus = "could_not"; reason = Reason.classify(text).rawValue
            case .none: modelStatus = "unconfirmed"
            }
        } else { modelStatus = "not_applicable" }
        let cancelled = error.map(Diagnostics.isCancellation) == true || Task.isCancelled
        let expected = error.map(Diagnostics.isExpected) == true
        let outcome = cancelled ? "cancelled" : (error != nil ? (expected ? "blocked" : "failed") : modelStatus)
        operation?.finish(outcome: outcome)
        details["runtime_outcome"] = cancelled ? "cancelled" : (error == nil ? "completed" : "failed")
        details["model_outcome"] = modelStatus
        details["duration_ms"] = String(max(0, Int(Date().timeIntervalSince(began) * 1000)))
        if let error { details.merge(Diagnostics.errorFields(error)) { _, new in new } }
        breadcrumb("agent.run_finished", details.merging(["outcome": outcome]) { _, new in new })
        let toolFailure = details["tool_failed"] != "0"
        guard (!cancelled && (error != nil || modelStatus == "could_not" || modelStatus == "unconfirmed")) || toolFailure else { return }
        let recovered = error == nil && modelStatus != "could_not" && modelStatus != "unconfirmed"
        emit("agent.run_diagnostic", tags: ["outcome": outcome, "reason": error.map { CodexFailureReason.classify($0).rawValue } ?? (recovered ? details["last_tool_reason"] ?? reason : reason),
             "evidence": error != nil ? "runtime_error" : (recovered ? "tool_result" : "model_status")], extra: details,
             informational: expected && !toolFailure,
             affectsOperation: !cancelled && !expected && (error != nil || modelStatus == "could_not" || modelStatus == "unconfirmed"))
    }

    private func breadcrumb(_ name: String, _ fields: [String: String]) {
        Diagnostics.$current.withValue(operation) {
            CrashReporting.diagnosticBreadcrumb(name, data: correlation.merging(fields) { _, new in new })
        }
    }

    private func emit(_ name: String, tags: [String: String], extra: [String: String], informational: Bool = false, affectsOperation: Bool = true) {
        Diagnostics.$current.withValue(operation) {
            CrashReporting.captureEvent(name, level: informational ? .info : .warning,
                tags: tags.merging(["backend": backend, "trigger": trigger, "feature": feature, "diagnostic_schema": "2"]) { _, new in new },
                extra: correlation.merging(extra) { _, new in new },
                fingerprint: [name, tags["tool_family"] ?? "run", tags["tool"] ?? "none", tags["outcome"] ?? "failed", tags["reason"] ?? "unknown"],
                cooldown: 0, includeInformational: informational, affectsOperation: affectsOperation)
        }
    }
}
