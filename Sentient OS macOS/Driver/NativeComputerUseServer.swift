// Per-task native MCP boundary: authenticates through Codex, preserves native state/action IDs,
// and retries a failed state read once after restoring that exact app's window. Never retries actions.
// Doc: Documentation - Native Computer Use.md

import Foundation
import AppKit
import CryptoKit

actor NativeComputerUseServer {
    private let diagnosticContext = CaptureDiagnostics(source: .native)
    private let configuration: OpenAIComputerUse.Configuration
    private var session: OpenAIComputerUseSession?
    private var transport: LocalMCPServer?
    private var tools: [[String: Any]] = []
    private var closed = false
    private var busy = false
    private var retried: Set<String> = []
    private var verified: Set<String> = []
    private var terminal: NativeComputerUseFailure?
    private var fingerprints: [String: Data] = [:]
    private var replies: [String: Data] = [:]
    private var replyOrder: [String] = []
    private var replyBytes = 0
    private static let names: Set<String> = ["list_apps", "get_app_state", "click", "perform_secondary_action",
        "set_value", "select_text", "scroll", "drag", "press_key", "type_text"]

    init(configuration: OpenAIComputerUse.Configuration) { self.configuration = configuration }

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
            let transport = LocalMCPServer(name: "sentient_native", tools: Self.names.sorted(), timeout: 270,
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
                return try reply(Self.errorResult(.init(kind: .unknown, code: -32602, detail: .malformedResponse, stage: .transport)))
            }
            let key = String(decoding: try JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), as: UTF8.self)
            let fingerprint = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: params, options: .sortedKeys)))
            if let old = fingerprints[key] {
                guard old == fingerprint, let response = replies[key] else {
                    return try reply(Self.errorResult(.init(kind: .unknown, code: nil, detail: .staleState, stage: .action)))
                }
                return response
            }
            guard !busy, fingerprints.count < 1024 else {
                return try reply(Self.errorResult(.init(kind: .connection, code: nil, detail: .concurrentCall, stage: .transport)))
            }
            fingerprints[key] = fingerprint
            busy = true
            defer { busy = false }
            let payload: [String: Any]
            if let terminal { payload = Self.errorResult(terminal) }
            else {
                do { payload = try await call(tool, arguments: arguments) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let failure = (error as? NativeComputerUseFailure) ?? .init(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                    terminal = failure; payload = Self.errorResult(failure)
                }
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
        let target = await MainActor.run { selector.flatMap { NativeWindowRecovery.resolve($0) } }
        let identity = target?.bundleURL?.standardizedFileURL.path
        if tool != "list_apps", !isState, identity.map({ verified.contains($0) }) != true {
            throw NativeComputerUseFailure(kind: .unknown, code: nil, detail: .staleState, stage: .action)
        }
        let encoded = try JSONSerialization.data(withJSONObject: arguments)
        func perform(_ attempt: Int) async throws -> [String: Any] {
            let evidence = await CaptureDiagnostics.environment(target: target)
            let began = Date()
            do {
                let data = try await session.call(tool, arguments: encoded)
                guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
                }
                if NativeComputerUseFailure.isError(result) { throw NativeComputerUseFailure.classify(result, stage: isState ? .appState : .action) }
                if isState { try OpenAIComputerUseProbe.validateResult(result, requiresCapture: true) }
                if isState {
                    diagnostics.record(attempt == 1 ? .passed : .recovered, attempt: attempt,
                        fields: evidence.merging(["duration_ms": String(Int(Date().timeIntervalSince(began) * 1000)), "image_valid": "true"]) { _, new in new })
                }
                return result
            } catch {
                diagnostics.record(error is CancellationError ? .cancelled : .failed, attempt: attempt,
                    failure: error as? NativeComputerUseFailure,
                    fields: evidence.merging(["tool": tool, "duration_ms": String(Int(Date().timeIntervalSince(began) * 1000))]) { _, new in new })
                throw error
            }
        }
        do {
            let result = try await perform(1)
            if isState {
                let current = await MainActor.run { selector.flatMap { NativeWindowRecovery.resolve($0) } }
                if let identity = current?.bundleURL?.standardizedFileURL.path { verified.insert(identity) }
            }
            return result
        } catch let failure as NativeComputerUseFailure {
            if let identity { verified.remove(identity) }
            let decision: String
            if !isState || !failure.allowsWindowRecovery { decision = "ineligible_failure" }
            else if target == nil || identity == nil { decision = "target_not_unique" }
            else if retried.contains(identity!) { decision = "budget_exhausted" }
            else { decision = "restore_window" }
            diagnostics.record(decision == "restore_window" ? .started : .skipped, fields: ["recovery_decision": decision])
            guard decision == "restore_window", let target, let identity else { throw failure }
            retried.insert(identity)
            try Task.checkCancellation()
            do {
                let fields = try await NativeWindowRecovery.restore(target)
                diagnostics.record(.started, attempt: 2, fields: fields)
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                let result = try await perform(2)
                verified.insert(identity)
                return result
            } catch {
                if let failure = error as? NativeComputerUseFailure, failure.stage == .recovery {
                    diagnostics.record(.failed, attempt: 2, failure: failure)
                }
                throw error
            }
        }
    }
    private static func errorResult(_ failure: NativeComputerUseFailure) -> [String: Any] {
        ["isError": true, "content": [["type": "text", "text": "\(failure.code.map { "Computer Use server error \($0): " } ?? "Native computer use failed: ")\(failure.detail.rawValue)"]]]
    }
}
