// Per-task native MCP boundary: authenticates through Codex, preserves native state/action IDs,
// and retries transient app-state reads before they reach the model. Never retries actions.
// Doc: Documentation - Native Computer Use.md

import Foundation
import AppKit
import CryptoKit

actor NativeComputerUseServer {
    private let diagnosticContext = CaptureDiagnostics(source: .native)
    private let modelBackend = ModelBackend.current
    private let interaction: SidekickInteraction?
    private let diagnosticOwner = UUID()
    private var diagnosticPolicy = ComputerUseDiagnosticPolicy()
    private let configuration: OpenAIComputerUse.Configuration
    private let resolveTarget: @MainActor @Sendable (String) -> String?
    private var session: OpenAIComputerUseSession?
    private var openingSession: Task<OpenAIComputerUseSession, Error>?
    private var transport: LocalMCPServer?
    private var tools: [[String: Any]] = []
    private var closed = false
    private var busy = false
    private var verified: Set<String> = []
    private var fingerprints: [Data: Data] = [:]
    private var replies: [Data: Data] = [:]
    private var replyOrder: [Data] = []
    private var replyBytes = 0
    private static let nativeNames: Set<String> = ["list_apps", "get_app_state", "click", "perform_secondary_action",
        "set_value", "select_text", "scroll", "drag", "press_key", "type_text"]
    private static let names = nativeNames.union(["diagnose_computer_use"])

    init(configuration: OpenAIComputerUse.Configuration,
         interaction: SidekickInteraction? = SidekickInteraction.current,
         resolveTarget: @escaping @MainActor @Sendable (String) -> String? = { NativeComputerUseServer.target($0) }) {
        self.configuration = configuration
        self.interaction = interaction
        self.resolveTarget = resolveTarget
    }

    func start() async throws -> LocalMCPServer.Connection {
        do {
            let session = try await openSession()
            self.session = session
            let data = try await session.catalog()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["data"] as? [[String: Any]],
                  let server = servers.first(where: { $0["name"] as? String == "sentient_native" }),
                  let catalog = server["tools"] as? [String: [String: Any]] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
            tools = catalog.values.filter { Self.nativeNames.contains($0["name"] as? String ?? "") }
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            guard Set(tools.compactMap { $0["name"] as? String }) == Self.nativeNames else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
            tools.append(Self.diagnosticTool)
            try Task.checkCancellation()
            let transport = LocalMCPServer(name: "sentient_native", tools: Self.names.sorted(), timeout: 130,
                maximumBody: 1_048_576) { [weak self] request in
                guard let self else { throw CancellationError() }
                return try await self.respond(request)
            }
            self.transport = transport
            return try await transport.start()
        } catch {
            CaptureDiagnostics(source: .native, context: diagnosticContext).record(.failed, failure: error as? NativeComputerUseFailure)
            await stop(); throw error
        }
    }
    func stop() async {
        closed = true
        interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
        let opening = openingSession
        opening?.cancel()
        await transport?.stop(); transport = nil
        await session?.close(); session = nil
        if let opened = try? await opening?.value { await opened.close() }
        replies.removeAll(); fingerprints.removeAll(); tools.removeAll()
        verified.removeAll()
    }
    func respond(_ data: Data) async throws -> Data {
        guard !closed, let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = rpc["id"] else { throw CancellationError() }
        func reply(_ result: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]) }
        switch rpc["method"] as? String {
        case "initialize":
            let params = rpc["params"] as? [String: Any]
            return try reply(["protocolVersion": params?["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "Sentient native computer use", "version": "1"]])
        case "ping": return try reply([:])
        case "tools/list": return try reply(["tools": tools])
        case "tools/call":
            guard let params = rpc["params"] as? [String: Any], let tool = params["name"] as? String,
                  Self.names.contains(tool), let arguments = params["arguments"] as? [String: Any] else {
                verified.removeAll()
                return try reply(Self.errorResult(.init(kind: .unknown, code: -32602, detail: .malformedResponse, stage: .transport)))
            }
            // Keep compact consumed-ID hashes for this task. A fixed count ceiling made
            // every later request fail permanently, including attempts to recover.
            let key = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed, .sortedKeys])))
            let fingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)))
            if let old = fingerprints[key] {
                guard old == fingerprint, let response = replies[key] else {
                    verified.removeAll()
                    return try reply(Self.errorResult(.init(kind: .unknown, code: nil, detail: .staleState, stage: .action)))
                }
                return response
            }
            guard !busy else {
                verified.removeAll()
                return try reply(Self.errorResult(.init(kind: .connection, code: nil, detail: .concurrentCall, stage: .transport)))
            }
            fingerprints[key] = fingerprint
            busy = true
            defer { busy = false }
            let payload: [String: Any]
            do {
                if tool == "diagnose_computer_use" {
                    payload = try await requestDiagnostic(arguments)
                } else { payload = try await observedCall(tool, arguments: arguments) }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                verified.removeAll()
                let failure = (error as? NativeComputerUseFailure) ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                payload = Self.errorResult(failure)
            }
            let response = try reply(payload)
            replies[key] = response; replyOrder.append(key); replyBytes += response.count
            // Never replay an evicted action. Its fingerprint remains as a consumed request ID.
            while replyOrder.count > 8 || replyBytes > 32 * 1_048_576 {
                let oldest = replyOrder.removeFirst()
                replyBytes -= replies.removeValue(forKey: oldest)?.count ?? 0
            }
            return response
        default:
            return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id,
                "error": ["code": -32601, "message": "Method unavailable"]])
        }
    }

    private static var diagnosticTool: [String: Any] {
        ["name": "diagnose_computer_use", "description": "Last-resort diagnostic for a broadly unavailable computer-use service, after relevant recovery and alternatives cannot complete the remaining task. Never use for a browser-specific bug, one app/window, changed Spaces, stale elements, interrupted typing, or a known missing permission. First call without approval_id: the app checks actual recent failure evidence and, only if eligible, returns an ID and instructions for asking through sentient_recovery.ask_user. No window opens and no connection resets until the user chooses Run check and you call again with that approval_id. Not now means do not ask again in this task. This never ends the original task or sends a report. Call alone.",
         "inputSchema": ["type": "object", "properties": ["approval_id": ["type": "string", "description": "The ID returned by this tool, only after the app's consent question was answered with Run check."]], "required": [], "additionalProperties": false]]
    }

    private func requestDiagnostic(_ arguments: [String: Any]) async throws -> [String: Any] {
        func response(_ status: String, _ message: String, extra: [String: Any] = [:]) throws -> [String: Any] {
            let value = ["status": status, "message": message].merging(extra) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        }
        guard Set(arguments.keys).isSubset(of: ["approval_id"]),
              arguments["approval_id"] == nil || arguments["approval_id"] is String else {
            return try response("invalid_request", "Use only the approval ID returned by this tool. Nothing was tested.")
        }
        guard diagnosticPolicy.eligible else {
            interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
            return try response("not_needed", "There is no evidence of a broad computer-use outage. Continue normal recovery. An app/browser-specific failure needs a fresh read or a suitable alternative, not a diagnostic window. Do not manufacture failures or open unrelated apps to qualify. The user can always run a check manually in Health.")
        }
        let automation = await Permissions.nativeAutomationState(ask: false)
        let permissionState = await MainActor.run {
            let grants = [Permissions.tccState(service: "kTCCServiceAccessibility", clientBundleID: OpenAIComputerUse.bundleID),
                          Permissions.tccState(service: "kTCCServiceScreenCapture", clientBundleID: OpenAIComputerUse.bundleID)]
            let missing = !Permissions.hasScreenRecording() || grants.contains(.denied) || grants.contains(.notAsked)
                || automation == .denied || automation == .notAsked
            return (missing: missing, verified: grants.allSatisfy { $0 == .granted } && automation == .granted)
        }
        guard !permissionState.missing else {
            interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
            return try response("permission_needed", "A required macOS grant is missing. Help the user fix the specific permission in Permissions & Health. A diagnostic window is unnecessary and was not opened.")
        }
        guard permissionState.verified else {
            interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
            return try response("permission_unverified", "The app cannot confirm that all required permissions are granted. Do not assume a broad outage or offer a diagnostic window. Continue available recovery; the user can review Permissions & Health or choose Test & repair there.")
        }
        guard let interaction else {
            return try response("approval_unavailable", "This run cannot ask for interactive approval. Do not open a diagnostic window. The user can run Test & repair in Health if needed.")
        }
        if let supplied = arguments["approval_id"] as? String {
            guard let id = UUID(uuidString: supplied),
                  let authorization = interaction.computerUseCheckConsent.consume(id: id, owner: diagnosticOwner) else {
                return try response("not_approved", "No unused Run check approval exists for this request. Do not start a check or repeat a declined question. Continue the task where possible.")
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            // Both the window and connection change follow an actual, single-use user approval.
            await session?.close(); session = nil; verified.removeAll()
            let report = try await ComputerUseDoctor.shared.checkFromAgent(authorization: authorization, backend: modelBackend) { [weak self] name, data in
                guard let self, let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CancellationError() }
                return try await self.diagnosticCall(name, arguments: values)
            }
            return ["content": [["type": "text", "text": String(decoding: report, as: UTF8.self)
                + "\nThis is diagnostic evidence, not the end of the user's task. Continue using available capabilities or ask for a specific missing permission. No report was uploaded."]]]
        }
        guard let request = interaction.computerUseCheckConsent.request(owner: diagnosticOwner) else {
            return try response("already_offered", "A diagnostic has already been offered in this task. Do not ask again. Continue normal recovery or explain the specific remaining blocker.")
        }
        return try response("needs_confirmation", "Ask through sentient_recovery.ask_user using the supplied computer_use_check_id, error=null, question and answers. The app will display its own fixed consent question. Only after Run check is chosen, call diagnose_computer_use with approval_id. A decline or unanswered question is never approval. Nothing has been tested, opened or reset.", extra: [
            "approval_id": request.id.uuidString, ComputerUseDiagnosticConsent.argument: request.id.uuidString,
            "question": ComputerUseDiagnosticConsent.question, "answers": ComputerUseDiagnosticConsent.answers])
    }

    private func observedCall(_ tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        do {
            let result = try await call(tool, arguments: arguments)
            diagnosticPolicy.observe(tool: tool, target: nil, failure: nil)
            return result
        } catch {
            let selector = arguments["app"] as? String
            let identity = await targetIdentity(selector)
            let browser = await MainActor.run {
                guard let app = selector.flatMap({ Self.resolve($0) }) else { return false }
                if let id = app.bundleIdentifier, ComputerUseDiagnosticPolicy.isBrowser(id) { return true }
                guard let url = app.bundleURL else { return false }
                if ComputerUseDiagnosticPolicy.isBrowser(url.path) { return true }
                // Conservatively exclude unfamiliar browsers too, using their declared web schemes.
                let types = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
                return types.contains { type in
                    let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
                    return schemes.contains { ["http", "https"].contains($0.lowercased()) }
                }
            }
            let target = identity.map { ComputerUseDiagnosticPolicy.Target(id: $0,
                isBrowser: browser || ComputerUseDiagnosticPolicy.isBrowser($0)) }
            if let failure = error as? NativeComputerUseFailure {
                diagnosticPolicy.observe(tool: tool, target: target, failure: failure)
            } else { diagnosticPolicy = ComputerUseDiagnosticPolicy() }
            throw error
        }
    }

    private func diagnosticCall(_ name: String, arguments: [String: Any]) async throws -> Data {
        guard !closed, ["get_app_state", "click", "set_value"].contains(name),
              arguments["app"] as? String == Bundle.main.bundleURL.path else { throw CancellationError() }
        let result = try await call(name, arguments: arguments)
        return try JSONSerialization.data(withJSONObject: result)
    }

    private func openSession() async throws -> OpenAIComputerUseSession {
        let configuration = configuration
        let opening = Task { try await OpenAIComputerUseSession.open(configuration) }
        openingSession = opening
        defer { openingSession = nil }
        let opened = try await withTaskCancellationHandler {
            try await opening.value
        } onCancel: { opening.cancel() }
        guard !closed, !Task.isCancelled else { await opened.close(); throw CancellationError() }
        return opened
    }

    /// Recovery follows a new model-requested read. Never replay an action or
    /// restart a healthy session merely because a native tool returned an error.
    private func currentSession(for tool: String) async throws -> OpenAIComputerUseSession {
        guard !closed else { throw CancellationError() }
        if let session, await session.isUsable() { return session }
        verified.removeAll()
        guard tool == "get_app_state" || tool == "list_apps" else {
            throw NativeComputerUseFailure(kind: .unknown, code: nil, detail: .staleState, stage: .action)
        }
        await session?.close(); session = nil
        let diagnostics = CaptureDiagnostics(source: .native, context: diagnosticContext)
        diagnostics.record(.started, fields: ["recovery_decision": "reopen_on_read", "tool": tool])
        let opened = try await openSession()
        session = opened
        diagnostics.record(.recovered, fields: ["recovery_decision": "reopen_on_read", "tool": tool])
        return opened
    }

    private func call(_ tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard !closed else { throw CancellationError() }
        let diagnostics = CaptureDiagnostics(source: .native, context: diagnosticContext)
        let isState = tool == "get_app_state"
        let selector = arguments["app"] as? String
        let target = await MainActor.run { selector.flatMap { Self.resolve($0) } }
        let identity = await targetIdentity(selector)
        if tool != "list_apps", !isState, identity.map({ verified.contains($0) }) != true {
            verified.removeAll()
            throw NativeComputerUseFailure(kind: .unknown, code: nil, detail: .staleState, stage: .action)
        }
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let evidence = await CaptureDiagnostics.environment(target: target)
        let began = ProcessInfo.processInfo.systemUptime
        var attempt = 1
        do {
            let session = try await currentSession(for: tool)
            while true {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - began)
                let remaining = NativeAppStateRetry.timeout - elapsed
                if isState && remaining <= 0 {
                    throw NativeComputerUseFailure(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .appState)
                }
                do {
                    // All retries share one deadline inside the outer 130s MCP timeout.
                    // A timed-out client request closes its transport and is not retryable.
                    let data = try await session.call(tool, arguments: encoded, timeout: isState ? remaining : 125)
                    try Task.checkCancellation()
                    guard !closed else { throw CancellationError() }
                    guard var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                    }
                    if NativeComputerUseFailure.isError(result) {
                        throw NativeComputerUseFailure.classify(result, stage: isState ? .appState : .action)
                    }
                    if isState {
                        result = try OpenAIComputerUseProbe.appStateResult(result)
                        let current = await targetIdentity(selector)
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        if let current { verified.insert(current) }
                        diagnostics.record(attempt == 1 ? .passed : .recovered, attempt: attempt,
                            fields: evidence.merging([
                                "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)),
                                "image_valid": String((result["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image" } == true)
                            ]) { _, new in new })
                    }
                    return result
                } catch {
                    guard !Task.isCancelled, !closed else { throw CancellationError() }
                    guard isState, let failure = error as? NativeComputerUseFailure,
                          let delay = NativeAppStateRetry.delay(afterAttempt: attempt, failure: failure,
                              elapsed: ProcessInfo.processInfo.systemUptime - began) else { throw error }
                    if let identity { verified.remove(identity) }
                    // Transient attempts stay internal: one model tool call remains pending.
                    // The final failed read reaches the model, which decides the next step.
                    diagnostics.record(.skipped, attempt: attempt, failure: failure,
                        fields: evidence.merging(["tool": tool, "recovery_decision": "wait_and_reread",
                            "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))]) { _, new in new })
                    try await Task.sleep(for: .seconds(delay))
                    attempt += 1
                }
            }
        } catch {
            verified.removeAll()
            let fields = evidence.merging(["tool": tool,
                "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))]) { _, new in new }
            if error is CancellationError || Task.isCancelled || closed {
                diagnostics.record(.cancelled, attempt: attempt, fields: fields)
                throw CancellationError()
            }
            var failure = (error as? NativeComputerUseFailure)
                ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
            failure.actionEffectsUnconfirmed = tool != "list_apps" && !isState
            diagnostics.record(.failed, attempt: attempt, failure: failure, fields: fields)
            throw failure
        }
    }

    @MainActor private static func resolve(_ selector: String) -> NSRunningApplication? {
        let matches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier == selector || $0.bundleURL?.path == selector
                || $0.localizedName?.caseInsensitiveCompare(selector) == .orderedSame)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    @MainActor private static func target(_ selector: String) -> String? {
        resolve(selector)?.bundleURL?.standardizedFileURL.path
    }

    private func targetIdentity(_ selector: String?) async -> String? {
        guard let selector else { return nil }
        return await resolveTarget(selector)
    }

    private static func errorResult(_ failure: NativeComputerUseFailure) -> [String: Any] {
        var evidence: [String: Any] = ["version": 1, "kind": failure.kind.rawValue, "detail": failure.detail.rawValue,
            "stage": failure.stage.rawValue,
            "effects_may_be_unknown": failure.effectsMayBeUnknown]
        if let code = failure.code { evidence["native_code"] = code }
        var lines = ["\(failure.code.map { "Computer Use server error \($0): " } ?? "Native computer use failed: ")\(failure.detail.rawValue)"]
        if let detail = failure.modelError { lines.append("Native error detail: " + detail) }
        lines.append(failure.modelGuidance)
        // Codex's model-facing failed-tool formatter retains only the first text block.
        // Preserve the actual native error and recovery guidance together in that block.
        return ["isError": true, "content": [["type": "text", "text": lines.joined(separator: "\n")]],
            "structuredContent": ["sentient_native_failure": evidence]]
    }
}
