// Compile this fixture with the production MailAccount.swift and GmailSenderMetadata.swift.
// It needs Foundation only; it never contacts a mailbox, Supabase or the user's Keychain.
import Foundation

@main enum GmailSenderMetadataTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS \(name)")
        }
        func message(_ sender: String, _ labels: [String] = ["SENT"]) -> [String: Any] {
            ["sender": sender, "labelIds": labels]
        }
        func payload(_ messages: [[String: Any]]) -> [String: Any] { ["threads": [["messages": messages]]] }
        func result(_ messages: [[String: Any]]) -> [String: Any] { ["structuredContent": payload(messages)] }
        func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        let own = message("me@example.com")
        let mixed = payload([message("someone-else@example.com", ["INBOX"]), own])

        check(GmailSenderMetadata.email(from: ["structuredContent": mixed]) == "me@example.com", "ignore received replies in a sent thread")
        check(GmailSenderMetadata.email(from: ["content": try json(mixed)]) == "me@example.com", "Claude string-form result")
        check(GmailSenderMetadata.email(from: ["content": [["type": "text", "text": try json(mixed)]]]) == "me@example.com", "MCP text-block result")
        check(GmailSenderMetadata.email(from: ["structured_content": mixed]) == "me@example.com", "alternate structured-content spelling")
        check(GmailSenderMetadata.email(from: ["structuredContent": mixed, "content": "someone-else@example.com"]) == "me@example.com", "typed result takes precedence over prose")
        check(GmailSenderMetadata.email(from: result([message("Me@Example.com"), message("Person <me@example.com>")])) == "me@example.com", "normalize repeated sender representations")
        check(GmailSenderMetadata.email(from: result([own, message("alias@example.com")])) == nil, "multiple sending addresses skip collection")
        check(GmailSenderMetadata.email(from: ["structuredContent": ["threads": []]]) == nil, "empty mailbox skips collection")
        check(GmailSenderMetadata.email(from: result([message("other@example.com", ["INBOX"])])) == nil, "never infer an address from received mail")
        check(GmailSenderMetadata.email(from: result([["sender": "me@example.com"]])) == nil, "missing SENT evidence skips collection")
        check(GmailSenderMetadata.email(from: result([own, message("not-an-email")])) == nil, "malformed sent sender invalidates inference")
        check(GmailSenderMetadata.email(from: result([message("me@example.com\r\nBcc: other@example.com")])) == nil, "reject header injection")
        check(GmailSenderMetadata.email(from: result([message("me@example.com, other@example.com")])) == nil, "reject mailbox lists")
        check(GmailSenderMetadata.email(from: result([message("other@example.com, Person <me@example.com>")])) == nil, "reject mixed bare and named mailbox lists")
        check(GmailSenderMetadata.email(from: result([message("Person <me@example.com>, other@example.com")])) == nil, "reject addresses after a named mailbox")
        check(GmailSenderMetadata.email(from: result([message("One <one@example.com>, Two <two@example.com>")])) == nil, "reject multiple named mailboxes")
        check(GmailSenderMetadata.email(from: ["isError": true, "structuredContent": mixed]) == nil, "tool failures cannot produce an identity")
        check(GmailSenderMetadata.email(from: ["content": "The account is me@example.com"]) == nil, "never scrape an address from prose")
        check(GmailSenderMetadata.email(from: ["content": "{bad-json"]) == nil, "malformed JSON skips collection")
        for key in ["plaintextBody", "htmlBody", "subject", "snippet"] {
            var body = own; body[key] = "Unexpected content"
            check(GmailSenderMetadata.email(from: result([body])) == nil, "reject ignored metadata-only mode: \(key)")
        }
        var emptyFields = own; emptyFields["plaintextBody"] = ""; emptyFields["subject"] = NSNull()
        check(GmailSenderMetadata.email(from: result([emptyFields])) == "me@example.com", "allow unpopulated content fields")
        check(GmailSenderMetadata.email(from: ["structuredContent": ["threads": [["messages": [own]], ["messages": [own]]]]]) == nil, "enforce one-thread response bound")

        let candidate = MailAccountCandidate(engine: .claude, provider: .gmail, connectionKey: "test", email: "me@example.com", reportedVia: .sentMailMetadata)
        let fallback = MailAccountCandidate(engine: .claude, provider: .gmail, connectionKey: "other", email: nil, reportedVia: .sentMailMetadata)
        guard let account = candidate.detectedAccount else { fatalError("Detected account missing") }
        check(account.email == "me@example.com", "resolve the sending address for the email-only contact list")
        check(fallback.detectedAccount == nil, "missing address is skipped without accepting manual input")
        check([candidate, fallback].compactMap(\.detectedAccount).count == 1, "resolved account is retained while unresolved accounts are skipped")
        check([fallback].compactMap(\.detectedAccount).isEmpty, "unresolved-only discovery does not save")
        let otherEngine = MailAccountCandidate(engine: .chatgpt, provider: .gmail, connectionKey: "codex", email: "codex@example.com")
        check(otherEngine.detectedAccount?.reportedVia == .connectorProfile, "Codex keeps profile provenance")
        do {
            _ = try MailAccount(engine: .chatgpt, provider: .outlook, connectionKey: "invalid", email: "a@example.com", reportedVia: .sentMailMetadata)
            check(false, "reject incompatible provenance")
        } catch MailAccountError.invalidResponse { check(true, "reject incompatible provenance") }
        print("\(count) Gmail metadata checks passed")
    }
}
