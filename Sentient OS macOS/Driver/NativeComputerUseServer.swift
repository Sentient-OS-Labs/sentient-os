// Per-task native MCP boundary: authenticates through Codex, preserves native state/action IDs,
// and retries transient app-state reads before they reach the model. Never retries actions.
// Doc: Documentation - Native Computer Use.md

import Foundation
import AppKit
import CryptoKit

actor NativeComputerUseServer {
    private let diagnosticContext = CaptureDiagnostics(source: .native)
    private let configuration: OpenAIComputerUse.Configuration
    private let resolveTarget: @MainActor @Sendable (String) -> String?
    private var session: OpenAIComputerUseSession?
    private var transport: LocalMCPServer?
    private var tools: [[String: Any]] = []
    private var closed = false
    private var busy = false
    private var verified: Set<String> = []
    private var fingerprints: [String: Data] = [:]
    private var replies: [String: Data] = [:]
    private var replyOrder: [String] = []
    private var replyBytes = 0
    private static let names: Set<String> = ["list_apps", "get_app_state", "click", "perform_secondary_action",
        "set_value", "select_text", "scroll", "drag", "press_key", "type_text"]

    init(configuration: OpenAIComputerUse.Configuration,
         resolveTarget: @escaping @MainActor @Sendable (String) -> String? = { NativeComputerUseServer.target($0) }) {
        self.configuration = configuration
        self.resolveTarget = resolveTarget
    }

    func start() async throws -> LocalMCPServer.Connection {
        do {
            let session = try await OpenAIComputerUseSession.open(configuration)
            self.session = session
            let data = try await session.catalog()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["data"] as? [[String: Any]],
                  let server = servers.first(where: { $0["name"] as? String == "sentient_native" }),
                  let catalog = server["tools"] as? [String: [String: Any]] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
            tools = catalog.values.filter { Self.names.contains($0["name"] as? String ?? "") }
                .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            guard Set(tools.compactMap { $0["name"] as? String }) == Self.names else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .catalog)
            }
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
        await transport?.stop(); transport = nil
        await session?.close(); session = nil
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
            let key = String(decoding: try JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), as: UTF8.self)
            let fingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)))
            if let old = fingerprints[key] {
                guard old == fingerprint, let response = replies[key] else {
                    verified.removeAll()
                    return try reply(Self.errorResult(.init(kind: .unknown, code: nil, detail: .staleState, stage: .action)))
                }
                return response
            }
            guard !busy, fingerprints.count < 1024 else {
                verified.removeAll()
                return try reply(Self.errorResult(.init(kind: .connection, code: nil, detail: .concurrentCall, stage: .transport)))
            }
            fingerprints[key] = fingerprint
            busy = true
            defer { busy = false }
            let payload: [String: Any]
            do { payload = try await call(tool, arguments: arguments) }
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

    private func call(_ tool: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let session, !closed else { throw CancellationError() }
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
