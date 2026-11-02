// Hosted connection management and task capabilities over the authenticated Sentient gateway.
// OAuth completion checks authorization metadata only; it never probes source content or changes opt-in.
// Doc: Connectors/Documentation - Connectors (Direct MCP).md
import Foundation

actor HostedConnectorClient {
    static let shared = HostedConnectorClient()
    @TaskLocal static var override: HostedConnectorClient?
    static var current: HostedConnectorClient { override ?? shared }
    private let client: HostedInferenceClient
    private var lifecycleGeneration = 0
    private var acceptingAuthorizations = true
    private var starting: [UUID: Task<Attempt, Error>] = [:]
    init(client: HostedInferenceClient = .shared) { self.client = client }

    struct Inventory: Codable, Sendable { let connections: [HostedConnectorAccount]; let services: [String]?; let revision: Int }
    struct Attempt: Codable, Sendable {
        let attempt_id: String
        let connection_id: UUID
        let generation: Int
        let redirect_url: URL
        let expires_at: String
        var localGeneration: Int?
    }
    struct AttemptStatus: Codable, Sendable { let status: String; let connection_id: UUID; let generation: Int }
    struct Tool: Codable, Sendable {
        let name: String
        let description: String
        let inputSchema: ConnectorJSON
        let write: Bool
    }
    struct Capability: Codable, Sendable {
        let capability_token: String
        let connection_id: UUID
        let generation: Int
        let tools: [Tool]
    }
    struct Result: Codable, Sendable {
        let status: String
        let data: ConnectorJSON?
        let cursor: String?
        let receipt: ConnectorJSON?
        let replayed: Bool?
    }
    struct UncertainAction: Codable, Sendable, Identifiable {
        let id: UUID
        let tool: String
        let created_at: String
    }

    func refresh() async throws -> Inventory {
        let data = try await client.connectorRequest(path: "v1/connectors", method: "GET")
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        guard inventory.connections.count <= 200, inventory.connections.allSatisfy({ HostedConnectorStore.services.contains($0.service) && $0.generation > 0 }) else { throw HostedConnectorFailure.invalidResponse }
        try HostedConnectorStore.save(inventory.connections, revision: inventory.revision)
        return inventory
    }
    func begin(service: String, label: String, reconnect: HostedConnectorAccount?) async throws -> Attempt {
        guard acceptingAuthorizations else { throw CancellationError() }
        // Persist before dispatch so a crash during browser authorization cannot make reset
        // assume there are no remote records. An inference-only identity needs no cleanup.
        UserDefaults.standard.set(true, forKey: HostedConnectorStore.managementUsedKey)
        let id = UUID(), generation = lifecycleGeneration
        let task = Task { try await startAttempt(service: service, label: label, reconnect: reconnect, generation: generation) }
        starting[id] = task
        defer { starting.removeValue(forKey: id) }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard acceptingAuthorizations, generation == lifecycleGeneration else {
            await cancel(result); throw CancellationError()
        }
        return result
    }
    private func startAttempt(service: String, label: String, reconnect: HostedConnectorAccount?, generation: Int) async throws -> Attempt {
        try Task.checkCancellation()
        guard ModelBackend.current == .sentient, HostedConnectorStore.services.contains(service) else { throw HostedConnectorFailure.connectionChanged }
        var body: [String: ConnectorJSON] = ["service": .string(service), "label": .string(label)]
        if let reconnect { body["connection_id"] = .string(reconnect.id.uuidString.lowercased()) }
        let data = try await client.connectorRequest(path: "v1/connectors/connect", payload: ConnectorJSON.object(body).data())
        var attempt = try JSONDecoder().decode(Attempt.self, from: data)
        attempt.localGeneration = generation
        guard UUID(uuidString: attempt.attempt_id) != nil, attempt.redirect_url.scheme == "https",
              attempt.redirect_url.host == "connect.composio.dev", attempt.redirect_url.path.hasPrefix("/link/"),
              attempt.redirect_url.user == nil, attempt.redirect_url.password == nil else { throw HostedConnectorFailure.invalidResponse }
        if Task.isCancelled || generation != lifecycleGeneration {
            let cleanup = attempt
            await Task.detached { await self.cancel(cleanup) }.value
            throw CancellationError()
        }
        _ = try? await refresh()
        if Task.isCancelled || generation != lifecycleGeneration {
            let cleanup = attempt
            await Task.detached { await self.cancel(cleanup) }.value
            throw CancellationError()
        }
        return attempt
    }
    func poll(_ attempt: Attempt) async throws -> Bool {
        guard acceptingAuthorizations, attempt.localGeneration == lifecycleGeneration else { throw CancellationError() }
        let data = try await client.connectorRequest(path: "v1/connectors/attempts/\(attempt.attempt_id)", method: "GET")
        let result = try JSONDecoder().decode(AttemptStatus.self, from: data)
        guard result.connection_id == attempt.connection_id, result.generation == attempt.generation else { throw HostedConnectorFailure.connectionChanged }
        if result.status == "completed" {
            _ = try await refresh()
            guard acceptingAuthorizations, attempt.localGeneration == lifecycleGeneration else { throw CancellationError() }
            return true
        }
        guard result.status == "pending" else { throw HostedConnectorFailure.authorizationExpired }
        return false
    }
    func cancel(_ attempt: Attempt) async {
        _ = try? await client.connectorRequest(path: "v1/connectors/attempts/\(attempt.attempt_id)/cancel", payload: Data("{}".utf8))
        _ = try? await refresh()
    }
    func disconnect(_ account: HostedConnectorAccount, revokeProvider: Bool = false) async throws {
        let data = try await client.connectorRequest(path: "v1/connectors/\(account.id.uuidString.lowercased())/disconnect",
            payload: ConnectorJSON.object(["revoke_provider": .bool(revokeProvider)]).data())
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        try HostedConnectorStore.save(inventory.connections, revision: inventory.revision)
        // Knowledge selection is independent and stays selected until the user changes it.
        await HostedConnectorToolServer.invalidate(account.id)
    }
    func disconnectAll() async throws {
        acceptingAuthorizations = false; lifecycleGeneration += 1
        defer { acceptingAuthorizations = true }
        let tasks = Array(starting.values); tasks.forEach { $0.cancel() }
        for task in tasks { _ = await task.result }
        guard !HostedConnectorStore.accounts().isEmpty || UserDefaults.standard.bool(forKey: HostedConnectorStore.managementUsedKey) else { return }
        // Reset must not enroll a fresh identity just to discover that it owns no accounts.
        guard try await client.hasSavedIdentity() else { return }
        let inventory = try await refresh()
        for account in inventory.connections where account.status != "disconnected" { try await disconnect(account) }
        let deadline = Date().addingTimeInterval(25)
        while HostedConnectorStore.accounts().contains(where: { $0.status != "disconnected" }) {
            guard Date() < deadline else { throw HostedConnectorFailure.revocationPending }
            try await Task.sleep(for: .seconds(1)); _ = try await refresh()
        }
    }
    func uncertainActions(_ account: HostedConnectorAccount) async throws -> [UncertainAction] {
        struct Response: Decodable { let actions: [UncertainAction] }
        let data = try await client.connectorRequest(path: "v1/connectors/\(account.id.uuidString.lowercased())/uncertain-actions", method: "GET")
        return try JSONDecoder().decode(Response.self, from: data).actions
    }
    func resolve(_ action: UncertainAction, account: HostedConnectorAccount, allowRetry: Bool) async throws {
        _ = try await client.connectorRequest(path: "v1/connectors/\(account.id.uuidString.lowercased())/resolve-action", payload: ConnectorJSON.object([
            "operation_id": .string(action.id.uuidString.lowercased()), "outcome": .string(allowRetry ? "allow_retry" : "reported_completed")
        ]).data())
        await HostedConnectorToolServer.invalidate(account.id)
    }
    func prepare(_ account: HostedConnectorAccount, mode: String, run: HostedInference.Run) async throws -> Capability {
        guard ModelBackend.current == .sentient, HostedConnectorStore.account(account.taskTarget) != nil else { throw HostedConnectorFailure.connectionChanged }
        let data: Data
        do {
            data = try await client.connectorRequest(path: "v1/connectors/capabilities", payload: ConnectorJSON.object([
                "run_id": .string(run.id), "connection_id": .string(account.id.uuidString.lowercased()),
                "generation": .number(Double(account.generation)), "mode": .string(mode)
            ]).data(), run: run, asPrincipal: true)
        } catch HostedInference.Failure.rejected(let code, _) where code == "connection_changed" {
            _ = try? await refresh() // Repair metadata for the NEXT attempt, never retarget this task.
            throw HostedConnectorFailure.connectionChanged
        }
        let result = try JSONDecoder().decode(Capability.self, from: data)
        guard result.connection_id == account.id, result.generation == account.generation,
              result.capability_token.hasPrefix("hct_"), result.capability_token.count == 68,
              !result.tools.isEmpty, result.tools.count <= 32,
              result.tools.allSatisfy({ $0.name.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil && (mode == "action" || !$0.write) }) else { throw HostedConnectorFailure.invalidResponse }
        return result
    }
    func execute(_ capability: Capability, tool: String, arguments: ConnectorJSON, operationID: UUID) async throws -> Result {
        guard let account = HostedConnectorStore.accounts().first(where: { $0.id == capability.connection_id }),
              account.generation == capability.generation, account.connected else { throw HostedConnectorFailure.connectionChanged }
        let data: Data
        do {
            data = try await client.connectorRequest(path: "v1/connectors/execute", payload: ConnectorJSON.object([
                "tool": .string(tool), "arguments": arguments, "operation_id": .string(operationID.uuidString.lowercased())
            ]).data(), capability: capability.capability_token)
        } catch HostedInference.Failure.rejected(let code, _) where code == "write_outcome_unknown" {
            throw HostedConnectorFailure.writeUncertain
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.status == "completed" else { throw HostedConnectorFailure.invalidResponse }
        return result
    }
    func close(_ capability: Capability) async {
        _ = try? await client.connectorRequest(path: "v1/connectors/close", payload: Data("{}".utf8), capability: capability.capability_token)
    }
    func check(_ accounts: [HostedConnectorAccount], run: HostedInference.Run) async throws {
        _ = try await client.connectorRequest(path: "v1/connectors/check", payload: ConnectorJSON.object([
            "connections": .array(accounts.map { .string($0.id.uuidString.lowercased()) })
        ]).data(), run: run)
    }
}
