#!/usr/bin/env python3
"""Real native-session subprocess failures, with an inert local RPC peer.

No helper, model, screenshot, permission or network access. Verifies that the
agent's next read can recover a dead transport without replaying a failed action.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
SUPPORT = r'''
import Foundation
import AppKit
nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture.native"
    struct Configuration: Sendable {
        let cliURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RPC_PEER"]!)
        let codexOverrides: [String] = []
        let clientEnvironment: [String: String]
        init(state: URL) {
            clientEnvironment = ProcessInfo.processInfo.environment.merging(["TEST_RPC_STATE": state.path]) { _, new in new }
        }
    }
}
actor LocalMCPServer {
    nonisolated struct Connection: Sendable {}
    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int,
         response: @escaping @Sendable (Data) async throws -> Data) {}
    func start() async throws -> Connection { Connection() }
    func stop() {}
}
nonisolated struct CaptureDiagnostics: Sendable {
    enum Source { case native, healthProbe }
    enum Outcome { case started, passed, failed, recovered, cancelled, skipped }
    init(source: Source, context: CaptureDiagnostics? = nil) {}
    @MainActor static func environment(target: NSRunningApplication? = nil) -> [String: String] { [:] }
    func record(_ outcome: Outcome, attempt: Int = 1, failure: NativeComputerUseFailure? = nil, fields: [String: String] = [:]) {}
}
'''
SUPPORT += r'''
nonisolated enum ModelBackend: Sendable { case chatgpt; static let current = ModelBackend.chatgpt }

nonisolated final class SidekickInteraction: Sendable {
    static let current: SidekickInteraction? = nil
    let computerUseCheckConsent = ComputerUseDiagnosticConsent()
}
nonisolated enum Permissions {
    enum TCCState { case granted, denied, notAsked, unavailable }
    enum AutomationState { case granted, denied, notAsked, unavailable }
    static func nativeAutomationState(ask: Bool) async -> AutomationState { .granted }
    static func hasScreenRecording() -> Bool { true }
    static func tccState(service: String, clientBundleID: String) -> TCCState { .granted }
}

@MainActor final class ComputerUseDoctor {
    static let shared = ComputerUseDoctor()
    func checkFromAgent(authorization: ComputerUseDiagnosticAuthorization, backend: ModelBackend, call: @escaping @Sendable (String, Data) async throws -> Data) async throws -> Data {
        fatalError("A normal failed tool must never automatically trigger diagnostics")
    }
}
'''
PEER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
p = pathlib.Path(os.environ['TEST_RPC_STATE'])
state = json.loads(p.read_text()) if p.exists() else {'opens': 0, 'calls': [], 'effects': 0, 'pids': []}
state['opens'] += 1
state['pids'].append(os.getpid())
def save(): p.write_text(json.dumps(state))
save()
names = ['list_apps', 'get_app_state', 'click', 'perform_secondary_action', 'set_value', 'select_text', 'scroll', 'drag', 'press_key', 'type_text']
for line in sys.stdin:
    req = json.loads(line)
    if 'id' not in req: continue
    method = req['method']
    if method == 'initialize':
        if state.get('hang_start') and state['opens'] > 1: time.sleep(30)
        result = {}
    elif method == 'thread/start': result = {'thread': {'id': 'fixture-' + str(state['opens'])}}
    elif method == 'mcpServerStatus/list': result = {'data': [{'name': 'sentient_native', 'tools': {n: {'name': n} for n in names}}]}
    elif method == 'mcpServer/tool/call':
        tool, args = req['params']['tool'], req['params']['arguments']
        scenario = args.get('scenario', '')
        state['calls'].append(tool)
        if tool == 'type_text': state['effects'] += 1
        if scenario in ['drop_read', 'drop_action', 'hang_reconnect'] and not state.get('dropped'):
            state['dropped'] = True
            state['hang_start'] = scenario == 'hang_reconnect'
            save(); sys.exit(23)
        save()
        result = {'content': [{'type': 'text', 'text': 'Synthetic app state; generation ' + str(state['opens'])}]}
        if scenario == 'tool_error': result = {'isError': True, 'content': [{'type': 'text', 'text': 'Element is not settable'}]}
    else: raise AssertionError(method)
    # Nullable protocol members must not turn a successful reply into a failure.
    print(json.dumps({'id': req['id'], 'result': result, 'error': None}), flush=True)
'''
TESTS = r'''
import Foundation
import Darwin
@main struct Tests {
    static var checks = 0
    static func check(_ value: Bool, _ description: String) {
        guard value else { fatalError(description) }; checks += 1
    }
    static func rpc(_ id: Int, _ tool: String = "get_app_state", _ scenario: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": tool, "arguments": ["app": "fixture", "scenario": scenario]]])
    }
    static func result(_ data: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: data) as! [String: Any])["result"] as! [String: Any]
    }
    static func state(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    static func open(_ name: String) async throws -> (NativeComputerUseServer, URL) {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RPC_STATE_DIR"]!).appendingPathComponent(name + ".json")
        let server = NativeComputerUseServer(configuration: .init(state: url), resolveTarget: { _ in "fixture" })
        _ = try await server.start()
        return (server, url)
    }
    static func main() async throws {
        do {
            let (server, url) = try await open("read")
            let failed = try await server.respond(rpc(1, "get_app_state", "drop_read"))
            check(NativeComputerUseFailure.isError(try result(failed)), "Disconnected read reaches the agent as a tool error")
            let fresh = try await server.respond(rpc(2))
            check(!NativeComputerUseFailure.isError(try result(fresh)), "Agent's next read must reopen the dead transport")
            check(try state(url)["opens"] as? Int == 2, "Exactly one replacement session opened")
            await server.stop()
        }
        do {
            let (server, url) = try await open("action")
            _ = try await server.respond(rpc(1))
            let action = try rpc(2, "type_text", "drop_action")
            let failed = try await server.respond(action)
            check(NativeComputerUseFailure.isError(try result(failed)), "Unconfirmed action returns an error")
            let cached = try await server.respond(action)
            check(cached == failed, "Duplicate request returns its original error")
            _ = try await server.respond(rpc(3, "type_text"))
            check(try state(url)["effects"] as? Int == 1, "Neither retrying an ID nor another action replays the unconfirmed change")
            let fresh = try await server.respond(rpc(4))
            check(!NativeComputerUseFailure.isError(try result(fresh)), "Fresh state recovers after uncertain action")
            let next = try await server.respond(rpc(5, "type_text"))
            check(!NativeComputerUseFailure.isError(try result(next)), "Agent can decide to act after a fresh read")
            check(try state(url)["effects"] as? Int == 2, "Only the agent's explicitly requested actions ran")
            await server.stop()
        }
        do {
            let (server, url) = try await open("ordinary-error")
            _ = try await server.respond(rpc(1))
            _ = try await server.respond(rpc(2, "set_value", "tool_error"))
            let fresh = try await server.respond(rpc(3))
            check(!NativeComputerUseFailure.isError(try result(fresh)), "Ordinary tool failure stays recoverable")
            check(try state(url)["opens"] as? Int == 1, "Ordinary tool errors do not restart healthy sessions")
            await server.stop()
        }
        do {
            let (server, url) = try await open("long-task")
            for id in 1...1030 {
                let response = try await server.respond(rpc(id, "list_apps"))
                check(!NativeComputerUseFailure.isError(try result(response)), "Long tasks cannot become permanently blocked at request 1024")
            }
            let old = try await server.respond(rpc(1, "list_apps"))
            check(NativeComputerUseFailure.isError(try result(old)), "Evicted request IDs remain consumed, not replayed")
            check(try (state(url)["calls"] as? [String])?.count == 1030, "No hidden duplicate request was executed")
            await server.stop()
        }
        do {
            let (server, url) = try await open("cancel-reconnect")
            _ = try await server.respond(rpc(1, "get_app_state", "hang_reconnect"))
            let read = Task { try await server.respond(rpc(2)) }
            for _ in 0..<100 {
                if try state(url)["opens"] as? Int == 2 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(try state(url)["opens"] as? Int == 2, "Recovery actually began before Stop")
            let began = Date()
            await server.stop(); read.cancel()
            do { _ = try await read.value; fatalError("Stopped reconnect returned a response") } catch is CancellationError { checks += 1 }
            check(Date().timeIntervalSince(began) < 4, "Stop cancels and drains session recovery promptly")
            let pids = try state(url)["pids"] as! [Int32]
            check(pids.allSatisfy { kill($0, 0) != 0 }, "No recovered session process survives Stop")
        }
        print("PASS \(checks) real-process native session recovery assertions")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-native-session-recovery-") as directory:
    root = Path(directory)
    (root / "Support.swift").write_text(SUPPORT)
    (root / "Tests.swift").write_text(TESTS)
    peer = root / "peer"
    peer.write_text(PEER)
    peer.chmod(0o700)
    executable = root / "tests"
    env = dict(os.environ, TEST_RPC_PEER=str(peer), TEST_RPC_STATE_DIR=str(root))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-target",
                    f"{platform.machine()}-apple-macos15.0", str(root / "Support.swift"), str(root / "Tests.swift"),
                    *[str(APP / p) for p in ["Diagnostics/NativeComputerUseFailure.swift",
                        "Diagnostics/ComputerUseDiagnosticConsent.swift", "Diagnostics/ComputerUseDiagnosticPolicy.swift",
                        "Driver/NativeAppStateRetry.swift", "Driver/OpenAIComputerUseProbe.swift",
                        "Driver/OpenAIComputerUseSession.swift", "Driver/NativeComputerUseServer.swift"]],
                    "-o", str(executable)], check=True, env=env, timeout=60)
    subprocess.run([str(executable)], check=True, env=env, timeout=45)
