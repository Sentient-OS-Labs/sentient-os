// MailAccountProbe.swift
// Reads hosted mail identities through CLI control protocols without starting a model turn.
// Codex uses connection metadata; Claude uses get_me or one Gmail sent-metadata lookup.
// Doc: Documentation - Connected Email Accounts.md

import Foundation
import os

nonisolated enum MailAccountProbe {
    static func discover(engine: MailAccount.Engine, provider: MailAccount.Provider? = nil) async throws -> [MailAccountCandidate] {
        let binary: String?
        let arguments: [String]
        let environment: [String: String]
        switch engine {
        case .chatgpt:
            binary = CodexCLI.locateBinary()
            arguments = ["app-server", "-c", "features.apps=true", "-c", "mcp_servers={}"]
            environment = [:]
        case .claude:
            binary = ClaudeCLI.locateBinary()
            let settings = #"{"allowedMcpServers":[{"serverUrl":"https://gmailmcp.googleapis.com/*"},{"serverUrl":"https://microsoft365.mcp.claude.com/*"}],"disableAllHooks":true}"#
            arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--no-session-persistence", "--setting-sources", "", "--disable-slash-commands",
                         "--tools", "", "--permission-mode", "dontAsk", "--settings", settings]
            environment = ClaudeCLI.baseEnv
        }
        guard let binary else { throw MailAccountError.unavailable }
        let session = MailProbeProcess()
        return try await withTaskCancellationHandler {
            let values: [MailAccountCandidate] = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    defer { session.stop() }
                    do {
                        try session.start(binary: binary, arguments: arguments, extraEnvironment: environment)
                        let values = try engine == .chatgpt ? codex(session) : claude(session, provider: provider)
                        let selected = values.filter { provider == nil || $0.provider == provider }
                        guard !selected.isEmpty else { throw MailAccountError.unavailable }
                        continuation.resume(returning: selected)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return values
        } onCancel: { session.stop() }
    }

    private static func codex(_ session: MailProbeProcess) throws -> [MailAccountCandidate] {
        _ = try session.request(["method": "initialize", "params": [
            "clientInfo": ["name": "sentient_mail_identity", "version": "1.0"]]])
        try session.send(["method": "initialized", "params": [:]])
        var candidates: [String: MailAccountCandidate] = [:]
        var cursor: String?
        for _ in 0..<20 {
            var params: [String: Any] = ["detail": "toolsAndAuthOnly", "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result = try session.request(["method": "mcpServerStatus/list", "params": params])
            for server in result["data"] as? [[String: Any]] ?? [] where server["name"] as? String == "codex_apps" {
                for tool in (server["tools"] as? [String: [String: Any]] ?? [:]).values {
                    guard let candidate = codexCandidate(tool) else { continue }
                    if let prior = candidates[candidate.id], prior.email != candidate.email { throw MailAccountError.invalidResponse }
                    candidates[candidate.id] = candidate
                }
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { return candidates.values.sorted { $0.id < $1.id } }
        }
        throw MailAccountError.invalidResponse
    }

    static func codexCandidate(_ tool: [String: Any]) -> MailAccountCandidate? {
        guard let meta = tool["_meta"] as? [String: Any],
              let connectorID = meta["connector_id"] as? String,
              let link = meta["link_id"] as? String, !link.isEmpty, link.count <= 256,
              let profile = meta["link_owner_profile"] as? [String: Any],
              let rawEmail = profile["email"] as? String,
              let email = MailAccount.normalizedEmail(rawEmail) else { return nil }
        let provider: MailAccount.Provider
        switch connectorID {
        case "connector_2128aebfecb84f64a069897515042a44": provider = .gmail
        case "connector_4aaab2856305417b993eca9a216aaf6e": provider = .outlook
        default: return nil
        }
        return MailAccountCandidate(engine: .chatgpt, provider: provider, connectionKey: link, email: email)
    }

    private static func claude(_ session: MailProbeProcess, provider: MailAccount.Provider?) throws -> [MailAccountCandidate] {
        _ = try session.request(["subtype": "initialize", "hooks": [:]], claude: true)
        var connected: [[String: Any]] = []
        // Connector attachment is asynchronous and can initially report an empty inventory.
        for attempt in 0..<15 {
            let result = try session.request(["subtype": "mcp_status"], claude: true)
            let servers = (result["mcpServers"] as? [[String: Any]] ?? []).filter {
                let url = ($0["config"] as? [String: Any])?["url"] as? String
                return url == "https://gmailmcp.googleapis.com/mcp/v1" || url == "https://microsoft365.mcp.claude.com/mcp"
            }
            connected = servers.filter { $0["status"] as? String == "connected" }
            if !servers.isEmpty && !servers.contains(where: { $0["status"] as? String == "pending" }) { break }
            if attempt < 14 { try session.pause() }
        }
        var values: [MailAccountCandidate] = []
        for server in connected {
            guard let config = server["config"] as? [String: Any],
                  let key = config["id"] as? String, !key.isEmpty, key.count <= 256 else { continue }
            if config["url"] as? String == "https://gmailmcp.googleapis.com/mcp/v1" {
                if provider == .outlook { continue }
                var email: String?
                if let name = server["name"] as? String,
                   (server["tools"] as? [[String: Any]] ?? []).contains(where: { $0["name"] as? String == "search_threads" }) {
                    let normalized = name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
                    // This control channel is trusted: keep the tool and arguments fixed here.
                    // Failure skips this address; never broaden the query or read a message body.
                    if let result = try? session.request(["subtype": "mcp_call",
                        "tool": "mcp__\(normalized)__search_threads", "arguments": GmailSenderMetadata.searchArguments], claude: true) {
                        email = GmailSenderMetadata.email(from: result)
                    }
                }
                values.append(MailAccountCandidate(engine: .claude, provider: .gmail, connectionKey: key,
                                                   email: email, reportedVia: .sentMailMetadata))
            } else {
                if provider == .gmail { continue }
                guard let name = server["name"] as? String,
                      (server["tools"] as? [[String: Any]] ?? []).contains(where: { $0["name"] as? String == "get_me" }) else { continue }
                let normalized = name.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
                let result = try session.request(["subtype": "mcp_call", "tool": "mcp__\(normalized)__get_me", "arguments": [:]], claude: true)
                guard let email = profileEmail(result) else { throw MailAccountError.invalidResponse }
                values.append(MailAccountCandidate(engine: .claude, provider: .outlook, connectionKey: key, email: email))
            }
        }
        return values
    }

    static func profileEmail(_ result: [String: Any]) -> String? {
        guard result["isError"] as? Bool != true else { return nil }
        if let profile = result["structuredContent"] as? [String: Any], let mail = profile["mail"] as? String {
            return MailAccount.normalizedEmail(mail)
        }
        for block in result["content"] as? [[String: Any]] ?? [] {
            guard block["type"] as? String == "text", let text = block["text"] as? String,
                  let data = text.data(using: .utf8),
                  let profile = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = profile["id"] as? String, !id.isEmpty,
                  let mail = profile["mail"] as? String else { continue }
            return MailAccount.normalizedEmail(mail)
        }
        return nil
    }
}

/// A bounded control channel. No model prompts or arbitrary tool calls are accepted.
private nonisolated final class MailProbeProcess: @unchecked Sendable {
    private let condition = NSCondition()
    private let cancellation = OSAllocatedUnfairLock(initialState: false)
    private let process = Process()
    private var runtimeLease: CodexRuntime.FileLock?
    private let input = Pipe(), output = Pipe()
    private var replies: [String: [String: Any]] = [:]
    private var stopped = false
    private var sequence = 0
    private let deadline = Date().addingTimeInterval(60)
    private var directory: URL?

    func start(binary: String, arguments: [String], extraEnvironment: [String: String]) throws {
        condition.lock(); defer { condition.unlock() }
        guard !stopped else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-mail-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        runtimeLease = try CodexRuntime.executionLease(for: binary, cancelled: { self.cancellation.withLock { $0 } })
        if binary == CodexRuntime.executable.path { try CodexRuntime.verifyCLIForLaunch() }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = CodexRuntime.arguments(arguments, binary: binary)
        let env = ProcessInfo.processInfo.environment
        var sanitized = ["HOME": NSHomeDirectory(), "USER": env["USER"] ?? "",
                         "PATH": "\((binary as NSString).deletingLastPathComponent):/usr/bin:/bin:/usr/sbin:/sbin"]
        sanitized.merge(extraEnvironment) { _, new in new }
        process.environment = CodexRuntime.environment(sanitized, binary: binary); process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self, runtimeLease] _ in runtimeLease?.unlock(); self?.didExit() }
        do { try process.run() } catch { runtimeLease?.unlock(); throw error }
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 16 * 1_024 * 1_024 { stop(); break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    condition.lock()
                    if let response = object["response"] as? [String: Any], let id = response["request_id"] as? String {
                        replies[id] = object
                    } else if let id = object["id"] as? Int, object["method"] == nil { replies[String(id)] = object }
                    condition.broadcast(); condition.unlock()
                }
            }
            try? FileManager.default.removeItem(at: directory)
            didExit()
        }
    }

    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ value: [String: Any], claude: Bool = false) throws -> [String: Any] {
        sequence += 1
        let id = String(sequence)
        var message = value
        if claude { message = ["type": "control_request", "request_id": id, "request": value] }
        else { message["id"] = sequence }
        try send(message)
        condition.lock(); defer { condition.unlock() }
        while replies[id] == nil && !stopped && Date() < deadline { condition.wait(until: min(deadline, Date().addingTimeInterval(1))) }
        guard let response = replies.removeValue(forKey: id) else {
            if stopped { throw MailAccountError.unavailable }
            throw MailAccountError.timedOut
        }
        if claude {
            guard let result = response["response"] as? [String: Any], result["subtype"] as? String == "success",
                  let value = result["response"] as? [String: Any] else { throw MailAccountError.invalidResponse }
            return value
        }
        guard response["error"] == nil, let result = response["result"] as? [String: Any] else { throw MailAccountError.invalidResponse }
        return result
    }

    func pause() throws {
        condition.lock(); defer { condition.unlock() }
        if stopped { throw CancellationError() }
        condition.wait(until: Date().addingTimeInterval(1))
    }
    private func didExit() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    func stop() {
        cancellation.withLock { $0 = true }
        condition.lock(); stopped = true; let running = process.isRunning; condition.broadcast(); condition.unlock()
        if running {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try? input.fileHandleForWriting.close()
    }
}
