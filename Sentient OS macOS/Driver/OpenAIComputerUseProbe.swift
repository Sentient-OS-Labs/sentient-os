// Checks the real native service through a short, model-free Codex app-server connection.
// Owns only its temporary profile and probe process; never terminates the shared GUI helper.
// Doc: Driver/Documentation - Native Computer Use.md

import Foundation
import Darwin

nonisolated enum OpenAIComputerUseProbe {
    static func check(_ configuration: OpenAIComputerUse.Configuration) async throws {
        let run = Run(configuration: configuration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in run.start(continuation) }
        } onCancel: { run.cancel() }
    }

    /// All mutable state lives on this queue, including cancellation before process launch.
    private final class Run: @unchecked Sendable {
        let configuration: OpenAIComputerUse.Configuration
        let queue = DispatchQueue(label: "sentient.native-readiness")
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        var profile: URL?
        var continuation: CheckedContinuation<Void, Error>?
        var buffer = Data()
        var outcome: Result<Void, Error>?
        var cancelled = false
        var expectedID = 1
        var receivedBytes = 0

        init(configuration: OpenAIComputerUse.Configuration) { self.configuration = configuration }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !self.cancelled else { self.complete(.failure(CancellationError())); return }
                do {
                    let profile = FileManager.default.temporaryDirectory
                        .appendingPathComponent("sentient-native-check-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                    self.profile = profile
                    // Isolate the frontend from user plugins/config and persisted conversations.
                    // The native client still receives the real Codex home through its MCP env.
                    var environment = self.configuration.clientEnvironment
                    environment["CODEX_HOME"] = profile.path
                    self.process.executableURL = self.configuration.cliURL
                    self.process.currentDirectoryURL = profile
                    self.process.environment = environment
                    let overrides = self.configuration.codexOverrides + [
                        "features.apps=false", "features.plugins=false", "analytics.enabled=false",
                        "cli_auth_credentials_store=\"ephemeral\"",
                        "mcp_servers.sentient_native.startup_timeout_sec=8",
                        "mcp_servers.sentient_native.tool_timeout_sec=8"]
                    self.process.arguments = ["app-server", "--listen", "stdio://"]
                        + overrides.flatMap { ["-c", $0] }
                    self.process.standardInput = self.input
                    self.process.standardOutput = self.output
                    self.process.standardError = FileHandle.nullDevice
                    self.output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        self?.queue.async { [weak self] in self?.receive(data) }
                    }
                    self.process.terminationHandler = { [weak self] _ in
                        self?.queue.async { [weak self] in
                            guard let self else { return }
                            self.complete(self.outcome ?? .failure(OpenAIComputerUse.RuntimeError.backendUnavailable))
                        }
                    }
                    try self.process.run()
                    self.send(["id": 1, "method": "initialize", "params": [
                        "clientInfo": ["name": "sentient_readiness", "version": "1"],
                        "capabilities": ["experimentalApi": true]]])
                    self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                        self?.finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable))
                    }
                } catch { self.complete(.failure(error)) }
            }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }

        private func send(_ message: [String: Any]) {
            guard outcome == nil else { return }
            do {
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch { finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)) }
        }

        private func receive(_ data: Data) {
            guard outcome == nil, continuation != nil else { return }
            guard !data.isEmpty else { finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)); return }
            receivedBytes += data.count
            guard receivedBytes <= 1_048_576 else { finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)); return }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A), outcome == nil {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)); return
                }
                // This read-only probe never accepts an app approval or any other elicitation.
                if message["method"] != nil, let id = message["id"] {
                    send(["id": id, "error": ["code": -32601, "message": "Readiness checks do not grant access"]])
                    finish(.failure(OpenAIComputerUse.RuntimeError.permissionRequired)); return
                }
                guard let id = message["id"] as? Int, id == expectedID else { continue }
                if let error = message["error"] as? [String: Any], error["code"] as? Int == -32601 {
                    finish(.failure(OpenAIComputerUse.RuntimeError.unsupportedCLI)); return
                }
                guard message["error"] == nil, let result = message["result"] as? [String: Any] else {
                    finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)); return
                }
                switch id {
                case 1:
                    expectedID = 2
                    send(["method": "initialized"])
                    send(["id": 2, "method": "thread/start", "params": [
                        "cwd": profile!.path, "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never"]])
                case 2:
                    guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)); return
                    }
                    expectedID = 3
                    send(["id": 3, "method": "mcpServer/tool/call", "params": [
                        "threadId": id, "server": "sentient_native", "tool": "list_apps", "arguments": [:]]])
                case 3:
                    guard result["isError"] as? Bool != true, result["content"] is [[String: Any]] else {
                        finish(.failure(OpenAIComputerUse.RuntimeError.backendUnavailable)); return
                    }
                    // Deliberately discard the app list; readiness is a boolean, not app telemetry.
                    finish(.success(()))
                default: break
                }
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard continuation != nil, outcome == nil else { return }
            outcome = result
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            guard process.isRunning else { complete(result); return }
            // EOF normally ends app-server and its owned MCP clients cleanly. Bound cleanup if
            // a broken child prevents that shutdown, including cancellation during startup.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.continuation != nil, self.process.isRunning else { return }
                self.process.terminate()
            }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.continuation != nil, self.process.isRunning else { return }
                kill(self.process.processIdentifier, SIGKILL)
            }
        }

        private func complete(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            outcome = result
            output.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? input.fileHandleForWriting.close()
            // Let the final reader callback release its handle before ARC closes the pipe.
            // Closing it here could race an already-delivered readability callback.
            if let profile { try? FileManager.default.removeItem(at: profile) }
            continuation.resume(with: result)
        }
    }
}
