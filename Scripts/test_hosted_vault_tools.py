#!/usr/bin/env python3
"""Compile complete hosted vault file and RPC implementation with an inert local transport.
No app folders, account, network, real credentials or model calls are used.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
SUPPORT = r'''
import Foundation
nonisolated enum ModelBackend { case sentient, claude; static let current = Self.sentient }
nonisolated enum CodexCLI {
    enum Availability { case notWorking(String) }
    enum CLIError: Error { case notAvailable(Availability) }
    struct Invocation {
        enum Sandbox { case workspaceWrite, readOnly }
        var hostedVaultRoot: String?, hostedVaultReadRoot: String?, cwd: String?
        var sandbox = Sandbox.workspaceWrite
        var bypassApprovals = false, toolsDisabled = false, webSearch = false
        var addDirs: [String] = [], mcpReadConnectors: [String] = [], configOverrides: [String] = []
        var mcpActionServer: String?, mcpAttachServer: String?, appleMailResearch: String?
        static let approveConnectorWrites = ["unsafe"]
    }
}
actor LocalMCPServer {
    nonisolated struct Connection: Sendable { let name: String; let tools: [String] }
    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int, response: @escaping @Sendable (Data) async throws -> Data) {}
    func start() throws -> Connection { .init(name: "sentient_vault", tools: HostedVaultToolServer.toolNames) }
    func stop() {}
}
'''
TEST = r'''
import Foundation
import Darwin
@main struct Test {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        func rejects(_ body: () throws -> Void, _ name: String) {
            do { try body(); preconditionFailure(name) } catch { checks += 1 }
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("sentient-vault-capability-\(UUID())")
        let root = temporary.appendingPathComponent("staging")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let files = try HostedVaultFiles(root: root)
        func write(_ path: String, _ text: String) throws { _ = try files.call("vault_write", arguments: ["path": path, "text": text]) }
        func read(_ path: String) throws -> String { try files.call("vault_read", arguments: ["path": path])["text"] as! String }
        try write("README.md", "# Portrait\n")
        try write("Work/Crème — Plan.md", "alpha beta")
        check(try read("README.md") == "# Portrait\n", "Markdown write/read")
        _ = try files.call("vault_edit", arguments: ["path":"Work/Crème — Plan.md", "old_text":"beta", "new_text":"gamma"])
        check(try read("Work/Crème — Plan.md") == "alpha gamma", "literal unique edit preserves Unicode")
        try write("duplicates.md", "x x")
        rejects({ _ = try files.call("vault_edit", arguments: ["path":"duplicates.md", "old_text":"x", "new_text":"y"]) }, "ambiguous edit refused")
        rejects({ _ = try files.call("vault_edit", arguments: ["path":"duplicates.md", "old_text":"missing", "new_text":"y"]) }, "absent edit refused")
        check(try read("duplicates.md") == "x x", "failed edits preserve note")
        for path in ["/outside.md", "../outside.md", "Work/../../outside.md", "./README.md", "Work//note.md", ".secret.md", "Work/.hidden/note.md", "note.txt", "writingstyle.md", "Work/WRITINGSTYLE.md", "Work\\outside.md", "line\nname.md"] {
            rejects({ try write(path, "bad") }, "unsafe path refused: " + path)
        }
        let outside = temporary.appendingPathComponent("outside.md")
        try "external sentinel".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.md"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: temporary)
        try fm.linkItem(at: outside, to: root.appendingPathComponent("hard.md"))
        for path in ["link.md", "outside/outside.md", "hard.md"] {
            rejects({ _ = try read(path) }, "link read refused")
            rejects({ try write(path, "bad") }, "link write refused")
        }
        check(try String(contentsOf: outside, encoding: .utf8) == "external sentinel", "external files unchanged")
        let rootLink = temporary.appendingPathComponent("rootlink")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: root)
        rejects({ _ = try HostedVaultFiles(root: rootLink) }, "symlink root refused")
        let first = try files.call("vault_list", arguments: [:])["paths"] as! [String]
        let second = try files.call("vault_list", arguments: [:])["paths"] as! [String]
        check(first == second && first == ["README.md", "Work/Crème — Plan.md", "duplicates.md"], "repeat listings exclude links and keep directory offsets independent")
        rejects({ try write("large.md", String(repeating:"a", count: HostedVaultFiles.maximumFileBytes + 1)) }, "oversize note refused")
        rejects({ _ = try files.call("vault_read", arguments: ["path":"README.md", "other":true]) }, "extra arguments refused")
        rejects({ _ = try files.call("Bash", arguments: ["command":"echo unsafe"]) }, "unknown capability refused")
        check(!((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).contains { $0.hasPrefix(".sentient-write-") }, "temporary write files cleaned")
        let mode = try fm.attributesOfItem(atPath: root.appendingPathComponent("README.md").path)[.posixPermissions] as! NSNumber
        check(mode.intValue == 0o600, "created notes are private")

        let server = try HostedVaultToolServer(root: root)
        func rpc(_ id: Int, _ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":id, "method":"tools/call", "params":["name":name,"arguments":args]])
            let responseData = try await server.response(data)
            return try JSONSerialization.jsonObject(with: responseData) as! [String: Any]
        }
        let created = try await rpc(1, "vault_write", ["path":"rpc.md", "text":"first"])
        let replay = try await rpc(1, "vault_write", ["path":"rpc.md", "text":"first"])
        check(NSDictionary(dictionary: created).isEqual(to: replay), "same request ID replays exact result")
        let reused = try await rpc(1, "vault_write", ["path":"rpc.md", "text":"changed"])
        check(try (reused["result"] as? [String:Any])?["isError"] as? Bool == true && read("rpc.md") == "first", "changed request ID cannot repeat write")
        let denied = try await rpc(2, "vault_read", ["path":"../outside.md"])
        check((denied["result"] as? [String:Any])?["isError"] as? Bool == true, "RPC rejects escaping requests without content")
        await server.stop()
        do { _ = try await rpc(3,"vault_read",["path":"README.md"]); preconditionFailure("closed server accepted request") } catch { checks += 1 }
        let readOnly = try HostedVaultToolServer(root: root, readOnly: true)
        let deniedWrite = try await readOnly.response(JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":10,"method":"tools/call","params":["name":"vault_write","arguments":["path":"README.md","text":"forbidden"]]]))
        let readOnlyReply = try JSONSerialization.jsonObject(with: deniedWrite) as! [String:Any]
        check((readOnlyReply["result"] as? [String:Any])?["isError"] as? Bool == true, "research file capability denies writes")
        await readOnly.stop()
        var invocation = CodexCLI.Invocation()
        rejects({ try HostedVaultToolServer.validateInvocation(invocation) }, "workspace edits need explicit capability")
        invocation.hostedVaultRoot = root.path; invocation.cwd = root.path
        let connection = LocalMCPServer.Connection(name: HostedVaultToolServer.name, tools: HostedVaultToolServer.toolNames)
        try HostedVaultToolServer.$connection.withValue(connection) {
            try HostedVaultToolServer.validateInvocation(invocation); checks += 1
            invocation.webSearch = true
            rejects({ try HostedVaultToolServer.validateInvocation(invocation) }, "knowledge rejects web access")
            invocation.webSearch = false; invocation.addDirs = [temporary.path]
            rejects({ try HostedVaultToolServer.validateInvocation(invocation) }, "knowledge rejects added roots")
        }
        print("\(checks) hosted vault confinement checks passed")
    }
}
'''
def run_tests():
    with tempfile.TemporaryDirectory(prefix='sentient-hosted-vault-') as temporary:
        root = Path(temporary)
        (root/'Support.swift').write_text(SUPPORT)
        (root/'Test.swift').write_text(TEST)
        executable = root/'tests'
        subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-default-isolation','MainActor','-warnings-as-errors',
                        str(APP/'Cloud/HostedVaultFiles.swift'), str(APP/'Cloud/HostedVaultToolServer.swift'),
                        str(root/'Support.swift'),str(root/'Test.swift'),'-o',str(executable)],check=True)
        subprocess.run([str(executable)],check=True)

if __name__ == '__main__':
    run_tests()
