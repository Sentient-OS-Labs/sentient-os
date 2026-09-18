#if DEBUG
//
// DirectMCPTests.swift
// Connector-lab checks for OAuth parsing, callback transactions, Keychain replacement and
// real engine argument restrictions. All credentials in directcheck are synthetic.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation
import SwiftUI
import AppKit
import os
import Security

enum DirectMCPTests {
    static func check() async {
        var passed = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(name) }; passed += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { passed += 1; return }
            throw Failure(name)
        }
        do {
            try expect(DirectMCPCrypto.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC 7636 S256 vector")
            let verifier = try DirectMCPCrypto.random()
            try expect(verifier.count == 43 && !verifier.contains("="), "secure base64url verifier")
            let metadata = DirectMCPAuth.metadataURLs(URL(string: "https://auth.example.com/tenant1")!).map(\.absoluteString)
            try expect(metadata == ["https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
                "https://auth.example.com/.well-known/openid-configuration/tenant1",
                "https://auth.example.com/tenant1/.well-known/openid-configuration"], "issuer path discovery")
            let challenge = try DirectMCPAuth.challengeParameters("Bearer realm=\"OAuth\", resource_metadata=\"https://mcp.granola.ai/.well-known/oauth-protected-resource\", scope=\"mcp\"")
            try expect(challenge["scope"] == "mcp", "challenge scopes")
            try rejects("ambiguous metadata challenge") { _ = try DirectMCPAuth.challengeParameters("Bearer resource_metadata=one, resource_metadata=two") }
            for url in ["http://mcp.granola.ai/mcp", "https://mcp.granola.ai.evil.example/mcp", "https://user@mcp.granola.ai/mcp", "https://mcp.granola.ai:123/mcp", "https://127.0.0.1/mcp"] {
                try rejects("untrusted endpoint") { try DirectMCPProvider.granola.validate(URL(string: url)!) }
            }
            try expect(DirectMCPCallback.parse("GET /oauth/granola?code=abc&state=good HTTP/1.1\r\n\r\n", path: "/oauth/granola", state: "good", issuer: "https://auth.example.com") != nil, "valid callback")
            for request in ["GET /favicon.ico HTTP/1.1\r\n\r\n", "GET /oauth/granola?code=abc&state=bad HTTP/1.1\r\n\r\n", "GET /oauth/granola?code=abc&state=good&state=good HTTP/1.1\r\n\r\n"] {
                try expect(DirectMCPCallback.parse(request, path: "/oauth/granola", state: "good", issuer: "https://auth.example.com") == nil, "unrelated callback not consumed")
            }
            let denied = DirectMCPCallback.parse("GET /oauth/granola?error=access_denied&state=good HTTP/1.1\r\n\r\n", path: "/oauth/granola", state: "good", issuer: "https://auth.example.com")
            try expect(denied != nil, "valid denied consent is consumed")
            do {
                try DirectMCPProbe.validateAccountResult(["isError": true, "content": [["type": "text", "text": "Unauthorized: user has not created a Granola account yet."]]])
                throw Failure("missing vendor account accepted")
            } catch DirectMCPError.accountSetupRequired { passed += 1 }
            func notionIdentity(user: String, workspace: String) throws -> DirectMCPIdentity.Identity? {
                DirectMCPIdentity.parse(try DirectMCPHTTP.json(["structuredContent": ["self": [
                    "user": ["id": user, "email": "synthetic@example.test"],
                    "workspace": ["id": workspace, "name": "Synthetic workspace"]]]]))
            }
            let nativeIdentity = try notionIdentity(user: "user-one", workspace: "workspace-one")
            try expect(nativeIdentity?.label == "synthetic@example.test · Synthetic workspace", "Notion native account identity")
            try expect(try nativeIdentity?.fingerprint != notionIdentity(user: "user-two", workspace: "workspace-one")?.fingerprint, "Notion user switch changes identity")
            try expect(try nativeIdentity?.fingerprint != notionIdentity(user: "user-one", workspace: "workspace-two")?.fingerprint, "Notion workspace switch changes identity")
            let listener = try DirectMCPCallback(state: "good", issuer: URL(string: "https://auth.example.com")!, providerSlug: "granola")
            let callbackURL = try await listener.start()
            defer { listener.cancel() }
            let badURL = URL(string: callbackURL.absoluteString + "?code=wrong&state=wrong")!
            let (_, badResponse) = try await URLSession.shared.data(from: badURL)
            try expect((badResponse as? HTTPURLResponse)?.statusCode == 400, "listener rejects wrong state without closing")
            let responseTask = Task { try await listener.response() }
            let (_, goodResponse) = try await URLSession.shared.data(from: URL(string: callbackURL.absoluteString + "?code=verified&state=good")!)
            try expect((goodResponse as? HTTPURLResponse)?.statusCode == 200, "listener accepts matching callback")
            let code = try await responseTask.value
            try expect(code == "verified", "listener completes transaction once")
            let id = UUID(), generation = UUID()
            let old = DirectMCPGrant(connectionID: id, generation: generation, providerSlug: "granola",
                issuer: URL(string: "https://mcp-auth.granola.ai")!, resource: DirectMCPProvider.granola.endpoint,
                tokenEndpoint: URL(string: "https://mcp-auth.granola.ai/oauth2/token")!, revocationEndpoint: nil,
                clientID: "synthetic-client", clientSecret: nil, authenticationMethod: "none",
                accessToken: "synthetic-old", refreshToken: "synthetic-refresh", expiresAt: Date(), issuedAt: Date(), scopes: ["mcp"])
            let response = DirectMCPHTTP.Response(status: 200, headers: [:], body: Data(#"{"access_token":"synthetic-new","token_type":"Bearer","expires_in":3600}"#.utf8))
            let replaced = try DirectMCPAuth.replacingTokens(old, response: response)
            try expect(replaced.refreshToken == old.refreshToken, "refresh token preserved when omitted")
            try expect(replaced.expiresAt != nil, "expiry recorded")
            try rejects("invalid token type") { _ = try DirectMCPAuth.replacingTokens(old, response: .init(status: 200, headers: [:], body: Data(#"{"access_token":"x","token_type":"mac"}"#.utf8))) }
            try rejects("boolean expiry") { _ = try DirectMCPAuth.replacingTokens(old, response: .init(status: 200, headers: [:], body: Data(#"{"access_token":"x","token_type":"bearer","expires_in":true}"#.utf8))) }
            try rejects("invalid grant is terminal") { _ = try DirectMCPAuth.replacingTokens(old, response: .init(status: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))) }
            do {
                _ = try DirectMCPAuth.replacingTokens(old, response: .init(status: 400, headers: [:], body: Data(#"{"error":"invalid_client"}"#.utf8)))
                throw Failure("expired registration accepted")
            } catch DirectMCPError.registrationExpired { passed += 1 }
            let definitions: [(String, DirectMCPTool.Category)] = [("read_item", .read), ("create_item", .write), ("delete_item", .destructive)]
            var connection = DirectMCPConnection(id: id, providerSlug: "granola", label: "Synthetic", generation: generation, state: .ready)
            connection.tools = try definitions.map { name, _ in .init(name: name, description: name,
                definition: try DirectMCPHTTP.json(["name": name, "description": name, "inputSchema": ["type": "object"]])) }
            connection.policy = Dictionary(uniqueKeysWithValues: definitions)
            connection.policyFingerprint = DirectMCPTool.fingerprint(connection.tools)
            try expect(connection.usable, "complete captured policy")
            try expect(connection.actionNames == ["create_item", "read_item"], "destructive excluded")
            var blocked = connection
            blocked.policy = Dictionary(uniqueKeysWithValues: definitions.map { ($0.0, .destructive) })
            try expect(!blocked.usable, "a wholly denied inventory is not task-usable")
            var drifted = connection
            drifted.tools.append(.init(name: "surprise_write", description: "new", definition: Data("new".utf8)))
            try expect(!drifted.policyValid && drifted.actionNames.isEmpty, "inventory drift fails closed")
            let attachment = DirectMCPRuntime.Attachment(connection: connection, allowed: ["read_item"], deadline: Date().addingTimeInterval(300))
            let receipt = String(decoding: try DirectMCPHTTP.json(["type": "item.completed", "item": [
                "type": "mcp_tool_call", "server": connection.serverName, "tool": "read_item", "status": "completed",
                "result": ["content": [["type": "text", "text": "Synthetic result"]]]]]), as: UTF8.self)
            try expect(DirectMCPRuntime.hasSuccessfulCall(raw: receipt, backend: .chatgpt, attachment: attachment), "confirmed direct tool result")
            try expect(!DirectMCPRuntime.hasSuccessfulCall(raw: "STATUS: DONE", backend: .chatgpt, attachment: attachment), "model claim is not a tool receipt")
            let otherServer = receipt.replacingOccurrences(of: connection.serverName, with: "another_server")
            try expect(!DirectMCPRuntime.hasSuccessfulCall(raw: otherServer, backend: .chatgpt, attachment: attachment), "other server cannot confirm direct action")
            var inv = CodexCLI.Invocation(prompt: "synthetic")
            inv.mcpReadConnectors = [connection.slug]
            inv.webSearch = false
            inv.connectorOnlyRead = true
            let codex = try ModelBackend.$runOverride.withValue(.chatgpt) {
                try DirectMCPRuntime.$current.withValue([attachment]) {
                    try CodexCLI.arguments(for: inv, modelID: "synthetic", effortArg: "low", schemaFile: nil)
                }
            }
            try expect(codex.contains("--ignore-user-config"), "direct read is hermetic")
            try expect(codex.contains("mcp_servers.\(connection.serverName).enabled_tools=[\"read_item\"]"), "Codex explicit read surface")
            let custom = try ModelBackend.$runOverride.withValue(.custom) {
                try DirectMCPRuntime.$current.withValue([attachment]) {
                    try CodexCLI.arguments(for: inv, modelID: "fixture", effortArg: "low", schemaFile: nil)
                }
            }
            try expect(custom.contains("features.apps=false") && custom.contains("mcp_servers.\(connection.serverName).enabled_tools=[\"read_item\"]"), "BYOM receives direct tools without hosted apps")
            try expect(!codex.joined().contains("synthetic-refresh") && !codex.joined().contains("synthetic-old"), "no credential in argv")
            let claude = try ModelBackend.$runOverride.withValue(.claude) {
                try DirectMCPRuntime.$current.withValue([attachment]) { try ClaudeCLI.arguments(for: inv, modelID: "haiku", effortArg: "low") }
            }
            try expect(claude.contains("--strict-mcp-config"), "Claude direct-only wall")
            let allowIndex = claude.firstIndex(of: "--allowedTools")!
            let claudeAllows = Set(claude[allowIndex + 1].split(separator: ",").map(String.init))
            try expect(claudeAllows.contains(connection.toolPrefix + "read_item"), "Claude scoped read allow")
            try expect(claudeAllows.isSubset(of: [connection.toolPrefix + "read_item", "WaitForMcpServers"]), "direct read adds no unrelated allowed tool")
            let bypass = try DirectMCPRuntime.claudeSettings([attachment], hostedURLs: [], guardBypass: true)
            try expect(bypass.contains("PermissionRequest") && bypass.contains(connection.toolPrefix + "*"), "Claude bypass guard configured")
            try expect(!DirectMCPRuntime.quoted("https://example.com/a").contains(#"\/"#), "TOML strings do not contain JSON-only slash escapes")
            try rejects("unprepared direct request refused") { _ = try CodexCLI.arguments(for: inv, modelID: "synthetic", effortArg: "low", schemaFile: nil) }
            let lease = try JSONDecoder().decode(DirectMCPRuntime.Lease.self, from: Data(base64Encoded: attachment.payload)!)
            try expect(lease.connectionID == id && lease.allowed == ["read_item"], "credential-free helper lease")
            // Real Keychain replacement, isolated to a random synthetic connection ID.
            try DirectMCPStore.saveGrant(old)
            defer { try? DirectMCPStore.deleteGrant(id) }
            try DirectMCPStore.saveGrant(replaced)
            let stored = try DirectMCPStore.readGrant(id)
            try expect(stored.accessToken == "synthetic-new" && stored.refreshToken == "synthetic-refresh", "Keychain atomic replacement")
            try expect(try DirectMCPStore.grantIDs().contains(id), "orphan-safe Keychain enumeration")
            try DirectMCPStore.save(connection)
            defer { DirectMCPStore.removeIndex(id: id) }
            let target = connection.taskTarget
            try expect(DirectMCPStore.connection(target)?.id == id, "task target resolves exact generation")
            var relinked = connection
            relinked.generation = UUID()
            try DirectMCPStore.save(relinked)
            try expect(ConnectorRegistry.server(for: target) == nil, "relinked account rejects old card target")
            do {
                _ = try await DirectMCPRuntime.execute([attachment]) { 1 }
                throw Failure("stale task executed")
            } catch DirectMCPError.connectionChanged { passed += 1 }
            let routes = ModelBackend.$runOverride.withValue(.custom) { CommandRouter.routableServices() }
            try expect(!routes.contains(where: { ["gmail", "google-calendar"].contains($0.slug) }), "BYOM cannot route to hosted chips")
            let identityData = try DirectMCPHTTP.json(["structuredContent": ["email": "person@example.invalid", "workspace": ["id": "one", "name": "Synthetic"]]])
            try expect(DirectMCPIdentity.parse(identityData)?.fingerprint.count == 64, "native account fingerprint")
            try expect(DirectMCPIdentity.parse(try DirectMCPHTTP.json(["structuredContent": ["email": "person@example.invalid"]])) == nil, "missing workspace is not inferred")
            let corruptID = UUID()
            let corrupt: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ai.sentient-os.app.direct-mcp.v1", kSecAttrAccount as String: corruptID.uuidString,
                kSecValueData as String: Data("invalid synthetic record".utf8)]
            guard SecItemAdd(corrupt as CFDictionary, nil) == errSecSuccess else { throw Failure("corrupt-record fixture") }
            defer { try? DirectMCPStore.deleteGrant(corruptID) }
            _ = try await DirectMCPAuth.revokeAndDelete(corruptID)
            try expect(try DirectMCPStore.optionalGrant(corruptID) == nil, "corrupt saved record can be removed")
            Log("DIRECT MCP CHECK: PASS (\(passed) assertions)")
        } catch {
            Log("DIRECT MCP CHECK: FAIL after \(passed) assertions (\(ErrorLabel(error)))")
            if let failure = error as? Failure { Log("DIRECT MCP CHECK: \(failure.name)") }
            if case DirectMCPError.keychain(let status) = error { Log("DIRECT MCP CHECK: Keychain status=\(status)") }
            exit(1)
        }
    }

    static func authorize() async {
        let env = ProcessInfo.processInfo.environment
        guard let provider = DirectMCPProvider.find(env["LAB_SLUG"] ?? "granola") else { Log("DIRECT CONNECT: unknown provider"); exit(1) }
        do {
            let replacing = env["LAB_DIRECT_ID"].flatMap(UUID.init(uuidString:))
                ?? DirectMCPStore.connections().first(where: { $0.providerSlug == provider.slug && $0.state == .verifying })?.id
            let id = try await DirectMCPConnections.shared.connect(provider: provider, label: env["LAB_LABEL"] ?? "Personal", replacing: replacing)
            guard let connection = DirectMCPStore.connection(id: id) else { exit(1) }
            Log("DIRECT CONNECT: PASS connection=\(connection.slug) tools=\(connection.tools.count)")
            if let output = env["LAB_DIRECT_OUTPUT"] {
                try JSONEncoder().encode(connection).write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        } catch {
            Log("DIRECT CONNECT: FAIL \(ErrorLabel(error))")
            if let error = error as? DirectMCPError { Log(error.errorDescription ?? "") }
            exit(1)
        }
    }
    struct Failure: Error { let name: String; init(_ name: String) { self.name = name } }

    static func exportFixture() async {
        do {
            guard let provider = DirectMCPProvider.find("fixture"),
                  let output = ProcessInfo.processInfo.environment["LAB_DIRECT_OUTPUT"] else { throw Failure("fixture setup") }
            let id = UUID(), generation = UUID()
            let definitions: [(String, DirectMCPTool.Category)] = [("read_item", .read), ("create_item", .write), ("delete_item", .destructive)]
            var connection = DirectMCPConnection(id: id, providerSlug: "fixture", label: "Synthetic", generation: generation, state: .ready)
            connection.tools = try definitions.map { name, _ in .init(name: name, description: name,
                definition: try DirectMCPHTTP.json(["name": name, "description": name, "inputSchema": ["type": "object"]])) }
            connection.policy = Dictionary(uniqueKeysWithValues: definitions)
            connection.policyFingerprint = DirectMCPTool.fingerprint(connection.tools)
            let grant = DirectMCPGrant(connectionID: id, generation: generation, providerSlug: "fixture", issuer: provider.endpoint.deletingLastPathComponent(),
                resource: provider.endpoint, tokenEndpoint: provider.endpoint.deletingLastPathComponent().appending(path: "token"), revocationEndpoint: nil,
                clientID: "synthetic-client", clientSecret: nil, authenticationMethod: "none", accessToken: "synthetic-access-0",
                refreshToken: "synthetic-refresh-0", expiresAt: Date().addingTimeInterval(300), issuedAt: Date(), scopes: ["mcp"])
            try DirectMCPStore.saveGrant(grant)
            var payload: [String: Any] = ["connection_id": id.uuidString, "server_name": connection.serverName,
                                         "app": Bundle.main.executableURL!.path]
            for mode in ["read", "action"] {
                let attachment = DirectMCPRuntime.Attachment(connection: connection,
                    allowed: mode == "read" ? ["read_item"] : connection.actionNames, deadline: Date().addingTimeInterval(3600))
                var inv = CodexCLI.Invocation(prompt: "Synthetic fixture operation")
                inv.webSearch = false
                if mode == "read" { inv.mcpReadConnectors = [connection.slug]; inv.connectorOnlyRead = true }
                else { inv.mcpActionServer = connection.slug }
                let codex = try ModelBackend.$runOverride.withValue(.chatgpt) {
                    try DirectMCPRuntime.$current.withValue([attachment]) { try CodexCLI.arguments(for: inv, modelID: "fixture", effortArg: "low", schemaFile: nil) }
                }
                let claude = try ModelBackend.$runOverride.withValue(.claude) {
                    try DirectMCPRuntime.$current.withValue([attachment]) { try ClaudeCLI.arguments(for: inv, modelID: "haiku", effortArg: "low") }
                }
                payload["codex_" + mode] = codex
                payload["claude_" + mode] = claude
                if mode == "action" {
                    payload["helper"] = attachment.helperCommand; payload["lease"] = attachment.payload
                    payload["claude_bypass_settings"] = try DirectMCPRuntime.claudeSettings([attachment], hostedURLs: [], guardBypass: true)
                }
            }
            // Two accounts can expose identical bare tool names. Exercise the real CLI
            // namespaces and separate credential helpers in one read-only invocation.
            let summary = MCPSource.modelInvocation(prompt: "Synthetic evidence", schema: MCPSource.readSchema, claudeModel: nil)
            payload["codex_summary"] = try ModelBackend.$runOverride.withValue(.chatgpt) {
                try CodexCLI.arguments(for: summary, modelID: "fixture", effortArg: "low", schemaFile: nil)
            }
            payload["claude_summary"] = try ModelBackend.$runOverride.withValue(.claude) {
                try ClaudeCLI.arguments(for: summary, modelID: "haiku", effortArg: "low")
            }
            let secondID = UUID(), secondGeneration = UUID()
            var second = DirectMCPConnection(id: secondID, providerSlug: "fixture", label: "Synthetic second",
                generation: secondGeneration, state: .ready)
            second.tools = connection.tools; second.policy = connection.policy
            second.policyFingerprint = connection.policyFingerprint
            let secondGrant = DirectMCPGrant(connectionID: secondID, generation: secondGeneration, providerSlug: "fixture",
                issuer: grant.issuer, resource: grant.resource, tokenEndpoint: grant.tokenEndpoint, revocationEndpoint: nil,
                clientID: "synthetic-second-client", clientSecret: nil, authenticationMethod: "none",
                accessToken: "synthetic-second-access-0", refreshToken: "synthetic-second-refresh-0",
                expiresAt: Date().addingTimeInterval(300), issuedAt: Date(), scopes: ["mcp"])
            try DirectMCPStore.saveGrant(secondGrant)
            let pair = [connection, second].map { DirectMCPRuntime.Attachment(connection: $0, allowed: ["read_item"], deadline: Date().addingTimeInterval(3600)) }
            var multiple = CodexCLI.Invocation(prompt: "Read both synthetic accounts")
            multiple.webSearch = false; multiple.connectorOnlyRead = true
            multiple.mcpReadConnectors = pair.map { $0.connection.slug }
            payload["codex_multiple"] = try ModelBackend.$runOverride.withValue(.chatgpt) {
                try DirectMCPRuntime.$current.withValue(pair) { try CodexCLI.arguments(for: multiple, modelID: "fixture", effortArg: "low", schemaFile: nil) }
            }
            payload["claude_multiple"] = try ModelBackend.$runOverride.withValue(.claude) {
                try DirectMCPRuntime.$current.withValue(pair) { try ClaudeCLI.arguments(for: multiple, modelID: "haiku", effortArg: "low") }
            }
            payload["second_connection_id"] = secondID.uuidString
            payload["second_server_name"] = second.serverName
            try DirectMCPHTTP.json(payload).write(to: URL(fileURLWithPath: output), options: .atomic)
            Log("DIRECT FIXTURE: exported synthetic engine recipes")
        } catch { Log("DIRECT FIXTURE: FAIL \(ErrorLabel(error))"); exit(1) }
    }

    static func cleanupFixture() {
        do {
            guard let value = ProcessInfo.processInfo.environment["LAB_DIRECT_ID"], let id = UUID(uuidString: value),
                  try DirectMCPStore.readGrant(id).providerSlug == "fixture" else { throw Failure("fixture cleanup refused") }
            try DirectMCPStore.deleteGrant(id)
            Log("DIRECT FIXTURE: removed synthetic Keychain item")
        } catch { Log("DIRECT FIXTURE: cleanup failed \(ErrorLabel(error))"); exit(1) }
    }

    static func protocolFixture() async {
        let id = UUID()
        defer { try? DirectMCPStore.deleteGrant(id); DirectMCPStore.removeIndex(id: id) }
        do {
            guard let provider = DirectMCPProvider.find("fixture") else { throw Failure("fixture setup") }
            let phases = OSAllocatedUnfairLock(initialState: [DirectMCPConnectPhase]())
            let report: @Sendable (DirectMCPConnectPhase) async -> Void = { phase in
                phases.withLock { $0.append(phase) }
                // A classification regression stops before any real model can be called.
                if phase == .checkingTools { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let browser: @Sendable (URL) async -> Bool = { url in
                // A local synthetic authorization page redirects to the real native callback.
                guard url.host == "127.0.0.1" else { return false }
                return (try? await URLSession.shared.data(from: url)) != nil
            }
            _ = try await DirectMCPConnections.shared.connect(provider: provider, label: "Synthetic", replacing: id,
                onProgress: report, openBrowser: browser)
            guard let connection = DirectMCPStore.connection(id: id), connection.connected, !connection.usable,
                  connection.tools.isEmpty, connection.detected.healthy,
                  phases.withLock({ $0 }) == [.openingBrowser, .waitingForBrowser, .verifyingAccount],
                  ConnectorRegistry.detectedForCurrentBackend().contains(where: { $0.id == connection.detected.id }),
                  CommandRouter.routableServices().contains(where: { $0.slug == connection.taskTarget }) else {
                throw Failure("new login was not connected and discoverable without a tool policy")
            }
            let restored = try JSONDecoder().decode(DirectMCPConnection.self, from: JSONEncoder().encode(connection))
            guard restored.state == .connected, restored.connected, !restored.usable else { throw Failure("connected state persistence") }
            let notion = DirectMCPConnection(id: UUID(), providerSlug: "notion", label: "Synthetic", generation: UUID(), state: .connected)
            guard notion.kbEligible, !notion.kbPolicyReady, notion.readNames.isEmpty, notion.actionNames.isEmpty else {
                throw Failure("KB opt-in granted unchecked tool access")
            }
            let firstUse = Task { try await DirectMCPConnections.verify(connection, onProgress: report) }
            do { _ = try await firstUse.value; throw Failure("first use skipped missing classification") }
            catch is CancellationError { }
            guard phases.withLock({ $0.last }) == .checkingTools,
                  DirectMCPStore.connection(id: id)?.usable == false else { throw Failure("unclassified tools became usable") }
            Log("DIRECT PROTOCOL: login skips classification; first use requires it")
            let grant = try DirectMCPStore.readGrant(id)
            guard grant.accessToken.hasPrefix("synthetic-access-"), grant.refreshToken != nil else { throw Failure("exchange") }
            let tools = try await DirectMCPProbe.tools(connection: connection)
            guard tools.count == 4 else { throw Failure("native MCP inventory") }
            let fresh = try await DirectMCPAuth.accessToken(id: id, generation: grant.generation, refresh: true)
            guard fresh != grant.accessToken else { throw Failure("native refresh") }
            let session = try await DirectMCPSession.open(connection)
            var expiring = try DirectMCPStore.readGrant(id)
            guard expiring.providerSlug == "fixture" else { throw Failure("expiry fixture scope") }
            expiring.expiresAt = Date().addingTimeInterval(-1)
            try DirectMCPStore.saveGrant(expiring)
            let renewedInventory = try await session.request(method: "tools/list", parameters: [:], id: 2)
            await session.close()
            guard (renewedInventory["tools"] as? [Any])?.count == 4,
                  try DirectMCPStore.readGrant(id).accessToken != expiring.accessToken else { throw Failure("native session renewal") }
            Log("DIRECT PROTOCOL: native read renewed expired synthetic grant")
            var connected = connection
            connected.tools = tools
            connected.policy = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.name == "read_item" ? DirectMCPTool.Category.read : .destructive) })
            connected.policyFingerprint = DirectMCPTool.fingerprint(tools)
            connected.state = .ready
            try DirectMCPStore.save(connected)
            do {
                _ = try await DirectMCPConnections.shared.connect(provider: provider, label: "Synthetic", replacing: id, openBrowser: { _ in false })
                throw Failure("failed browser unexpectedly connected")
            } catch DirectMCPError.network { }
            guard DirectMCPStore.connection(id: id)?.generation == grant.generation,
                  try !DirectMCPStore.readGrant(id).revoked else { throw Failure("failed reconnect did not restore existing grant") }
            let opened = OSAllocatedUnfairLock(initialState: false)
            let pending = Task {
                try await DirectMCPConnections.shared.connect(provider: provider, label: "Synthetic", replacing: id, openBrowser: { _ in
                    opened.withLock { $0 = true }; return true
                })
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !opened.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            pending.cancel()
            do { _ = try await pending.value; throw Failure("cancelled reconnect completed") }
            catch is CancellationError { }
            guard DirectMCPStore.connection(id: id)?.generation == grant.generation,
                  try !DirectMCPStore.readGrant(id).revoked else { throw Failure("cancelled reconnect did not restore existing grant") }
            phases.withLock { $0 = [] }
            _ = try await DirectMCPConnections.shared.connect(provider: provider, label: "Synthetic", replacing: id,
                onProgress: report, openBrowser: browser)
            guard let reconnected = DirectMCPStore.connection(id: id), reconnected.connected, !reconnected.usable,
                  reconnected.generation != grant.generation, reconnected.policy == connected.policy,
                  phases.withLock({ $0 }) == [.openingBrowser, .waitingForBrowser, .verifyingAccount] else {
                throw Failure("unchanged reconnect did not reuse policy with ordered progress")
            }
            let verified = try await DirectMCPConnections.verify(reconnected, onProgress: report)
            guard verified.usable else { throw Failure("cached first-use policy was not prepared") }
            let attachments = try await DirectMCPRuntime.prepare(slugs: [verified.taskTarget], mode: .action, timeout: 30)
            guard attachments.count == 1, attachments[0].allowed == ["read_item"] else {
                throw Failure("prepared task did not enforce the cached allowed tools")
            }
            Log("DIRECT PROTOCOL: first use reuses unchanged policy and prepares only permitted tools")

            for invalidateRevision in [false, true] {
                guard var cached = DirectMCPStore.connection(id: id) else { throw Failure("missing reconnect fixture") }
                if invalidateRevision {
                    cached.policyRevision = DirectMCPConnection.currentPolicyRevision - 1
                } else {
                    let tool = cached.tools[0]
                    var definition = try JSONSerialization.jsonObject(with: tool.definition) as! [String: Any]
                    definition["description"] = "A different captured definition"
                    cached.tools[0] = .init(name: tool.name, description: "A different captured definition",
                                            definition: try DirectMCPHTTP.json(definition))
                    cached.policyFingerprint = DirectMCPTool.fingerprint(cached.tools)
                }
                try DirectMCPStore.save(cached)
                phases.withLock { $0 = [] }
                _ = try await DirectMCPConnections.shared.connect(provider: provider, label: "Synthetic", replacing: id,
                    onProgress: report, openBrowser: browser)
                guard let deferred = DirectMCPStore.connection(id: id), deferred.connected, !deferred.usable,
                      !phases.withLock({ $0.contains(.checkingTools) }) else { throw Failure("reconnect classified tools eagerly") }
                let attempt = Task {
                    try await DirectMCPConnections.verify(deferred, onProgress: report)
                }
                do { _ = try await attempt.value; throw Failure("stale policy skipped classification") }
                catch is CancellationError { }
                guard phases.withLock({ $0.last }) == .checkingTools,
                      DirectMCPStore.connection(id: id)?.usable == false else {
                    throw Failure("stale policy became usable before classification")
                }
            }
            Log("DIRECT PROTOCOL: changed definitions and policy revisions require classification")
            _ = try await DirectMCPConnections.shared.disconnect(id)
            guard DirectMCPStore.connection(id: id) == nil else { throw Failure("disconnect index survived") }
            do { _ = try await DirectMCPProbe.tools(connection: connection); throw Failure("disconnected probe continued") }
            catch DirectMCPError.connectionChanged { }
            do { _ = try DirectMCPStore.readGrant(id); throw Failure("deleted record readable") }
            catch DirectMCPError.reconnectRequired { }
            Log("DIRECT PROTOCOL: PASS")
        } catch { Log("DIRECT PROTOCOL: failed \(ErrorLabel(error))"); exit(1) }
    }

    static func inspectConnection() async {
        guard let connection = selectedConnection() else { exit(1) }
        do {
            let snapshot = try await DirectMCPProbe.capture(connection: connection, includeAccount: true)
            func shape(_ value: Any) -> Any {
                if let object = value as? [String: Any] { return object.mapValues(shape) }
                if let list = value as? [Any] { return list.map(shape) }
                if let text = value as? String, let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) { return shape(object) }
                return String(describing: type(of: value))
            }
            if let data = snapshot.account {
                let object = try JSONSerialization.jsonObject(with: data)
                Log("DIRECT INSPECT: \(String(decoding: try DirectMCPHTTP.json(shape(object)), as: UTF8.self))")
                // Capability statuses only; do not print the connected user/workspace fields.
                if connection.providerSlug == "notion", let result = object as? [String: Any] {
                    for block in result["content"] as? [[String: Any]] ?? [] {
                        if let text = block["text"] as? String, let bytes = text.data(using: .utf8),
                           let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                           let account = value["self"] as? [String: Any],
                           let access = account["current_tool_access"] as? [String: Any] {
                            let statuses = access.mapValues { ($0 as? [String: Any])?["status"] as? String ?? "unknown" }
                            Log("DIRECT CAPABILITIES: \(String(decoding: try DirectMCPHTTP.json(statuses), as: UTF8.self))")
                        }
                    }
                }
            }
        } catch { Log("DIRECT INSPECT: failed \(ErrorLabel(error))"); exit(1) }
    }

    static func readConnection() async {
        guard let connection = selectedConnection() else { exit(1) }
        do {
            let tool: String, arguments: String
            switch connection.providerSlug {
            case "granola": tool = "list_meetings"; arguments = "time_range this_week"
            case "notion": tool = "notion-list-recent-pages"; arguments = "limit 1"
            default: throw Failure("no reviewed live test")
            }
            var inv = CodexCLI.Invocation(prompt: "Call \(tool) once with \(arguments). Do not fetch content, repeat returned data, or call any other tool. Reply with exactly READ_OK if the tool succeeded, otherwise READ_FAILED.")
            inv.feature = "mcp-read"; inv.model = .gpt56luna; inv.effort = .low; inv.timeout = 120
            inv.webSearch = false; inv.connectorOnlyRead = true; inv.mcpReadConnectors = [connection.slug]
            inv.mcpReadToolNames = [tool]
            let envelope = try await FrontierRun.run(inv)
            guard envelope.result.trimmingCharacters(in: .whitespacesAndNewlines) == "READ_OK",
                  MCPSource.hasDirectReadEvidence(raw: envelope.raw, connection: connection, backend: ModelBackend.current, requiredNames: [tool]) else {
                throw Failure("real read lacks successful tool evidence")
            }
            Log("DIRECT READ: PASS provider=\(connection.providerSlug) backend=\(ModelBackend.current.rawValue)")
        } catch { Log("DIRECT READ: failed \(ErrorLabel(error))"); exit(1) }
    }

    static func notionDiscovery() async {
        guard let connection = selectedConnection(), connection.providerSlug == "notion" else { exit(1) }
        do {
            let session = try await DirectMCPSession.open(connection)
            defer { Task { await session.close() } }
            let format = ISO8601DateFormatter(); format.formatOptions = [.withFullDate]
            let start = format.string(from: Date().addingTimeInterval(-30 * 86_400))
            let end = format.string(from: Date().addingTimeInterval(86_400))
            let output = try ConnectorReadAudit.outputDirectory()
            let queries: [(String, [String: Any], String)] = [
                ("notion-search", ["query": "", "page_size": 5, "max_highlight_length": 0,
                    "filters": ["created_date_range": ["start_date": start, "end_date": end]]], "created"),
                ("notion-list-recent-pages", ["limit": 5], "recent")]
            for (offset, query) in queries.enumerated() {
                let result = try await session.call(query.0, arguments: query.1, id: 2 + offset, limit: 150_000)
                try DirectMCPHTTP.json(result).write(to: output.appending(path: query.2 + ".json"), options: .atomic)
                Log("NOTION DISCOVERY: \(query.2) saved privately, error=\(result["isError"] as? Bool == true)")
                if query.2 == "recent", let block = (result["content"] as? [[String: Any]])?.first,
                   let text = block["text"] as? String, let data = text.data(using: .utf8),
                   let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let first = (object["results"] as? [[String: Any]])?.first,
                   let url = first["url"] as? String {
                    let page = try await session.call("notion-fetch", arguments: ["id": url, "include_transcript": false,
                        "include_discussions": false], id: 10, limit: 400_000)
                    try DirectMCPHTTP.json(page).write(to: output.appending(path: "page-shape.json"), options: .atomic)
                    Log("NOTION DISCOVERY: one page fetched, error=\(page["isError"] as? Bool == true)")
                }
            }
        } catch { Log("NOTION DISCOVERY: failed \(ErrorLabel(error))"); exit(1) }
    }

    static func refreshConnection() async {
        guard let connection = selectedConnection() else { exit(1) }
        do {
            let previous = try DirectMCPStore.readGrant(connection.id)
            let value = try await DirectMCPAuth.accessToken(id: connection.id, generation: connection.generation, refresh: true)
            let stored = try DirectMCPStore.readGrant(connection.id)
            guard !value.isEmpty, stored.accessToken == value, stored.generation == previous.generation else { throw Failure("renewal persistence") }
            Log("DIRECT RENEW: PASS rotation=\(stored.refreshToken != previous.refreshToken) expiry=\(stored.expiresAt != nil)")
        } catch { Log("DIRECT RENEW: failed \(ErrorLabel(error))"); exit(1) }
    }

    static func discoverProviders() async {
        for provider in DirectMCPProvider.catalog {
            do {
                _ = try await DirectMCPAuth.discover(provider)
                Log("DIRECT DISCOVERY: PASS \(provider.slug)")
            } catch { Log("DIRECT DISCOVERY: failed \(provider.slug) \(ErrorLabel(error))"); exit(1) }
        }
    }

    static func verifyConnection() async {
        guard let connection = selectedConnection(requireUsable: false) else { exit(1) }
        do {
            let verified = try await DirectMCPConnections.verify(connection)
            Log("DIRECT VERIFY: PASS provider=\(verified.providerSlug) identity=\(verified.accountFingerprint != nil) tools=\(verified.tools.count)")
        } catch {
            Log("DIRECT VERIFY: unavailable \(ErrorLabel(error))")
            if case DirectMCPError.accountSetupRequired = error { Log("DIRECT VERIFY: existing Granola account required") }
            exit(1)
        }
    }

    private static func selectedConnection(requireUsable: Bool = true) -> DirectMCPConnection? {
        let env = ProcessInfo.processInfo.environment
        let slug = env["LAB_SLUG"] ?? "granola"
        let id = env["LAB_DIRECT_ID"].flatMap(UUID.init(uuidString:))
        guard env["LAB_DIRECT_ID"] == nil || id != nil else { return nil }
        let matches = DirectMCPStore.connections().filter {
            ($0.providerSlug == slug || $0.slug == slug) && (!requireUsable || $0.usable)
                && (id == nil || $0.id == id)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func renderConnectView() async {
        let slug = ProcessInfo.processInfo.environment["LAB_SLUG"] ?? "granola"
        guard let source = ConnectorSource.catalog(with: []).first(where: { $0.serviceSlug == slug }) else { exit(1) }
        let view = ConnectorConnectSheet(source: source, connectors: .constant([]), onRefresh: {}, onConnect: {})
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            Log("DIRECT RENDER: failed"); exit(1)
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: "/tmp/sentient-direct-connect.png"))
            Log("DIRECT RENDER: PASS")
        } catch { exit(1) }
    }
}
#endif
