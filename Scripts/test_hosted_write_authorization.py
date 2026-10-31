#!/usr/bin/env python3
"""Exercise production hosted write scope with synthetic accounts and an inert model boundary."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Connectors/Hosted/HostedConnectorAuthorization.swift"
FIXTURE = r'''
import Foundation
nonisolated enum ModelBackend { case sentient, chatgpt; static var current = Self.sentient }
nonisolated struct HostedConnectorAccount {
    let taskTarget: String, service: String, label: String
    var connected = true
    var taskDescription: String { "Read and send plain text" }
}
nonisolated enum HostedConnectorStore {
    static var records: [HostedConnectorAccount] = []
    static func accounts() -> [HostedConnectorAccount] { records }
    static func account(_ target: String) -> HostedConnectorAccount? { records.first { $0.taskTarget == target } }
}
nonisolated final class SidekickInteraction {
    static var current: SidekickInteraction? = .init()
    var authorizedHostedWrites: Set<String> = []
    func authorizeHostedWrites(_ targets: Set<String>) { authorizedHostedWrites = targets }
}
nonisolated enum CodexCLI {
    struct Invocation {
        let prompt: String
        enum Model { case gpt6luna }; var model = Model.gpt6luna
        enum Effort { case low }; var effort = Effort.low
        enum Sandbox { case readOnly }; var sandbox = Sandbox.readOnly
        var webSearch = true, includeUserConfig = true, toolsDisabled = false
        var timeout: Double = 0, feature = "", outputSchema: String?
    }
    struct Envelope { let jsonResult: String }
}
nonisolated enum FrontierRun {
    static var reply = #"{"targets":[]}"#
    static var calls = 0
    static var fail = false, cancel = false
    static var after: (() -> Void)?
    static func run(_ invocation: CodexCLI.Invocation) async throws -> CodexCLI.Envelope {
        precondition(invocation.toolsDisabled && !invocation.webSearch && !invocation.includeUserConfig)
        precondition(invocation.timeout == 30 && invocation.outputSchema != nil)
        calls += 1
        if cancel { throw CancellationError() }
        if fail { throw NSError(domain: "synthetic", code: 1) }
        after?()
        return .init(jsonResult: reply)
    }
}
func Log(_ message: String) {}
@main struct Test {
    static func main() async throws {
        let personal = HostedConnectorAccount(taskTarget: "hosted-a@1", service: "gmail", label: "Personal")
        let work = HostedConnectorAccount(taskTarget: "hosted-b@2", service: "gmail", label: "Work")
        let outlook = HostedConnectorAccount(taskTarget: "hosted-c@1", service: "outlook-mail", label: "Office")
        func allowed(_ command: String, _ accounts: [HostedConnectorAccount], _ targets: [String]) -> Set<String> {
            HostedConnectorAuthorization.allowedTargets(targets, command: command, accounts: accounts)
        }
        precondition(allowed("Send using Gmail", [personal], [personal.taskTarget]) == [personal.taskTarget])
        precondition(allowed("Send using Gmail", [personal, work], [personal.taskTarget]).isEmpty)
        precondition(allowed("Send using Work Gmail", [personal, work], [personal.taskTarget, work.taskTarget]) == [work.taskTarget])
        precondition(allowed("Send using Personal and Work Gmail", [personal, work], [personal.taskTarget, work.taskTarget]).isEmpty)
        precondition(allowed("Send email", [personal, outlook], [personal.taskTarget, outlook.taskTarget]).isEmpty)
        precondition(allowed("Send using Outlook", [personal, outlook], [personal.taskTarget, outlook.taskTarget]) == [outlook.taskTarget])
        precondition(allowed("Reply in Apple Mail", [personal], [personal.taskTarget]).isEmpty)
        precondition(allowed("Send this, not Gmail", [personal], [personal.taskTarget]).isEmpty)
        precondition(allowed("Send using Gmail", [personal], ["hosted-a@0", "unknown"]).isEmpty)
        HostedConnectorStore.records = [personal]
        FrontierRun.reply = #"{"targets":["hosted-a@1"]}"#
        try await HostedConnectorAuthorization.authorize("Send using Gmail")
        precondition(SidekickInteraction.current!.authorizedHostedWrites == [personal.taskTarget])
        FrontierRun.reply = #"{"targets":[]}"#
        try await HostedConnectorAuthorization.authorize("Summarize Gmail")
        precondition(SidekickInteraction.current!.authorizedHostedWrites.isEmpty)
        FrontierRun.reply = #"{"targets":["hosted-a@1"]}"#
        FrontierRun.after = { HostedConnectorStore.records = [] }
        try await HostedConnectorAuthorization.authorize("Send using Gmail")
        precondition(SidekickInteraction.current!.authorizedHostedWrites.isEmpty)
        FrontierRun.after = nil; HostedConnectorStore.records = [personal]
        FrontierRun.reply = "invalid"
        try await HostedConnectorAuthorization.authorize("Send using Gmail")
        precondition(SidekickInteraction.current!.authorizedHostedWrites.isEmpty)
        FrontierRun.fail = true
        try await HostedConnectorAuthorization.authorize("Send using Gmail")
        precondition(SidekickInteraction.current!.authorizedHostedWrites.isEmpty)
        FrontierRun.fail = false; FrontierRun.cancel = true
        do { try await HostedConnectorAuthorization.authorize("Send using Gmail"); preconditionFailure("Cancellation swallowed") }
        catch is CancellationError {}
        let before = FrontierRun.calls
        ModelBackend.current = .chatgpt
        try await HostedConnectorAuthorization.authorize("Send using Gmail")
        precondition(FrontierRun.calls == before)
        print("PASS hosted write scope: exact accounts, generation, ambiguity, read-only fallback, cancellation, backend isolation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-hosted-write-scope-") as directory:
    root = Path(directory)
    fixture = root / "Fixture.swift"
    fixture.write_text(FIXTURE)
    executable = root / "check"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(SOURCE), str(fixture), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
