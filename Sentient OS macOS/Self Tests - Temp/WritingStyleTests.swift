// WritingStyleTests.swift
// Synthetic end-to-end checks for the writing sample pipeline; never reads personal sources.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
#if DEBUG
import Foundation
import SQLite3
import SwiftUI

enum WritingStyleTests {
    private static var checks = 0
    private static func check(_ value: Bool, _ label: String) throws {
        checks += 1
        guard value else { Log("FAIL WritingStyle: \(label)"); throw TestError.failed }
        Log("PASS WritingStyle: \(label)")
    }
    private enum TestError: Error { case failed }
    private static func json(_ value: Any) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func run() async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("writingstyle-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            guard VaultGenerator.vaultRoot.path.hasPrefix("/tmp/") || VaultGenerator.vaultRoot.path.hasPrefix("/private/tmp/") else { throw TestError.failed }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try testLocal(in: dir)
            try testStripper()
            try testMail()
            try await WritingStyle.$acceptanceSources.withValue(["gmail", "outlook-mail"]) {
                try await testGeneration()
            }
            let view = WritingStyleSetupView(runsSetup: false)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/writingstyle-setup-preview.png"))
            }
            Log("WritingStyle tests: \(checks) passed")
        } catch { Log("WritingStyle tests FAILED: \(ErrorLabel(error))"); exit(1) }
    }

    private static func testLocal(in dir: URL) throws {
        var db: OpaquePointer?
        let path = dir.appendingPathComponent("chat.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw TestError.failed }
        defer { sqlite3_close(db) }
        func sql(_ text: String) throws {
            guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw TestError.failed }
        }
        try sql("PRAGMA journal_mode=WAL")
        try sql("CREATE TABLE chat (guid TEXT, chat_identifier TEXT, style INTEGER, is_filtered INTEGER DEFAULT 0, is_blackholed INTEGER DEFAULT 0)")
        try sql("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)")
        try sql("CREATE TABLE message (date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0)")
        try sql("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
        for person in 1...8 {
            let handle = person == 1 ? "+14155550100" : "person\(person)"
            try sql("INSERT INTO chat (ROWID,guid,chat_identifier,style) VALUES (\(person),'guid\(person)','\(handle)',45)")
            try sql("INSERT INTO chat_handle_join VALUES (\(person),\(person))")
            for number in 1...7 {
                let id = person * 100 + number
                try sql("INSERT INTO message (ROWID,date,text,is_from_me) VALUES (\(id),\(1000 + person * 10 + number),'im-\(person)-\(number)',1)")
                try sql("INSERT INTO chat_message_join VALUES (\(person),\(id))")
            }
            let incoming = person * 100 + 99
            try sql("INSERT INTO message (ROWID,date,text,is_from_me) VALUES (\(incoming),\(10000 - person * 100),'INCOMING',0)")
            try sql("INSERT INTO chat_message_join VALUES (\(person),\(incoming))")
        }
        // The newest text is a full typedstream body, longer than the ingestion truncation limit.
        let long = "hey :)\n" + String(repeating: "λ", count: 1500) + "  \n"
        let bytes = Array(long.utf8)
        let typed = Data("NSString".utf8) + Data(repeating: 0, count: 5)
            + Data([0x81, UInt8(bytes.count & 255), UInt8(bytes.count >> 8)]) + Data(bytes)
        let hex = typed.map { String(format: "%02x", $0) }.joined()
        try sql("UPDATE message SET text=NULL, attributedBody=X'\(hex)' WHERE ROWID=107")
        // Groups, hidden chats, incoming-only contacts and reactions are all more recent.
        for id in 90...93 {
            try sql("INSERT INTO chat (ROWID,guid,chat_identifier,style,is_filtered) VALUES (\(id),'g\(id)','excluded\(id)',\(id == 90 ? 43 : 45),\(id == 91 ? 2 : 0))")
            try sql("INSERT INTO chat_handle_join VALUES (\(id),\(id))")
            try sql("INSERT INTO message (ROWID,date,text,is_from_me,associated_message_type) VALUES (\(id),999999,'EXCLUDED',\(id == 92 ? 0 : 1),\(id == 93 ? 2000 : 0))")
            try sql("INSERT INTO chat_message_join VALUES (\(id),\(id))")
        }
        let names = [AddressBookNames.key(for: "+1 (415) 555-0100"): "Jordan Lee"]
        let messages = try LocalWritingSamples.iMessage(path: path, names: names)
        let texts = messages.map(\.text)
        try check(messages.count == 30, "iMessage: six people times five messages")
        try check(texts.first == long, "typedstream body and whitespace are unabridged")
        try check(!texts.contains(where: { $0.contains("EXCLUDED") || $0.contains("INCOMING") || $0.hasPrefix("im-7-") || $0.hasPrefix("im-8-") }), "iMessage: excludes groups, reactions, hidden and incoming messages; ranks by chat activity")
        try check(texts.contains("im-1-3") && !texts.contains("im-1-2"), "iMessage: latest five sent messages")
        try check(messages.first?.recipient == "Jordan Lee" && Set(messages.map(\.recipient)) == ["Jordan Lee", "person2", "person3", "person4", "person5", "person6"],
                  "iMessage: a saved contact is named, an unsaved handle stays a handle")
        try sql("INSERT INTO chat (ROWID,guid,chat_identifier,style) VALUES (100,'sms-1','+14155550100',45)")
        try sql("INSERT INTO chat_handle_join VALUES (100,1)")
        try sql("INSERT INTO message (ROWID,date,text,is_from_me) VALUES (10000,20000,'SAME PERSON SMS',1)")
        try sql("INSERT INTO chat_message_join VALUES (100,10000)")
        let merged = try LocalWritingSamples.iMessage(path: path, names: names).map(\.text)
        try check(merged.count == 30 && merged.first == "SAME PERSON SMS" && merged.contains("im-6-7") && !merged.contains("im-1-3"), "SMS and iMessage handles share one person quota")

        var wa: OpaquePointer?
        let waPath = dir.appendingPathComponent("ChatStorage.sqlite").path
        guard sqlite3_open(waPath, &wa) == SQLITE_OK else { throw TestError.failed }
        defer { sqlite3_close(wa) }
        func waSQL(_ text: String) throws {
            guard sqlite3_exec(wa, text, nil, nil, nil) == SQLITE_OK else { throw TestError.failed }
        }
        try waSQL("PRAGMA journal_mode=WAL")
        try waSQL("CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZSESSIONTYPE INTEGER, ZPARTNERNAME TEXT)")
        try waSQL("CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMESSAGEDATE REAL, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZTEXT TEXT)")
        for person in 1...8 {
            try waSQL("INSERT INTO ZWACHATSESSION VALUES (\(person),'person\(person)@s.whatsapp.net',0,\(person == 1 ? "'Jordan Lee'" : "NULL"))")
            for number in 1...7 {
                try waSQL("INSERT INTO ZWAMESSAGE VALUES (\(person * 100 + number),\(person),\(10000 - person * 100 + number),1,0,'wa-\(person)-\(number)')")
            }
            try waSQL("INSERT INTO ZWAMESSAGE VALUES (\(person * 100 + 98),\(person),\(11000 - person * 100),0,0,'INCOMING')")
            try waSQL("INSERT INTO ZWAMESSAGE VALUES (\(person * 100 + 99),\(person),\(11001 - person * 100),1,5,'SYSTEM')")
        }
        for (id, jid, kind) in [(90,"group@g.us",1), (91,"status@broadcast",0), (92,"community@g.us",4), (93,"odd@g.us",0)] {
            try waSQL("INSERT INTO ZWACHATSESSION VALUES (\(id),'\(jid)',\(kind),NULL)")
            try waSQL("INSERT INTO ZWAMESSAGE VALUES (\(id),\(id),999999,1,0,'EXCLUDED')")
        }
        let whatsapp = try LocalWritingSamples.whatsApp(path: waPath)
        try check(whatsapp.count == 30 && whatsapp.first?.text == "wa-1-7" && whatsapp.last?.text == "wa-6-3", "WhatsApp: exact recency and outgoing quotas")
        try check(!whatsapp.contains(where: { ["INCOMING", "SYSTEM", "EXCLUDED"].contains($0.text) }), "WhatsApp: excludes groups, status, communities, received and system messages")
        try check(whatsapp.first?.recipient == "Jordan Lee" && whatsapp.last?.recipient == "person6", "WhatsApp: the stored contact name, else the phone handle")
        try check(WritingStyle.render([.init(to: ["Jordan Lee"], medium: "email", text: "  hi\n"), .init(to: [], medium: "iMessage", text: "yes 😄")])
                  == "To Jordan Lee (email)\n  hi\n\n\nTo undisclosed recipients (iMessage)\nyes 😄",
                  "document heads each verbatim sample with its recipient and medium")
        try check(WritingStyle.recipientLine(["A", "B", "C", "D", "E"]) == "A, B, C and 2 more", "long recipient lists are capped")
        try check(WritingStyle.named(["Jordan@Example.com", "Sam Rivera"], names: [AddressBookNames.key(for: "jordan@example.com"): "Jordan Lee"]) == ["Jordan Lee", "Sam Rivera"],
                  "email addresses resolve through the Contacts map, names pass through")
    }

    private static func expected(_ slug: String, _ index: Int) -> String {
        index == 1 ? "\(slug) raw body 1 😄\n  keep spacing" : "\(slug) raw body \(index) 😄\n  keep spacing  "
    }
    /// Message 1 carries a quoted thread under the user's text, the way every sent reply does.
    private static func delivered(_ slug: String, _ index: Int) -> String {
        let quoted = "\nOn Tue, 1 Sep 2026 at 12:01 Sample Sender <sender@example.com>\nwrote:\n\n> earlier message\n> second line\n"
        return index == 1 ? "\(slug) raw body 1 😄\n  keep spacing  " + quoted : expected(slug, index)
    }

    /// Gmail's To header as codex delivers it. Message 1 goes back to the person quoted in its
    /// body under a name-less address, so its name must come from the attribution line.
    private static func toHeader(_ index: Int) -> String {
        index == 1 ? "\"sender@example.com\" <sender@example.com>" : "Jordan Lee <jordan@example.com>"
    }
    /// The recipients each shape resolves to.
    private static func expectedTo(_ slug: String, _ backend: ModelBackend, _ index: Int, multipart: Bool = false) -> [String] {
        if index == 1 { return slug == "gmail" ? ["Sample Sender"] : ["Jordan Lee"] }
        if multipart { return ["Jordan Lee", "taylor@example.com"] }
        return slug == "gmail" && backend == .claude ? ["jordan@example.com"] : ["Jordan Lee"]
    }

    /// Native receipts in each provider's observed shape. `htmlOnly` leaves message 0 without a
    /// plain-text form, which a real mailbox does for mail composed by marketing tools or Outlook.
    /// `bodiless` gives message 2 no body at all, the way an attachment sent alone reads back.
    private static func envelope(slug: String, backend: ModelBackend, count: Int = 15,
                                 wrongBody: Bool = false, pretendEmpty: Bool = false,
                                 multipartGmail: Bool = false, htmlOnly: Bool = false, bodiless: Bool = false) throws -> CodexCLI.Envelope {
        let html = "<div dir=\"ltr\">HTML alternative</div>"
        let ids = (0..<count).map { "m\($0)" }
        let stamps = (0..<count).map { "2026-09-01T12:\(String(format: "%02d", $0)):00Z" }
        let plain: [String?] = (0..<count).map { htmlOnly && $0 == 0 ? nil : delivered(slug, $0) }
        let empty = { (index: Int) in bodiless && index == 2 }
        let native: [[String: Any]] = (0..<count).map { index in
            switch (slug, backend) {
            case ("gmail", .claude):
                var record: [String: Any] = ["id": ids[index], "date": stamps[index], "labelIds": ["SENT"],
                                             "toRecipients": [index == 1 ? "sender@example.com" : "jordan@example.com"]]
                if empty(index) { return record }
                record["htmlBody"] = html
                if let text = plain[index] { record["plaintextBody"] = text }
                return record
            case (_, .claude):
                return ["id": ids[index], "sentDateTime": stamps[index], "isDraft": false,
                        "toRecipients": [["name": "Jordan Lee", "address": "jordan@example.com"]],
                        "body": ["contentType": plain[index] == nil ? "html" : "text", "content": empty(index) ? "" : plain[index] ?? html]]
            case ("gmail", _):
                return ["id": ids[index], "sentDateTime": stamps[index], "labelIds": ["SENT"], "isDraft": false,
                        "to": toHeader(index), "body": empty(index) ? "" : plain[index] ?? html]
            default:
                return ["id": ids[index], "sentDateTime": stamps[index], "labelIds": ["SENT"], "isDraft": false,
                        "toRecipients": [["emailAddress": ["name": "Jordan Lee", "address": "jordan@example.com"]]],
                        "body": empty(index) ? "" : plain[index] ?? html]
            }
        }
        let name = slug == "gmail" ? (backend == .claude ? "search_threads" : "search_emails")
            : (backend == .claude ? "outlook_email_search" : "list_messages")
        let arguments: [String: Any] = slug == "gmail" ? ["query": "in:sent -in:drafts"]
            : backend == .claude ? ["query": "in:sent"]
            : ["folder_id": "sentitems", "order_by": "sentDateTime desc", "top": 15, "filter": "isDraft eq false"]
        let payload: [String: Any] = multipartGmail
            ? ["emails": (0..<count).map { ["id": ids[$0], "email_ts": stamps[$0], "labels": ["SENT"]] }, "next_page_token": "more"]
            : ["messages": native]
        let detailPayload: [String: Any] = multipartGmail ? ["responses": (0..<count).map { index -> [String: Any] in
            var parts: [[String: Any]] = [
                ["mime_type": "text/plain", "filename": "notes.txt", "body": ["content": "ATTACHMENT"]],
                ["mime_type": "text/plain", "headers": [["name": "Content-Disposition", "value": "attachment"]], "body": ["content": "ATTACHMENT WITHOUT FILENAME"]],
                ["mime_type": "text/html", "body": ["content": "<p>HTML alternative</p>"]]]
            if empty(index) { parts = [parts[0]] } else if let text = plain[index] { parts.append(["mime_type": "text/plain", "body": ["content": text]]) }
            return ["id": ids[index], "internal_date": String(Int64(WritingStyleMail.parseDate(stamps[index])!.timeIntervalSince1970 * 1000)),
                    "label_ids": ["SENT"], "payload": ["mime_type": "multipart/alternative", "parts": parts,
                                                       "headers": [["name": "To", "value": toHeader(index) + (index == 1 ? "" : ", taylor@example.com")]]]]
        }] : payload
        let tool = slug == "gmail" ? (backend == .claude ? "mcp__claude_ai_Gmail__" : "gmail.") + name
            : (backend == .claude ? OutlookMailConnector.claudePrefix : "microsoft_outlook_email.") + name
        var raw: String
        if backend == .chatgpt {
            raw = try json(["type": "item.completed", "item": ["id": "r1", "type": "mcp_tool_call", "server": "codex_apps",
                "tool": tool, "arguments": arguments, "status": "completed", "result": ["content": [], "structured_content": payload]]])
        } else {
            raw = try json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "r1", "name": tool, "input": arguments]]]])
                + "\n" + json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "r1", "content": [["type": "text", "text": try json(payload)]]]]]])
        }
        if count > 0, slug == "gmail" || backend == .claude {
            let detailTool = slug == "gmail" ? (backend == .claude ? "mcp__claude_ai_Gmail__get_thread" : "gmail.batch_read_email")
                : OutlookMailConnector.claudePrefix + "read_resource"
            if backend == .chatgpt {
                raw += "\n" + (try json(["type": "item.completed", "item": ["id": "r2", "type": "mcp_tool_call", "server": "codex_apps",
                    "tool": detailTool, "arguments": ["message_ids": ids], "status": "completed", "result": ["content": [], "structured_content": detailPayload]]]))
            } else {
                raw += "\n" + (try json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "r2", "name": detailTool, "input": ["id": "fixture"]]]]]))
                    + "\n" + (try json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "r2", "content": [["type": "text", "text": try json(detailPayload)]]]]]]))
            }
        }
        var output: [[String: Any]] = (0..<count).map { ["id": ids[$0], "sent_at": stamps[$0], "body": plain[$0] ?? html] }
        if wrongBody, !output.isEmpty { output[0]["body"] = "A summary, not the real body" }
        if pretendEmpty { output = [] }
        return .init(result: try json(["messages": output, "exhausted": output.count < 15, "tool_failure": ""]),
                     sessionID: nil, numTurns: nil, durationMS: nil, inputTokens: nil, cachedInputTokens: nil, outputTokens: nil, raw: raw)
    }

    private static func testMail() throws {
        for backend in [ModelBackend.chatgpt, .claude] {
            for slug in ["gmail", "outlook-mail"] {
                let label = "\(backend.rawValue) \(slug)"
                let valid = try envelope(slug: slug, backend: backend)
                let samples = try WritingStyleMail.validate(valid, slug: slug, backend: backend)
                try check(samples.count == 15 && samples.first?.id == "m14", "\(label): real receipts and newest-first ordering")
                try check(samples.map(\.text) == (0..<15).reversed().map { expected(slug, $0) },
                          "\(label): samples are the user's own words with the quoted thread removed")
                try check(samples.map(\.to) == (0..<15).reversed().map { expectedTo(slug, backend, $0) },
                          "\(label): recipients are named from the receipt or the reply's attribution line")
                let rewritten = try WritingStyleMail.validate(envelope(slug: slug, backend: backend, wrongBody: true), slug: slug, backend: backend)
                try check(rewritten.map(\.text) == samples.map(\.text), "\(label): model rewriting cannot alter native bodies")
                let omitted = try WritingStyleMail.validate(envelope(slug: slug, backend: backend, pretendEmpty: true), slug: slug, backend: backend)
                try check(omitted.count == 15, "\(label): model omissions cannot discard observed messages")
                var previewRaw = valid.raw
                for (key, preview) in [("body", "bodyPreview"), ("plaintextBody", "bodyPreview"), ("htmlBody", "htmlPreview")] {
                    previewRaw = previewRaw.replacingOccurrences(of: "\"\(key)\":", with: "\"\(preview)\":")
                        .replacingOccurrences(of: "\\\"\(key)\\\":", with: "\\\"\(preview)\\\":")
                }
                let previews = CodexCLI.Envelope(result: valid.result, sessionID: nil, numTurns: nil, durationMS: nil,
                    inputTokens: nil, cachedInputTokens: nil, outputTokens: nil, raw: previewRaw)
                var refused = false
                do { _ = try WritingStyleMail.validate(previews, slug: slug, backend: backend) } catch { refused = true }
                try check(refused, "\(label): previews cannot stand in for complete bodies")
                try check(try WritingStyleMail.validate(envelope(slug: slug, backend: backend, count: 0), slug: slug, backend: backend).isEmpty,
                          "\(label): verified empty mailbox accepted")
                let html = try WritingStyleMail.validate(envelope(slug: slug, backend: backend, htmlOnly: true), slug: slug, backend: backend)
                try check(html.count == 14 && !html.contains { $0.id == "m0" || $0.text.contains("<") },
                          "\(label): an HTML-only message is verified but never sampled")
                let bodiless = try WritingStyleMail.validate(envelope(slug: slug, backend: backend, bodiless: true), slug: slug, backend: backend)
                try check(bodiless.count == 14 && !bodiless.contains { $0.id == "m2" },
                          "\(label): an attachment sent without text is a complete read with no sample")
            }
        }
        let multipart = try WritingStyleMail.validate(envelope(slug: "gmail", backend: .chatgpt, multipartGmail: true), slug: "gmail", backend: .chatgpt)
        try check(multipart.count == 15 && multipart.first?.text == "gmail raw body 14 😄\n  keep spacing  ",
                  "live Gmail multipart format preserves plain-text bodies, dates and whitespace")
        try check(!multipart.contains(where: { $0.text.contains("ATTACHMENT") || $0.text.contains("<p>") }),
                  "Gmail selects plain text before HTML and excludes attachments")
        try check(multipart.map(\.to) == (0..<15).reversed().map { expectedTo("gmail", .chatgpt, $0, multipart: true) },
                  "Gmail To headers yield every recipient, named when the header names them")
        let multipartHTML = try WritingStyleMail.validate(envelope(slug: "gmail", backend: .chatgpt, multipartGmail: true, htmlOnly: true), slug: "gmail", backend: .chatgpt)
        try check(multipartHTML.count == 14 && !multipartHTML.contains { $0.id == "m0" },
                  "Gmail multipart without a plain-text part is never sampled as markup")
        let multipartEmpty = try WritingStyleMail.validate(envelope(slug: "gmail", backend: .chatgpt, multipartGmail: true, bodiless: true), slug: "gmail", backend: .chatgpt)
        try check(multipartEmpty.count == 14 && !multipartEmpty.contains { $0.id == "m2" },
                  "Gmail multipart with only an attachment part is a complete read with no sample")
    }

    /// Every client shape the stripper must recognize, with fictional names throughout.
    private static func testStripper() throws {
        let own = "Hey Jordan,\n\nSounds great, would love to meet any time on\nFriday after 12.\n\nBest,\nSam"
        let attribution = "On Wed, 16 Sep 2026 at 12:03 Jordan Lee <jordan@example.com> wrote:"
        let quoted = "\n\n> Can you do Friday?\n>\n> Jordan\n"
        let prose = "On the surface this looks like a quote header but it is not.\nOn the other hand, as I wrote: it stays.\nhttps://example.com/on-date-someone-wrote-about-parsing"
        let wrappedLink = "Details at <https://example.com/a/very/long/path\n> and that is all.\nThanks"
        let cold = "Hi Jordan,\n\nCold intro.\n\nBest,\nSam\n"
        let cases: [(label: String, body: String, text: String?)] = [
            ("Gmail single-line attribution", own + "\n\n" + attribution + quoted, own),
            ("Gmail attribution wrapped before wrote:", own + "\n\nOn Wed, 16 Sep 2026 at 12:03 Jordan Lee <jordan@example.com>\nwrote:" + quoted, own),
            ("Gmail attribution wrapped inside the address", own + "\n\nOn Wed, 16 Sep 2026 at 12:03 Jordan Lee <\njordan@example.com> wrote:" + quoted, own),
            ("CRLF line endings", (own + "\n\n" + attribution + quoted).replacingOccurrences(of: "\n", with: "\r\n"), own),
            ("US date with the sign-off directly above", "Thanks!\nSam\nOn Tue, Sep 15, 2026 at 4:37 PM Jordan Lee <jordan@example.com> wrote:\n> ping", "Thanks!\nSam"),
            ("Apple Mail", "Sounds good, see you then.\n\nOn Dec 16, 2024, at 12:47 PM, Support <support@example.com> wrote:\n\n> How can we help?\n", "Sounds good, see you then."),
            ("nested quotes", own + "\n\n> On Tue, 15 Sep 2026 at 10:00 Taylor Kim <taylor@example.com> wrote:\n>\n>> older\n", own),
            ("Apple Mail forward", "FYI.\n\nBegin forwarded message:\n\nFrom: Jordan Lee <jordan@example.com>\nSubject: Q3\nDate: December 16, 2024\nTo: Sam <sam@example.com>\n\nBody", "FYI."),
            ("Gmail forward", "See below.\n\n---------- Forwarded message ---------\nFrom: Jordan Lee <jordan@example.com>\nDate: Wed, 16 Sep 2026 at 12:03\nSubject: Q3\nTo: <sam@example.com>\n\nBody", "See below."),
            ("forward without a comment", "---------- Forwarded message ---------\nFrom: Jordan Lee <jordan@example.com>\nDate: Wed, 16 Sep 2026\n\nBody", nil),
            ("Outlook web underscores", own + "\n________________________________\nFrom: Jordan Lee <jordan@example.com>\nSent: Tuesday, September 15, 2026 4:37 PM\nTo: Sam\nSubject: Friday\n\nCan you do Friday?", own),
            ("Outlook header block with a wrapped From", own + "\n\nFrom: Human Resources \n<a-really-long-address@example.com> \nSent: Monday, August 26, 2019 4:37 PM\nTo: Sam\nSubject: Onboarding\n\nWelcome", own),
            ("Outlook original message", own + "\n\n-----Original Message-----\nFrom: Jordan Lee\nSent: Tuesday\nTo: Sam\nSubject: Friday\n\nCan you do Friday?", own),
            ("Danish Outlook separator", own + "\n\n-------- Oprindelig besked --------\nFra: Jordan Lee <jordan@example.com>\nDato: 1. september 2026\nTil: Sam\nEmne: Fredag\n\nHej", own),
            ("Outlook iOS device signature", own + "\n\nGet Outlook for iOS<https://aka.ms/o0ukef>\n________________________________\nFrom: Jordan Lee\nSent: Tuesday\nSubject: Friday", own),
            ("iPhone signature", "Here is another email\n\nSent from my iPhone", "Here is another email"),
            ("signature dash block", "Quick note.\n\n-- \nSam Rivera\nCTO, Example Co", "Quick note."),
            ("French Gmail wrapped", own + "\n\nLe lun. 15 nov. 2021 à 19:42, Jordan Lee <jordan@example.com>\na écrit :\n\n> Bonjour", own),
            ("German Gmail", own + "\n\nAm Mo., 15. Nov. 2021 um 19:42 Uhr schrieb Jordan Lee <jordan@example.com>:\n\n> Hallo", own),
            ("Zoho", "What is the best way to clear a bucket?\n\n---- On Wed, 24 Feb 2021 14:02:50 +0530 jordan@example.com wrote ----\n\nNo idea", "What is the best way to clear a bucket?"),
            ("quote run without attribution", "I wanted to respond to your points:\n\n> first point\n> second point\n\nAgreed on both.", "I wanted to respond to your points:"),
            ("prose beginning with On is not an attribution", prose, prose),
            ("a lone > from a wrapped link", wrappedLink, wrappedLink),
            ("cold email untouched, trailing newline kept", cold, cold),
            ("whitespace only", "\n\n", nil),
            ("real sign-offs stay", "Sure thing.\n\nCheers,\nSam", "Sure thing.\n\nCheers,\nSam"),
        ]
        for item in cases {
            try check(MailQuoteStripper.ownText(of: item.body) == item.text, "stripper: \(item.label)")
        }
        let authors: [(label: String, body: String, name: String?, address: String?)] = [
            ("Gmail day-first", "Thanks!\n\n" + attribution + quoted, "Jordan Lee", "jordan@example.com"),
            ("Gmail US with AM", "Thanks!\n\nOn Wed, Sep 16, 2026 at 11:52 AM Taylor Kim <taylor@example.com> wrote:\n> x", "Taylor Kim", "taylor@example.com"),
            ("Apple Mail with PM", "Ok.\n\nOn Dec 16, 2024, at 12:47 PM, Support <support@example.com> wrote:\n\n> x", "Support", "support@example.com"),
            ("French", "Merci.\n\nLe lun. 15 nov. 2021 à 19:42, Jordan Lee <jordan@example.com>\na écrit :\n\n> x", "Jordan Lee", "jordan@example.com"),
            ("German, name after schrieb", "Danke.\n\nAm Mo., 15. Nov. 2021 um 19:42 Uhr schrieb Jordan Lee <jordan@example.com>:\n\n> x", "Jordan Lee", "jordan@example.com"),
            ("quoted name", "Ok.\n\nOn Wed, 16 Sep 2026 at 12:03 \"Jordan Lee\" <jordan@example.com> wrote:\n> x", "Jordan Lee", "jordan@example.com"),
            ("wrapped inside the address", "Ok.\n\nOn Wed, 16 Sep 2026 at 12:03 Jordan Lee <\njordan@example.com> wrote:\n> x", "Jordan Lee", "jordan@example.com"),
            ("address without a name", "Ok.\n\nOn Wed, 16 Sep 2026 at 12:03 <jordan@example.com> wrote:\n> x", nil, "jordan@example.com"),
            ("Zoho without brackets", "Ok.\n\n---- On Wed, 24 Feb 2021 14:02:50 +0530 jordan@example.com wrote ----\n\nx", nil, nil),
            ("cold email", cold, nil, nil),
        ]
        for item in authors {
            let author = MailQuoteStripper.attributedAuthor(in: item.body)
            try check(author?.name == item.name && author?.address == item.address, "attribution author: \(item.label)")
        }
        let boxes = WritingStyleMail.mailboxes(in: "Jordan Lee <jordan@example.com>, \"Kim, Taylor\" <taylor@example.com>, sam@example.com, \"sam@example.com\" <sam@example.com>")
        try check(boxes == [.init(name: "Jordan Lee", address: "jordan@example.com"), .init(name: "Kim, Taylor", address: "taylor@example.com"),
                            .init(name: nil, address: "sam@example.com"), .init(name: nil, address: "sam@example.com")],
                  "mailbox list: names, a quoted name with a comma, bare and self-named addresses")
    }

    private static func testGeneration() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        }
        var overrides = original
        overrides[ModelBackend.key] = "chatgpt"
        for key in ["dbg.gmail.connected", "dbg.run.gmail", "mcp.outlook-mail.kb"] { overrides[key] = true }
        for key in ["dbg.run.imessage", "dbg.run.whatsapp"] { overrides[key] = false }
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        overrides["dbg.run.gmail"] = false
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        try WritingStyle.$acceptanceSources.withValue(nil) {
            try check(WritingStyle.Selection().mail.contains("gmail"), "connected Gmail participates when regular analysis is off")
        }
        let root = VaultGenerator.vaultRoot
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // This is the test-only root verified by run(), never the user's real knowledge base.
        try? fm.removeItem(at: root.appendingPathComponent(WritingStyle.fileName))
        try "# Fixture user".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await FrontierRun.$acceptanceRun.withValue({ invocation in
            try await MainActor.run {
                try check(invocation.connectorOnlyRead && invocation.sandbox == .readOnly && !invocation.bypassApprovals && !invocation.webSearch,
                          "mail uses confined connector reads")
                return try envelope(slug: invocation.mcpReadConnectors[0], backend: .chatgpt)
            }
        }) { try await WritingStyle.generateIfNeeded() }
        let file = root.appendingPathComponent(WritingStyle.fileName)
        let text = try String(contentsOf: file, encoding: .utf8)
        try check(text.components(separatedBy: "raw body").count == 31, "generation keeps 15 Gmail plus 15 Outlook emails")
        try check(text.contains("To Jordan Lee (email)\n") && text.contains("To Sample Sender (email)\n"),
                  "document names each recipient, including one read from the reply's attribution line")
        try check(!text.contains("#") && !text.contains("sentAt") && !text.contains("wrote:") && !text.contains("\n> "),
                  "document contains only the user's own words")
        try await FrontierRun.$acceptanceRun.withValue({ _ in throw TestError.failed }) { try await WritingStyle.generateIfNeeded() }
        try check(try String(contentsOf: file, encoding: .utf8) == text, "completed setup is idempotent")
        try WritingStyle.publish("REPLACEMENT", in: root)
        try check(try String(contentsOf: file, encoding: .utf8) == text, "publication never replaces an existing user file")
        let staging = root.deletingLastPathComponent().appendingPathComponent("fixture-staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try "REWRITTEN".write(to: staging.appendingPathComponent(WritingStyle.fileName), atomically: true, encoding: .utf8)
        try WritingStyle.preserve(in: staging, from: root)
        try check(try String(contentsOf: staging.appendingPathComponent(WritingStyle.fileName), encoding: .utf8) == text, "vault swaps restore the untouched raw artifact")
        try String(repeating: "x", count: DoubleTapInference.vaultByteCeiling).write(to: root.appendingPathComponent("Big.md"), atomically: true, encoding: .utf8)
        let packed = try DoubleTapInference.packVault(root)
        Log("WritingStyle pack fixture: notes=\(packed.notes) bytes=\(packed.bytes) truncated=\(packed.truncated) suffix=\(packed.text.hasSuffix(text + "\n"))")
        try check(packed.truncated && packed.text.hasSuffix(text + "\n"), "samples remain complete and last when other notes exceed the budget")
        try check(packed.text.components(separatedBy: text).count == 2, "writing samples are included exactly once")
        try fm.removeItem(at: file)
        try WritingStyle.preserve(in: staging, from: root)
        try check(!WritingStyle.exists(in: staging), "a fabricated staged artifact is removed")
        var cancelled = false
        do {
            try await FrontierRun.$acceptanceRun.withValue({ _ in throw CancellationError() }) { try await WritingStyle.generateIfNeeded() }
        } catch is CancellationError { cancelled = true }
        try check(cancelled && !WritingStyle.exists(), "cancelled setup publishes no partial file")

        overrides[AppState.onboardingKey] = false
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        await FrontierRun.$acceptanceRun.withValue({ invocation in
            try await MainActor.run { try envelope(slug: invocation.mcpReadConnectors[0], backend: .chatgpt) }
        }) {
            ProactiveCycle.publishWritingStyle(await ProactiveCycle.collectWritingStyle())
        }
        try check(WritingStyle.exists(), "initial-processing hook collects the samples and lands the file")
        try fm.removeItem(at: file)
        overrides[AppState.onboardingKey] = true
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        await FrontierRun.$acceptanceRun.withValue({ _ in throw TestError.failed }) {
            ProactiveCycle.publishWritingStyle(await ProactiveCycle.collectWritingStyle())
        }
        try check(!WritingStyle.exists(), "existing-user background cycles leave setup to the home")
    }
}
#endif
