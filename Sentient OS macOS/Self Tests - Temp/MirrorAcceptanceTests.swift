#if DEBUG
// MirrorAcceptanceTests.swift
// Tests the real mirror client/server with an isolated Keychain service and fictional vault.
// Only the test app may invoke this. No share URL or credential is printed or exported.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import Foundation

enum MirrorAcceptanceTests {
    static func run() async throws {
        guard Bundle.main.bundleIdentifier == "ai.sentientos.acceptance" else { throw FullAcceptanceTests.Failure(message: "test app required") }
        let root = VaultGenerator.vaultRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = "Synthetic Cedar Mirror Acceptance"
        try "# \(marker)\nThis fictional vault exists only for connector verification.\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "Projects"), withIntermediateDirectories: true)
        try "# Cedar Project\nA fictional project.\n".write(to: root.appending(path: "Projects/Cedar.md"), atomically: true, encoding: .utf8)
        let client = MirrorClient.shared
        MirrorClient.destroyKeychainIdentity()
        do {
            let first = try await client.enable()
            try FullAcceptanceTests.require(!MirrorClient.maskedURL(first).contains(first), "mirror display does not expose its complete share URL")
            try await client.push()
            try FullAcceptanceTests.require(MirrorClient.lastPush != nil, "real encrypted mirror upload succeeds")
            var session: String?
            func rpc(_ method: String, params: [String: Any], id: Int?) async throws -> [String: Any] {
                var request = URLRequest(url: URL(string: first)!)
                request.httpMethod = "POST"; request.timeoutInterval = 40
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
                if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
                var body: [String: Any] = ["jsonrpc":"2.0", "method":method, "params":params]
                if let id { body["id"] = id }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw FullAcceptanceTests.Failure(message: "mirror RPC HTTP failure")
                }
                if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = value }
                if id == nil { return [:] }
                let value: [String: Any]?
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { value = object }
                else {
                    value = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasPrefix("data:") }
                        .compactMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(5).utf8)) as? [String: Any] }
                        .first { $0["id"] as? Int == id }
                }
                guard let result = value?["result"] as? [String: Any] else {
                    let code = (value?["error"] as? [String: Any])?["code"] as? Int
                    throw FullAcceptanceTests.Failure(message: "mirror RPC \(method) result missing; keys=\(value?.keys.sorted() ?? []), errorCode=\(code ?? 0), bytes=\(data.count)")
                }
                return result
            }
            _ = try await rpc("initialize", params: ["protocolVersion":"2025-03-26", "capabilities":[:], "clientInfo":["name":"Sentient acceptance", "version":"1"]], id: 1)
            _ = try await rpc("notifications/initialized", params: [:], id: nil)
            let catalog = try await rpc("tools/list", params: [:], id: 2)
            let output = try ConnectorReadAudit.outputDirectory()
            try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted]).write(to: output.appending(path: "mirror-tool-schema.json"))
            let tools = catalog["tools"] as? [[String: Any]] ?? []
            try FullAcceptanceTests.require(Set(tools.compactMap { $0["name"] as? String }) == ["get_structure", "get_files"], "mirror exposes exactly its two read tools")
            let structure = try await rpc("tools/call", params: ["name":"get_structure", "arguments":[:]], id: 3)
            try FullAcceptanceTests.require(String(decoding: try JSONSerialization.data(withJSONObject: structure), as: UTF8.self).contains(marker), "remote structure includes uploaded README")
            guard let schema = tools.first(where: { $0["name"] as? String == "get_files" })?["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: [String: Any]],
                  let parameter = properties.first(where: { ["paths", "paths_json", "file_paths"].contains($0.key) }) else {
                throw FullAcceptanceTests.Failure(message: "get_files schema requires inspection")
            }
            let array = parameter.value["type"] as? String == "array"
                || (parameter.value["anyOf"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "array" }) == true
            let value: Any = array ? ["Projects/Cedar.md"] : "[\"Projects/Cedar.md\"]"
            let files = try await rpc("tools/call", params: ["name":"get_files", "arguments":[parameter.key:value]], id: 4)
            try JSONSerialization.data(withJSONObject: files, options: [.prettyPrinted]).write(to: output.appending(path: "mirror-test-note-response.json"))
            try FullAcceptanceTests.require(String(decoding: try JSONSerialization.data(withJSONObject: files), as: UTF8.self).contains("A fictional project"), "remote get_files decrypts exact uploaded note")
            let stats = try await client.stats()
            try FullAcceptanceTests.require(stats.toolCalls24h >= 2, "mirror records the actual read tool calls")
            await client.disable()
            try FullAcceptanceTests.require(!(await client.isEnabled), "mirror disable persists opt-out")
            try FullAcceptanceTests.require(try await client.enable() == first, "reenabling retains the share identity")
            try await client.push()
            let changed = try await client.regenerateToken()
            try FullAcceptanceTests.require(changed != first, "regeneration creates a new mirror identity")
            _ = try await client.stats()
            try FullAcceptanceTests.require(Keychain.set("acceptance-replacement", "first") && Keychain.set("acceptance-replacement", "second") && Keychain.read("acceptance-replacement") == "second", "Keychain replacement updates existing value")
            Keychain.delete("acceptance-replacement")
            await client.disable()
            MirrorClient.destroyKeychainIdentity()
            try FullAcceptanceTests.require(MirrorClient.lastPush == nil, "test mirror deletion clears its sync stamp")
        } catch {
            await client.disable()
            MirrorClient.destroyKeychainIdentity()
            throw error
        }
    }
}
#endif
