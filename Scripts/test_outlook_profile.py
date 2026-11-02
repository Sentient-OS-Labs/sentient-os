#!/usr/bin/env python3
"""Replay profile response variants through Outlook's production decoder without I/O."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def member(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


source = (APP / "Cloud/OutlookMailConnector.swift").read_text()
fixture = r'''
import Foundation
import CryptoKit
enum ModelBackend: CaseIterable { case chatgpt, claude }
enum MCPSource { enum MCPError: Error { case invalidResponse(slug: String, rule: String) } }
enum MCPCallEvidence {
    enum Status { case succeeded, failed }
    struct Receipt { var status: Status = .succeeded; var arguments: Data?; var output: Data? }
}
enum OutlookMailConnector {
    static let slug = "outlook-mail"
    __PRODUCTION__
}
func data(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func text(_ value: Any) -> [String: Any] { ["type": "text", "text": String(decoding: data(value), as: UTF8.self)] }
@main struct Tests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
    static func main() throws {
        for backend in ModelBackend.allCases {
            for id in ["12345678-1234-4234-8234-123456789ABC", "a12B34C56D78E90f", "opaque-account/AbC=", "provider account key"] {
                let profile: [String: Any] = ["id": id, "email": "User@Example.test", "mail": "User@Example.test", "newMetadata": ["enabled": true]]
                let envelopes: [[String: Any]] = [
                    profile,
                    ["structuredContent": profile],
                    ["structured_content": profile, "content": [text(profile)]],
                    ["content": [["type": "text", "text": "An informational provider notice."], text(profile)]],
                    ["structuredContent": profile, "content": [text(["notice": "metadata"])]],
                    ["result": profile],
                    ["jsonrpc": "2.0", "id": 7, "result": ["structuredContent": profile]],
                    ["content": [text(["result": profile])]],
                ]
                for envelope in envelopes {
                    let call = MCPCallEvidence.Receipt(arguments: nil, output: data(envelope))
                    let parsed = try OutlookMailConnector.profileIdentity(call, backend: backend)
                    check(parsed.id == id && parsed.email == "user@example.test", "opaque identifiers and equivalent envelopes are accepted")
                }
            }
            let fallback: [String: Any] = ["id": "personal-id", "mail": NSNull(), "userPrincipalName": " user@example.test "]
            check(try OutlookMailConnector.profileIdentity(.init(output: data(fallback)), backend: backend).email == "user@example.test",
                  "missing optional mail uses returned principal name")
            let profile: [String: Any] = ["id": "account-A", "email": "user@example.test", "mail": "user@example.test"]
            let other: [String: Any] = ["id": "account-B", "email": "user@example.test", "mail": "user@example.test"]
            for envelope: [String: Any] in [
                ["structuredContent": profile, "content": [text(other)]],
                ["isError": true, "structuredContent": profile],
                ["is_error": true, "structured_content": profile],
                ["jsonrpc": "2.0", "result": ["isError": true, "structuredContent": profile]],
                ["id": "", "email": "user@example.test"],
                ["id": "account", "mail": NSNull()],
                ["id": 42, "email": "user@example.test"],
            ] {
                do {
                    _ = try OutlookMailConnector.profileIdentity(.init(output: data(envelope)), backend: backend)
                    preconditionFailure("unusable or conflicting account accepted")
                } catch { check(true, "actual errors and conflicting identities remain failures") }
            }
            do {
                _ = try OutlookMailConnector.profileIdentity(.init(status: .failed, output: data(profile)), backend: backend)
                preconditionFailure("failed call accepted")
            } catch { check(true, "failed provider call cannot establish identity") }
        }
        let lower = OutlookMailConnector.Identity(id: "12345678-1234-4234-8234-123456789abc", email: "user@example.test")
        let upper = OutlookMailConnector.Identity(id: lower.id.uppercased(), email: "USER@example.test")
        check(lower.fingerprint == upper.fingerprint, "existing UUID account fingerprints remain stable")
        check(OutlookMailConnector.Identity(id: "Abc", email: lower.email).fingerprint != OutlookMailConnector.Identity(id: "abc", email: lower.email).fingerprint,
              "opaque case-sensitive identifiers remain distinct")
        print("PASS \(checks) Outlook profile compatibility checks")
    }
}
'''
fixture = fixture.replace("__PRODUCTION__", "\n".join(member(source, name) for name in (
    "static func object(", "struct Identity:", "static func profileIdentity(")))
with tempfile.TemporaryDirectory(prefix="sentient-outlook-profile-") as folder:
    folder = Path(folder)
    swift = folder / "ProfileTests.swift"
    swift.write_text(fixture)
    binary = folder / "profile-tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), str(APP / "Connectors/DirectMCPResult.swift"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=15)
