//
// OutlookToolPolicy.swift
// Native primary-mailbox checks, knowledge-read budgets and one send attempt per routed
// task. State contains counters only and is removed when the run finishes.
// Doc: Documentation - Cloud - CodexCLI (the codex exec spine).md
//

import Foundation
import Darwin
import CryptoKit

nonisolated enum OutlookToolPolicy {
    @TaskLocal static var computerRunID: UUID?
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func recipientHash(_ emails: [String]) -> String {
        hash(String(data: try! JSONEncoder().encode(emails.map { $0.lowercased() }.sorted()), encoding: .utf8)!)
    }
    static func rule(backend: ModelBackend, operation: OutlookMailConnector.Operation, runID: UUID,
                     mode: MCPSource.ReadMode? = nil, window: MCPSource.Window? = nil,
                     expectedMessage: String? = nil, expectedRecipients: [String]? = nil,
                     calendar: OutlookCalendarToolPolicy.Context? = nil, includesMail: Bool = true) -> HostedToolPolicy.Rule {
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        var args = [backend.rawValue, operation.rawValue, runID.uuidString, mode?.rawValue ?? "-",
                    window.map { String($0.lower.timeIntervalSince1970) } ?? "-",
                    window.map { String($0.upper.timeIntervalSince1970) } ?? "-", expectedMessage.map(hash) ?? "-",
                    expectedRecipients.map(recipientHash) ?? "-"]
        if let calendar { args += [includesMail ? "1" : "0", calendar.encoded] }
        return .init(matcher: ".*([Oo]utlook|[Mm]icrosoft_365).*",
            command: DirectMCPRuntime.shellQuote(executable) + " --outlook-tool-policy "
                + args.map(DirectMCPRuntime.shellQuote).joined(separator: " ")
                + " || { echo 'Outlook policy could not be verified.' >&2; exit 2; }")
    }
    static func allowed(name: String, input: [String: Any], backend: ModelBackend,
                        operation: OutlookMailConnector.Operation, mode: MCPSource.ReadMode? = nil,
                        window: MCPSource.Window? = nil, expectedHash: String? = nil, expectedRecipientsHash: String? = nil) -> Bool {
        guard let bare = OutlookMailConnector.bareName(name, backend: backend),
              OutlookMailConnector.actionTools(backend, operation: operation).contains(bare),
              OutlookMailSource.absent(input, "mailboxOwnerEmail"),
              OutlookMailSource.absent(input, "mailbox_user_principal_name"),
              OutlookMailSource.absent(input, "attachment_files") else { return false }
        if bare == "read_resource" {
            guard Set(input.keys) == ["uri"], let uri = input["uri"] as? String, OutlookMailSource.mailID(uri) != nil else { return false }
        }
        if ["get_me", "get_granted_scopes", "get_profile"].contains(bare), !input.isEmpty { return false }
        if let id = input["message_id"] as? String,
           id.utf8.count > 1_024 || id.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) == nil { return false }
        if let mode, let window {
            guard operation == .read, OutlookMailConnector.knowledgeTools(backend).contains(bare) else { return false }
            if bare == "list_messages" {
                guard Set(input.keys).isSubset(of: ["filter", "order_by", "top", "skip", "folder_id", "select"]),
                      OutlookMailSource.absent(input, "select"), input["filter"] as? String == OutlookMailSource.codexFilter(window),
                      input["order_by"] as? String == "receivedDateTime desc", OutlookMailSource.absent(input, "folder_id"),
                      let top = input["top"] as? Int, (1...OutlookMailSource.pageSize).contains(top),
                      (input["skip"] as? Int ?? 0) >= 0 else { return false }
            }
            if bare == "outlook_email_search" {
                let bounds = OutlookMailSource.claudeBounds(window)
                guard Set(input.keys).isSubset(of: ["query", "afterDateTime", "beforeDateTime", "limit", "offset", "cursor", "mailboxOwnerEmail"]),
                      input["query"] as? String == "*", input["afterDateTime"] as? String == bounds.after,
                      input["beforeDateTime"] as? String == bounds.before,
                      let limit = input["limit"] as? Int, (1...OutlookMailSource.pageSize).contains(limit),
                      (input["offset"] as? Int ?? 0) >= 0 else { return false }
            }
            guard OutlookMailSource.discoveryCap(mode) > 0 else { return false }
        } else if mode != nil || window != nil { return false }
        if bare == "send_email", input["save_to_sent_items"] as? Bool == false { return false }
        if let expectedRecipientsHash, !OutlookMailConnector.reads(backend).contains(bare) {
            guard let values = input["to"] as? [Any], !values.isEmpty else { return false }
            let emails = values.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["email"] as? String) }
            guard emails.count == values.count, recipientHash(emails) == expectedRecipientsHash,
                  ["cc", "bcc"].allSatisfy({ OutlookMailSource.absent(input, $0) || (input[$0] as? [Any])?.isEmpty == true }) else { return false }
        }
        let bodyTools = ["draft_email", "send_email", "reply_to_email", "forward_email", "create_reply_draft", "create_forward_draft",
                         "outlook_create_draft", "outlook_send_mail", "outlook_create_reply_draft", "outlook_create_reply_all_draft", "outlook_forward_mail"]
        if bodyTools.contains(bare), backend == .claude, !OutlookMailSource.absent(input, "body"), input["bodyType"] as? String != "text" { return false }
        if bodyTools.contains(bare), let expectedHash {
            let body = (input["text_content"] ?? input["body"] ?? input["comment"]) as? String ?? ""
            guard hash(body) == expectedHash else { return false }
        }
        return true
    }
    static func isSend(_ name: String) -> Bool {
        ["send_email", "reply_to_email", "forward_email", "outlook_send_mail", "outlook_send_draft", "outlook_forward_mail"].contains(name)
    }
    private static func marker(_ runID: UUID, kind: String, index: Int) -> URL {
        URL(fileURLWithPath: "/private/tmp/sentient-outlook-\(getuid())-\(runID.uuidString)-\(kind)-\(index)")
    }
    static func claudeSettings(_ base: String, operation: OutlookMailConnector.Operation, runID: UUID,
                               mode: MCPSource.ReadMode? = nil, window: MCPSource.Window? = nil,
                               expectedMessage: String? = nil, expectedRecipients: [String]? = nil,
                               calendar: OutlookCalendarToolPolicy.Context? = nil, includesMail: Bool = true) throws -> String {
        let pre = rule(backend: .claude, operation: operation, runID: runID, mode: mode, window: window,
                       expectedMessage: expectedMessage, expectedRecipients: expectedRecipients, calendar: calendar, includesMail: includesMail)
        let settings = try HostedToolPolicy.claudeSettings(base, adding: pre)
        guard includesMail, operation != .read else { return settings }
        let post = HostedToolPolicy.Rule(matcher: "^mcp__claude_ai_Microsoft_365__outlook_create_(?:reply_(?:all_)?)?draft$", command: pre.command)
        return try HostedToolPolicy.claudeSettings(settings, adding: post, event: "PostToolUse")
    }
    static func rememberDraft(runID: UUID, id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 1_024, id.range(of: #"^[A-Za-z0-9+/=_-]+$"#, options: .regularExpression) != nil else { return false }
        return HostedToolPolicy.claim(replyMarker(runID, id: id))
    }
    private static func replyMarker(_ runID: UUID, id: String) -> URL {
        URL(fileURLWithPath: "/private/tmp/sentient-outlook-\(getuid())-\(runID.uuidString)-reply-\(hash(id))")
    }
    static func verifiedDraft(runID: UUID, id: String) -> Bool {
        let descriptor = open(replyMarker(runID, id: id).path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var info = stat()
        return fstat(descriptor, &info) == 0 && info.st_uid == getuid() && info.st_size == 0
            && (info.st_mode & S_IFMT) == S_IFREG
    }
    static func claim(runID: UUID, kind: String, limit: Int) -> Bool {
        guard (1...16).contains(limit), ["send", "draft", "discovery", "open", "calendar-create", "calendar-discovery", "calendar-open"].contains(kind) else { return false }
        for index in 0..<limit where HostedToolPolicy.claim(marker(runID, kind: kind, index: index)) { return true }
        return false
    }
    static func cleanup(runID: UUID) {
        for kind in ["send", "draft", "discovery", "open", "calendar-create", "calendar-discovery", "calendar-open"] {
            for index in 0..<16 { try? FileManager.default.removeItem(at: marker(runID, kind: kind, index: index)) }
        }
        let prefix = "sentient-outlook-\(getuid())-\(runID.uuidString)-reply-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/private/tmp")) ?? [] where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            if suffix.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil {
                _ = unlink("/private/tmp/" + name)
            }
        }
    }
    static func runHelper(arguments: [String]) -> Int32 {
        guard [10, 12].contains(arguments.count), let backend = ModelBackend(rawValue: arguments[2]), backend != .custom,
              let operation = OutlookMailConnector.Operation(rawValue: arguments[3]),
              let runID = UUID(uuidString: arguments[4]), arguments[8] == "-"
                || arguments[8].range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil,
              arguments[9] == "-" || arguments[9].range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil else { return reject() }
        let calendar: OutlookCalendarToolPolicy.Context?
        let includesMail: Bool
        if arguments.count == 12 {
            guard ["0", "1"].contains(arguments[10]), let parsed = OutlookCalendarToolPolicy.Context.decode(arguments[11]) else { return reject() }
            calendar = parsed; includesMail = arguments[10] == "1"
        } else { calendar = nil; includesMail = true }
        let mode: MCPSource.ReadMode?
        let window: MCPSource.Window?
        if arguments[5] == "-" {
            guard arguments[6] == "-", arguments[7] == "-" else { return reject() }
            mode = nil; window = nil
        } else {
            guard let parsed = MCPSource.ReadMode(rawValue: arguments[5]), let lower = Double(arguments[6]),
                  let upper = Double(arguments[7]), lower.isFinite, upper.isFinite, lower <= upper else { return reject() }
            mode = parsed
            window = .init(lower: Date(timeIntervalSince1970: lower), upper: Date(timeIntervalSince1970: upper), label: "")
        }
        do {
            let envelope = try HostedToolPolicy.readEnvelope()
            guard let name = envelope["tool_name"] as? String, let input = envelope["tool_input"] as? [String: Any] else { return reject() }
            if envelope["hook_event_name"] as? String == "PostToolUse" {
                guard includesMail, backend == .claude, ["outlook_create_draft", "outlook_create_reply_draft", "outlook_create_reply_all_draft"].contains(OutlookMailConnector.bareName(name, backend: backend) ?? ""),
                      allowed(name: name, input: input, backend: backend, operation: operation, expectedHash: arguments[8] == "-" ? nil : arguments[8],
                              expectedRecipientsHash: arguments[9] == "-" ? nil : arguments[9]),
                      let value = envelope["tool_response"] else { return reject() }
                // Claude's hosted MCP callback carries the content-block array directly;
                // other transports retain the MCP result object.
                let response = (value as? [String: Any]) ?? (value is [Any] ? ["content": value] : [:])
                guard !response.isEmpty,
                      response["isError"] as? Bool != true, response["is_error"] as? Bool != true,
                      OutlookMailSource.absent(response, "error") else { return reject() }
                let data = try JSONSerialization.data(withJSONObject: response)
                let call = MCPCallEvidence.Receipt(id: "post", server: nil, tool: name, arguments: nil, output: data, status: .succeeded)
                let id = response["id"] as? String ?? OutlookMailConnector.createdDraftID(call, backend: backend)
                guard let id, rememberDraft(runID: runID, id: id) else { return reject() }
                try FileHandle.standardOutput.write(contentsOf: Data("{}".utf8))
                return 0
            }
            guard envelope["hook_event_name"] as? String == "PreToolUse" else { return reject() }
            if let calendar, !includesMail || OutlookCalendarToolPolicy.handles(name, input: input, backend: backend) {
                var allow = OutlookCalendarToolPolicy.allowed(name: name, input: input, backend: backend, context: calendar)
                if allow, let bare = OutlookCalendarConnector.bareName(name, backend: backend) {
                    if bare == OutlookCalendarConnector.createTool(backend) {
                        allow = claim(runID: runID, kind: "calendar-create", limit: 1)
                        if allow, let creation = OutlookCalendarToolPolicy.Creation(input: input, backend: backend) {
                            allow = OutlookCalendarToolPolicy.reserve(creation, context: calendar)
                        } else { allow = false }
                    } else if calendar.purpose != nil {
                        let discovery = ["list_events", "outlook_calendar_search"].contains(bare)
                        allow = claim(runID: runID, kind: discovery ? "calendar-discovery" : "calendar-open",
                                      limit: discovery ? calendar.discoveryCap : calendar.detailCap)
                    }
                }
                return try HostedToolPolicy.respond(allowed: allow, service: "Outlook Calendar")
            }
            var allow = includesMail && allowed(name: name, input: input, backend: backend, operation: operation,
                mode: mode, window: window, expectedHash: arguments[8] == "-" ? nil : arguments[8],
                expectedRecipientsHash: arguments[9] == "-" ? nil : arguments[9])
            if allow, let bare = OutlookMailConnector.bareName(name, backend: backend) {
                if bare == "outlook_send_draft" {
                    guard let id = input["messageId"] as? String, verifiedDraft(runID: runID, id: id) else {
                        return try HostedToolPolicy.respond(allowed: false, service: "Outlook")
                    }
                    // Consume before the network call. Even an uncertain send cannot use the
                    // same reply draft twice, including in a wider computer-use run.
                    guard unlink(replyMarker(runID, id: id).path) == 0 else { return reject() }
                }
                if let mode {
                    let discovery = ["list_messages", "outlook_email_search"].contains(bare)
                    allow = claim(runID: runID, kind: discovery ? "discovery" : "open",
                                  limit: discovery ? OutlookMailSource.discoveryCap(mode) : OutlookMailSource.openCap(mode))
                } else if operation != .write {
                    if isSend(bare) { allow = claim(runID: runID, kind: "send", limit: 1) }
                    else if !OutlookMailConnector.reads(backend).contains(bare) { allow = claim(runID: runID, kind: "draft", limit: 1) }
                }
            }
            return try HostedToolPolicy.respond(allowed: allow, service: "Outlook")
        } catch { return reject() }
    }
    private static func reject() -> Int32 {
        try? FileHandle.standardError.write(contentsOf: Data("Outlook policy could not be verified.\n".utf8))
        return 2
    }
}
