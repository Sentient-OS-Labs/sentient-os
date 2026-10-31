// Per-task native MCP boundary: authenticates through Codex, preserves native state/action IDs,
// forwards native results unchanged. FIFO calls, cancellation and request deduplication are transport concerns.
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
    private var offeredPermissionSetup = false
    private var reopenOnNextRead = false
    private var recoveredSinceLastState = false
    private var fingerprints: [Data: Data] = [:]
    private var replies: [Data: Data] = [:]
    private var replyOrder: [Data] = []
    private var replyBytes = 0
    private var names: Set<String> = []
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let expiry: Task<Void, Never>
    }
    private var waiters: [Waiter] = []
    private let requestTimeout: TimeInterval
    private let permissionSetupTimeout: TimeInterval

    init(configuration: OpenAIComputerUse.Configuration,
         interaction: SidekickInteraction? = SidekickInteraction.current,
         requestTimeout: TimeInterval = 120,
         permissionSetupTimeout: TimeInterval = OpenAIComputerUseSession.permissionSetupTimeout,
         resolveTarget: @escaping @MainActor @Sendable (String) -> String? = { NativeComputerUseServer.target($0) }) {
        self.requestTimeout = requestTimeout.isFinite && requestTimeout > 0 ? min(requestTimeout, 120) : 120
        self.permissionSetupTimeout = permissionSetupTimeout.isFinite && permissionSetupTimeout > 0
            ? min(permissionSetupTimeout, OpenAIComputerUseSession.permissionSetupTimeout)
            : OpenAIComputerUseSession.permissionSetupTimeout
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
            tools = catalog.values.filter { ($0["name"] as? String) != "diagnose_computer_use" }
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            guard !tools.isEmpty, tools.allSatisfy({ ($0["name"] as? String)?.isEmpty == false }),
                  Set(tools.compactMap { $0["name"] as? String }).count == tools.count else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
            tools.append(Self.diagnosticTool)
            names = Set(tools.compactMap { $0["name"] as? String })
            try Task.checkCancellation()
            // A normal request can discover missing grants at the end of its budget.
            // Keep its outer MCP call alive for the separate permission-setup phase.
            let transport = LocalMCPServer(name: "sentient_native", tools: names.sorted(),
                timeout: requestTimeout + permissionSetupTimeout + 10,
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
        let queued = waiters; waiters.removeAll()
        for waiter in queued {
            waiter.expiry.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
        interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
        let opening = openingSession
        opening?.cancel()
        await transport?.stop(); transport = nil
        await session?.close(); session = nil
        if let opened = try? await opening?.value { await opened.close() }
        replies.removeAll(); fingerprints.removeAll(); tools.removeAll()
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
                  names.contains(tool), let arguments = params["arguments"] as? [String: Any] else {
                return try reply(Self.errorResult(.init(kind: .unknown, code: -32602, detail: .malformedResponse, stage: .transport)))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
            do { try await acquire(deadline: deadline) }
            catch is CancellationError { throw CancellationError() }
            catch {
                let failure = (error as? NativeComputerUseFailure) ?? Self.queueTimeout()
                NativeComputerUseErrorLog.record(tool: tool, failure: failure)
                return try reply(Self.errorResult(failure))
            }
            defer { release() }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            // Keep compact consumed-ID hashes for this task. A fixed count ceiling made
            // every later request fail permanently, including attempts to recover.
            let key = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed, .sortedKeys])))
            let fingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)))
            if let old = fingerprints[key] {
                guard old == fingerprint, let response = replies[key] else {
                    return try reply(Self.errorResult(.init(kind: .unknown, code: nil, detail: .duplicateRequest, stage: .transport)))
                }
                return response
            }
            fingerprints[key] = fingerprint
            let payload: [String: Any]
            do {
                if tool == "diagnose_computer_use" {
                    payload = try await requestDiagnostic(arguments)
                } else { payload = try await observedCall(tool, arguments: arguments, deadline: deadline) }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                let failure = (error as? NativeComputerUseFailure) ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                NativeComputerUseErrorLog.record(tool: tool, failure: failure)
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

    private static func queueTimeout() -> NativeComputerUseFailure {
        var failure = NativeComputerUseFailure(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .transport)
        failure.actionEffectsUnconfirmed = false
        failure.modelError = "Computer-use request expired before it could be sent. No action was executed."
        return failure
    }

    private func acquire(deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, !closed else { continuation.resume(throwing: CancellationError()); return }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { continuation.resume(throwing: Self.queueTimeout()); return }
                let expiry = Task {
                    do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                    self.removeWaiter(id, error: Self.queueTimeout())
                }
                waiters.append(Waiter(id: id, continuation: continuation, expiry: expiry))
            }
        } onCancel: {
            Task { await self.removeWaiter(id, error: CancellationError()) }
        }
    }

    private func removeWaiter(_ id: UUID, error: Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.expiry.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func release() {
        guard !waiters.isEmpty else { busy = false; return }
        let waiter = waiters.removeFirst()
        waiter.expiry.cancel()
        waiter.continuation.resume()
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
            NativePermissionCheck.shared.refresh()
            let grants = NativePermissionCheck.shared.snapshot
            let missing = !Permissions.hasScreenRecording() || grants.accessibility == .denied || grants.screenRecording == .denied
                || automation == .denied || automation == .notAsked
            return (missing: missing, readyForDiagnostic:
                (grants.isReady || NativePermissionSetup.shared.canAttemptTask) && automation == .granted)
        }
        guard !permissionState.missing else {
            interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
            return try response("permission_needed", "A required macOS grant is missing. Help the user fix the specific permission in Permissions & Help. A diagnostic window is unnecessary and was not opened.")
        }
        guard permissionState.readyForDiagnostic else {
            interaction?.computerUseCheckConsent.invalidate(owner: diagnosticOwner)
            return try response("permission_unverified", "The app cannot confirm that all required permissions are granted. Do not assume a broad outage or offer a diagnostic window. Continue available recovery; the user can review Permissions & Help or choose Test & repair there.")
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
            await session?.close(); session = nil
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

    private func observedCall(_ tool: String, arguments: [String: Any], deadline: TimeInterval) async throws -> [String: Any] {
        let result = try await call(tool, arguments: arguments, deadline: deadline)
        guard NativeComputerUseFailure.isError(result) else {
            diagnosticPolicy.observe(tool: tool, target: nil, failure: nil)
            return result
        }
        let selector = arguments["app"] as? String
        let identity = await targetIdentity(selector)
        let browser = await MainActor.run {
            guard let app = selector.flatMap({ Self.resolve($0) }) else { return false }
            if let id = app.bundleIdentifier, ComputerUseDiagnosticPolicy.isBrowser(id) { return true }
            guard let url = app.bundleURL else { return false }
            if ComputerUseDiagnosticPolicy.isBrowser(url.path) { return true }
            let types = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
            return types.contains { type in
                let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
                return schemes.contains { ["http", "https"].contains($0.lowercased()) }
            }
        }
        let target = identity.map { ComputerUseDiagnosticPolicy.Target(id: $0,
            isBrowser: browser || ComputerUseDiagnosticPolicy.isBrowser($0)) }
        diagnosticPolicy.observe(tool: tool, target: target,
            failure: NativeComputerUseFailure.classify(result, stage: tool == "get_app_state" ? .appState : .action))
        return result
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
        if reopenOnNextRead, tool == "get_app_state" || tool == "list_apps" {
            reopenOnNextRead = false
            recoveredSinceLastState = true
            await session?.close()
            session = nil
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        }
        if let session, await session.isUsable() { return session }
        guard tool == "get_app_state" || tool == "list_apps" else {
            throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .disconnected, stage: .transport)
        }
        await session?.close(); session = nil
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let diagnostics = CaptureDiagnostics(source: .native, context: diagnosticContext)
        diagnostics.record(.started, fields: ["recovery_decision": "reopen_on_read", "tool": tool])
        let opened = try await openSession()
        session = opened
        diagnostics.record(.recovered, fields: ["recovery_decision": "reopen_on_read", "tool": tool])
        return opened
    }

    private func call(_ tool: String, arguments: [String: Any],
                      deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 120) async throws -> [String: Any] {
        guard !closed else { throw CancellationError() }
        let diagnostics = CaptureDiagnostics(source: .native, context: diagnosticContext)
        let isState = tool == "get_app_state"
        let target = await MainActor.run { (arguments["app"] as? String).flatMap { Self.resolve($0) } }
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        let evidence = await CaptureDiagnostics.environment(target: target)
        let began = ProcessInfo.processInfo.systemUptime
        var nativeError: [String: Any]?
        var dispatched = false
        do {
            try Task.checkCancellation()
            guard deadline > ProcessInfo.processInfo.systemUptime else { throw Self.queueTimeout() }
            let session = try await currentSession(for: tool)
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !closed else { throw CancellationError() }
            guard remaining > 0 else { throw Self.queueTimeout() }
            dispatched = true
            let data = try await session.call(tool, arguments: encoded, timeout: min(isState ? 90 : 120, remaining))
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            guard var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
            }
            if NativeComputerUseFailure.isError(result) {
                nativeError = result
                throw NativeComputerUseFailure.classify(result, stage: isState ? .appState : .action)
            }
            if isState {
                result = try OpenAIComputerUseProbe.appStateResult(result)
                reopenOnNextRead = false
                recoveredSinceLastState = false
            }
            diagnostics.record(.passed, fields: evidence.merging([
                "tool": tool, "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))
            ]) { _, new in new })
            return result
        } catch {
            let fields = evidence.merging(["tool": tool,
                "duration_ms": String(Int((ProcessInfo.processInfo.systemUptime - began) * 1000))]) { _, new in new }
            if error is CancellationError || Task.isCancelled || closed {
                diagnostics.record(.cancelled, fields: fields)
                throw CancellationError()
            }
            var failure = (error as? NativeComputerUseFailure)
                ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
            failure.actionEffectsUnconfirmed = dispatched && tool != "list_apps" && !isState
            NativeComputerUseErrorLog.record(tool: tool, failure: failure)
            if failure.permitsSessionRecovery, !recoveredSinceLastState {
                reopenOnNextRead = true
            }
            if failure.kind == .permission || failure.requiresSystemPermissionSetup {
                let permissionFailure = failure
                await MainActor.run { NativePermissionCheck.shared.invalidate(failure: permissionFailure) }
            }
            if failure.requiresSystemPermissionSetup {
                let token: UUID? = await MainActor.run {
                    guard !Task.isCancelled, !NativePermissionCheck.shared.isTearingDown else { return nil }
                    return NativePermissionSetup.shared.permissionFailed()
                }
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                // One permission-setup phase per task, with a fresh user-facing budget.
                // Keep it owned by this call so Stop cancels it and drains the same session.
                // The failed action is never replayed; return its original error afterward.
                if let token, !offeredPermissionSetup, let connection = session {
                    offeredPermissionSetup = true
                    let setupTimeout = permissionSetupTimeout
                    do {
                        _ = try await NativeHelperPermissionNote.withGuide(appURL: configuration.appURL) {
                            try await NativePermissionReadiness.helperSetup { tool, arguments in
                                try await connection.call(tool, arguments: arguments, timeout: setupTimeout)
                            }
                        }
                        try Task.checkCancellation()
                        guard !closed else { throw CancellationError() }
                        await MainActor.run { NativePermissionSetup.shared.recovered(ifCurrent: token) }
                    } catch {
                        if error is CancellationError || Task.isCancelled || closed { throw CancellationError() }
                        if let setupFailure = error as? NativeComputerUseFailure {
                            NativeComputerUseErrorLog.record(tool: "permission_setup", failure: setupFailure)
                        }
                        // Leave recovery available in Sentient's permission screen. A helper
                        // relaunch, dismissal or timeout never becomes a false success.
                    }
                }
            }
            diagnostics.record(.failed, failure: failure, fields: fields)
            return nativeError ?? Self.errorResult(failure)
        }
    }

    @MainActor private static func resolve(_ selector: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        guard let index = matchingTargetIndex(selector, targets: apps.map {
            (id: $0.bundleIdentifier, path: $0.bundleURL?.path, name: $0.localizedName)
        }) else { return nil }
        return apps[index]
    }

    /// Best-effort diagnostic attribution only; never gates or rewrites a native request.
    /// Display names may contain invisible direction marks (WhatsApp starts with U+200E).
    /// Match their visible spelling without weakening exact bundle/path identity or choosing
    /// arbitrarily between apps whose display names normalize to the same text.
    static func matchingTargetIndex(_ selector: String,
                                    targets: [(id: String?, path: String?, name: String?)]) -> Int? {
        let exact = targets.indices.filter { targets[$0].id == selector || targets[$0].path == selector }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        func visibleName(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter {
                // Unicode Bidi_Control only; preserve meaningful joiners, accents and letters.
                ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                  0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
            }))
        }
        let name = visibleName(selector)
        guard !name.isEmpty else { return nil }
        let matches = targets.indices.filter {
            targets[$0].name.map { visibleName($0).caseInsensitiveCompare(name) == .orderedSame } == true
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
        let message = failure.rawError.flatMap { String(data: $0, encoding: .utf8) }
            ?? failure.modelError ?? "Sentient computer-use error: \(failure.detail.rawValue)"
        var metadata: [String: Any] = ["sentient_native_failure": evidence]
        if let raw = failure.rawError, let object = try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed) {
            metadata["native_error"] = object
        }
        return ["isError": true, "content": [["type": "text", "text": message]],
            "structuredContent": metadata]
    }
}
