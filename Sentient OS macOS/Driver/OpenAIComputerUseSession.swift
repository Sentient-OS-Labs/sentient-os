// Owns one model-free, authenticated native MCP session through the signed Codex app-server.
// The same session serves capture and actions; requests are bounded and STOP closes owned children.
// Doc: Documentation - Native Computer Use.md

import Foundation
import Darwin

nonisolated final class OpenAIComputerUseSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sentient.native-session")
    private let process = Process(), input = Pipe(), output = Pipe(), errorOutput = Pipe()
    private var profile: URL?
    private var buffer = Data()
    private var stderrBuffer = Data()
    private var stderrFailure: NativeComputerUseFailure?
    private var nextID = 0
    private var pending: (id: Int, stage: NativeComputerUseFailure.Stage, continuation: CheckedContinuation<Data, Error>)?
    private var closed = false
    private var terminalError: Error?
    private var launched = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var threadID = ""

    static func open(_ configuration: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession {
        let session = OpenAIComputerUseSession()
        do {
            try await session.launch(configuration)
            _ = try await session.request("initialize", params: ["clientInfo": ["name": "sentient_native_session", "version": "1"],
                "capabilities": ["experimentalApi": true]], stage: .initialize, timeout: 15)
            try await session.notifyInitialized()
            // This session never runs a model or arbitrary commands. The only requests are the
            // catalog and explicit native tools. Seatbelt read-only auto-denies native elicitation.
            let result = try await session.request("thread/start", params: ["cwd": session.profile!.path,
                "ephemeral": true, "sandbox": "danger-full-access", "approvalPolicy": "never"], stage: .thread, timeout: 15)
            guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
                  let thread = object["thread"] as? [String: Any], let id = thread["id"] as? String else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .thread)
            }
            session.threadID = id
            return session
        } catch { await session.close(); throw error }
    }

    func catalog() async throws -> Data {
        try await request("mcpServerStatus/list", params: ["threadId": threadID, "serverName": "sentient_native", "limit": 1], stage: .catalog, timeout: 20)
    }
    /// Only transport liveness, not an interpretation of a tool's success or permissions.
    func isUsable() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: !self.closed && self.terminalError == nil) }
        }
    }
    func call(_ tool: String, arguments: Data, timeout: TimeInterval = 125) async throws -> Data {
        let args = try JSONSerialization.jsonObject(with: arguments)
        return try await request("mcpServer/tool/call", params: ["threadId": threadID, "server": "sentient_native", "tool": tool, "arguments": args],
                                 stage: tool == "get_app_state" ? .appState : .action, timeout: timeout)
    }
    private func launch(_ configuration: OpenAIComputerUse.Configuration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !closed else { throw CancellationError() }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-native-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    profile = directory
                    var environment = configuration.clientEnvironment
                    environment["CODEX_HOME"] = directory.path
                    process.environment = environment
                    process.executableURL = configuration.cliURL
                    process.currentDirectoryURL = directory
                    let overrides = configuration.codexOverrides + ["features.apps=false", "features.plugins=false",
                        "analytics.enabled=false", "cli_auth_credentials_store=\"ephemeral\"",
                        "mcp_servers.sentient_native.startup_timeout_sec=15"]
                    process.arguments = ["app-server", "--listen", "stdio://"] + overrides.flatMap { ["-c", $0] }
                    process.standardInput = input; process.standardOutput = output
                    process.standardError = errorOutput
                    errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        self?.queue.async { [weak self] in self?.receiveStderr(data) }
                    }
                    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        self?.queue.async { [weak self] in self?.receive(data) }
                    }
                    process.terminationHandler = { [weak self] process in
                        let code = Int(process.terminationStatus)
                        self?.queue.async { [weak self] in self?.exited(code) }
                    }
                    try process.run(); launched = true
                    continuation.resume()
                } catch {
                    var failure = NativeComputerUseFailure(kind: .connection, code: nil, detail: .launchFailed, stage: .transport)
                    failure.recordSystemError(error)
                    continuation.resume(throwing: error is CancellationError ? error : failure)
                }
            }
        }
    }
    private func notifyInitialized() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try self.send(["method": "initialized"]); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func request(_ method: String, params: [String: Any], stage: NativeComputerUseFailure.Stage, timeout: TimeInterval) async throws -> Data {
        // Serialize before crossing the queue boundary. Raw payloads live only for this request.
        let parameters = try JSONSerialization.data(withJSONObject: params)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !closed else { continuation.resume(throwing: terminalError ?? CancellationError()); return }
                    guard pending == nil else {
                        continuation.resume(throwing: NativeComputerUseFailure(kind: .connection, code: nil, detail: .concurrentCall, stage: stage)); return
                    }
                    stderrFailure = nil; stderrBuffer.removeAll()
                    nextID += 1
                    let id = nextID
                    pending = (id, stage, continuation)
                    do { try send(["id": id, "method": method, "params": try JSONSerialization.jsonObject(with: parameters)]) }
                    catch { fail(error); return }
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self, self.pending?.id == id else { return }
                        self.fail(NativeComputerUseFailure(kind: .timeout, code: nil, detail: .requestTimedOut, stage: stage))
                    }
                }
            }
        } onCancel: { self.queue.async { self.fail(CancellationError()) } }
    }
    private func send(_ object: [String: Any]) throws {
        guard !closed else { throw CancellationError() }
        do {
            var data = try JSONSerialization.data(withJSONObject: object); data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch { throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .writeFailed, stage: pending?.stage ?? .transport) }
    }
    private func receive(_ data: Data) {
        guard !closed else { return }
        guard !data.isEmpty else {
            fail(NativeComputerUseFailure(kind: .connection, code: nil, detail: .unexpectedEOF, stage: pending?.stage ?? .transport)); return
        }
        buffer.append(data)
        guard buffer.count <= 32 * 1_048_576 else {
            fail(NativeComputerUseFailure(kind: .connection, code: nil, detail: .responseTooLarge, stage: pending?.stage ?? .transport)); return
        }
        while let newline = buffer.firstIndex(of: 0x0A), !closed {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                fail(NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: pending?.stage ?? .transport)); return
            }
            if object["method"] != nil, let id = object["id"] {
                try? send(["id": id, "error": ["code": -32601, "message": "Unexpected request"]])
                fail(NativeComputerUseFailure(kind: .permission, code: nil, detail: .unexpectedRequest, stage: pending?.stage ?? .transport)); return
            }
            guard let id = object["id"] as? Int, let request = pending, id == request.id else { continue }
            pending = nil
            if let error = object["error"], !(error is NSNull) {
                request.continuation.resume(throwing: withStderr(NativeComputerUseFailure.classify(error, stage: request.stage)))
            } else if let result = object["result"], let encoded = try? JSONSerialization.data(withJSONObject: result) {
                request.continuation.resume(returning: encoded)
            } else {
                request.continuation.resume(throwing: NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: request.stage))
            }
        }
    }
    private func receiveStderr(_ data: Data) {
        guard !closed else { return }
        stderrBuffer.append(data.prefix(16384))
        let text = String(decoding: stderrBuffer.suffix(16384), as: UTF8.self)
        let hint = NativeComputerUseFailure.classify(text, stage: .transport)
        if hint.detail != .unspecified || hint.code != nil { stderrFailure = hint }
        if stderrBuffer.count > 16384 { stderrBuffer = Data(stderrBuffer.suffix(4096)) }
    }
    private func withStderr(_ error: Error) -> Error {
        guard var failure = error as? NativeComputerUseFailure, let hint = stderrFailure else { return error }
        // Stderr is a text-derived hint, never a replacement for the actual RPC failure.
        failure.stderrDetail = hint.detail; failure.stderrCode = hint.code
        return failure
    }
    private func fail(_ error: Error) {
        let error = withStderr(error)
        terminalError = terminalError ?? error
        pending?.continuation.resume(throwing: error); pending = nil
        beginClose()
    }
    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { self.closeWaiters.append(continuation); self.beginClose() }
        }
    }
    private func beginClose() {
        guard !closed else {
            if !launched || !process.isRunning { cleanup() }
            return
        }
        closed = true
        pending?.continuation.resume(throwing: CancellationError()); pending = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if !launched || !process.isRunning { cleanup(); return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if let self, self.process.isRunning { self.process.terminate() }
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let self, self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
        }
    }
    private func exited(_ code: Int) {
        if !closed { terminalError = NativeComputerUseFailure(kind: .connection, code: nil, detail: .processExited, stage: pending?.stage ?? .transport, exitCode: code) }
        if let request = pending {
            pending = nil
            request.continuation.resume(throwing: withStderr(NativeComputerUseFailure(kind: .connection, code: nil, detail: .processExited, stage: request.stage, exitCode: code)))
        }
        closed = true; cleanup()
    }
    private func cleanup() {
        output.fileHandleForReading.readabilityHandler = nil; errorOutput.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        try? input.fileHandleForWriting.close()
        buffer.removeAll(); stderrBuffer.removeAll(); stderrFailure = nil
        if let profile { try? FileManager.default.removeItem(at: profile); self.profile = nil }
        let waiters = closeWaiters; closeWaiters.removeAll(); waiters.forEach { $0.resume() }
    }
}
