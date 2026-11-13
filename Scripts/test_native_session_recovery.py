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
nonisolated enum NativeComputerUseErrorLog { static func record(tool: String, failure: NativeComputerUseFailure) {} }

import Foundation
import AppKit
nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture.native"
    struct Configuration: Sendable {
        var appURL: URL {URL(fileURLWithPath:"/fixture-helper.app")}

        let cliURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RPC_PEER"]!)
        let codexOverrides: [String] = []
        let clientEnvironment: [String: String]
        init(state: URL) {
            clientEnvironment = ProcessInfo.processInfo.environment.merging(["TEST_RPC_STATE": state.path]) { _, new in new }
        }
    }
}
actor LocalMCPServer {
    nonisolated struct Connection: Sendable { let timeout: TimeInterval }
    private let timeout: TimeInterval
    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int,
         response: @escaping @Sendable (Data) async throws -> Data) { self.timeout = timeout }
    func start() async throws -> Connection { Connection(timeout: timeout) }
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
@MainActor final class NativePermissionSetup {
    var canAttemptTask = false
    static let shared = NativePermissionSetup()
    var recoveryNeeded = false
    var recovered = 0
    private var generation = UUID()
    func permissionFailed() -> UUID { generation = UUID(); recoveryNeeded = true; return generation }
    func recovered(ifCurrent token: UUID) { if token == generation { recoveryNeeded = false; recovered += 1 } }
}

nonisolated enum ModelBackend: Sendable { case chatgpt; static let current = ModelBackend.chatgpt }

nonisolated final class SidekickInteraction: Sendable {
    let onWorkWindow: (@MainActor @Sendable (SidekickWorkWindow?) -> Void)? = nil
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
SUPPORT += r'''
@MainActor final class NativePermissionCheck {
    static let shared = NativePermissionCheck()
    var isTearingDown = false
    var snapshot = NativePermissionReadiness.Snapshot(accessibility: .verified, screenRecording: .verified)
    var invalidations = 0
    func refresh() {}
    func invalidate(failure: NativeComputerUseFailure? = nil) {
        invalidations += 1; snapshot = NativePermissionReadiness.afterFailure(failure)
    }
}
'''
PEER = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time, struct, zlib, base64
p = pathlib.Path(os.environ['TEST_RPC_STATE'])
state = json.loads(p.read_text()) if p.exists() else {'opens': 0, 'calls': [], 'effects': 0, 'pids': []}
state['native_tool_timeout'] = [a for a in sys.argv if a.startswith('mcp_servers.sentient_native.tool_timeout_sec=')][-1]
state['opens'] += 1
state['pids'].append(os.getpid())
def save():
    temporary = p.with_name(p.name + f'.{os.getpid()}.tmp')
    temporary.write_text(json.dumps(state))
    temporary.replace(p)
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
        if scenario == 'permission_late': time.sleep(0.25)
        if scenario == 'slow_read': time.sleep(0.4)
        state['calls'].append(tool)
        if tool == 'type_text': state['effects'] += 1
        if scenario in ['drop_read', 'drop_action', 'hang_reconnect'] and not state.get('dropped'):
            state['dropped'] = True
            state['hang_start'] = scenario == 'hang_reconnect'
            save(); sys.exit(23)
        if scenario.startswith('permission'): state['permission_scenario'] = scenario
        save()
        result = {'content': [{'type': 'text', 'text': 'Synthetic app state; generation ' + str(state['opens'])}]}
        if scenario == 'native_capture': result = {'isError':True,'content':[{'type':'text','text':'Computer Use server error -10005: Error Domain=SCStreamErrorDomain Code=-3811 capture failed'}]}
        if scenario == 'tool_error': result = {'isError': True, 'content': [{'type': 'text', 'text': 'Element is not settable'}]}
        if scenario.startswith('permission'):
            result = {'isError':True,'content':[{'type':'text','text':'Computer Use server error -10009: permissionsNotGranted'}]}
        if set(args) == {'app'} and args.get('app') != 'fixture':
            state['setup_calls'] = state.get('setup_calls',0)+1;save()
            if state.get('permission_scenario') == 'permission_hang':time.sleep(30)
            if state.get('permission_scenario') == 'permission_late': time.sleep(0.5)
            if state.get('permission_scenario') == 'permission_slow_setup': time.sleep(0.6)
            def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
            png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0\xff\0\0\xff'))+chunk(b'IEND',b'')
            result={'content':[{'type':'text','text':'Synthetic settings state'},{'type':'image','data':base64.b64encode(png).decode()}]}
            if state.get('permission_scenario') == 'permission_dismissed':
                result={'isError':True,'content':[{'type':'text','text':'Computer Use server error -10014: permissionsPending'}]}
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
    static func open(_ name: String, requestTimeout: TimeInterval = 120, setupTimeout: TimeInterval = 300) async throws -> (NativeComputerUseServer, URL) {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_RPC_STATE_DIR"]!).appendingPathComponent(name + ".json")
        let server = NativeComputerUseServer(configuration: .init(state: url), requestTimeout: requestTimeout, permissionSetupTimeout: setupTimeout, resolveTarget: { _ in "fixture" })
        let connection = try await server.start()
        check(connection.timeout >= requestTimeout + setupTimeout + 10, "Outer MCP timeout covers both phases")
        check(try state(url)["native_tool_timeout"] as? String == "mcp_servers.sentient_native.tool_timeout_sec=310", "Inner MCP timeout cannot cut off permission setup")
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
            let (server, url) = try await open("native-capture-live-client")
            let first = try await server.respond(rpc(1, "get_app_state", "native_capture"))
            check(NativeComputerUseFailure.isError(try result(first)), "Live RPC native capture failure remains an error")
            check(try state(url)["opens"] as? Int == 1, "Error result does not secretly retry")
            let next = try await server.respond(rpc(2))
            check(!NativeComputerUseFailure.isError(try result(next)), "Next explicit read can recover a live but failing native client")
            check(try state(url)["opens"] as? Int == 2, "Failing client was actually replaced")
            check(try (state(url)["calls"] as? [String]) == ["get_app_state", "get_app_state"], "Session replacement injects no tool actions")
            await server.stop()
            check(try (state(url)["pids"] as! [Int32]).allSatisfy { kill($0, 0) != 0 }, "Recovered sessions are drained on Stop")
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
        do {
            let (server,url) = try await open("permission-action")
            _ = try await server.respond(rpc(1))
            let failed = try await server.respond(rpc(2,"type_text","permission_action"))
            check(NativeComputerUseFailure.isError(try result(failed)),"Recovery never turns failed action into success")
            check(try state(url)["effects"] as? Int == 1,"Action is not replayed after permission setup")
            check(try state(url)["setup_calls"] as? Int == 1,"Confirmed permission denial opens helper setup once")
            check(await MainActor.run { !NativePermissionSetup.shared.recoveryNeeded },"Valid helper response finishes recovery")
            _ = try await server.respond(rpc(3,"get_app_state","permission_action"))
            check(try state(url)["setup_calls"] as? Int == 1,"Repeated denial cannot loop helper windows in one task")
            check(await MainActor.run { NativePermissionSetup.shared.recoveryNeeded },"Repeated denial keeps manual recovery available")
            await server.stop()
        }
        do {
            let (server,url) = try await open("permission-dismissed")
            let failed = try await server.respond(rpc(1,"get_app_state","permission_dismissed"))
            check(NativeComputerUseFailure.isError(try result(failed)),"Dismissed setup preserves original error")
            check(await MainActor.run { NativePermissionSetup.shared.recoveryNeeded },"Dismissed setup never confirms grants")
            check(try state(url)["setup_calls"] as? Int == 1,"No automatic loop after dismissed setup")
            await server.stop()
        }
        do {
            let (server,url) = try await open("permission-late", requestTimeout: 0.4, setupTimeout: 1)
            let action = try rpc(1,"type_text","permission_late")
            let began = Date()
            let failed = try await server.respond(action)
            check(Date().timeIntervalSince(began) > 0.7, "Setup can finish after the ordinary action budget expires")
            check(NativeComputerUseFailure.isError(try result(failed)), "Setup success preserves original failed action result")
            check(try state(url)["setup_calls"] as? Int == 1, "Late permission failure still opens setup")
            check(await MainActor.run { !NativePermissionSetup.shared.recoveryNeeded }, "Setup with its own budget completes recovery")
            check(try state(url)["effects"] as? Int == 1, "Late failed action is never replayed")
            check(try await server.respond(action) == failed, "Duplicate returns original result after setup")
            check(try state(url)["effects"] as? Int == 1, "Duplicate cannot repeat the action")
            await server.stop()
        }
        do {
            let (server,url) = try await open("permission-budget", requestTimeout: 0.4, setupTimeout: 0.12)
            let failed = try await server.respond(rpc(1,"get_app_state","permission_slow_setup"))
            check(NativeComputerUseFailure.isError(try result(failed)), "Setup timeout preserves original permission error")
            check(try state(url)["setup_calls"] as? Int == 1, "Timed-out setup was attempted once")
            check(await MainActor.run { NativePermissionSetup.shared.recoveryNeeded }, "Timed-out setup cannot claim success")
            await server.stop()
            let pids = try state(url)["pids"] as! [Int32]
            check(pids.allSatisfy { kill($0,0) != 0 }, "Timed-out setup leaves no session child alive")
        }
        do {
            let (server,url) = try await open("ordinary-deadline", requestTimeout: 0.1, setupTimeout: 1)
            let began = Date()
            let failed = try await server.respond(rpc(1,"get_app_state","slow_read"))
            check(NativeComputerUseFailure.isError(try result(failed)), "Ordinary slow read still times out")
            check(Date().timeIntervalSince(began) < 0.3, "Permission allowance does not extend ordinary native actions")
            check(try state(url)["setup_calls"] == nil, "Ordinary timeout does not trigger permission UI")
            await server.stop()
        }
        do {
            let (server,url) = try await open("permission-stop")
            let pending = Task {try await server.respond(rpc(1,"get_app_state","permission_hang"))}
            for _ in 0..<100 {
                if try state(url)["setup_calls"] as? Int == 1 {break}
                try await Task.sleep(for:.milliseconds(20))
            }
            check(try state(url)["setup_calls"] as? Int == 1,"Stop is tested while helper setup is pending")
            let began=Date()
            await server.stop();pending.cancel()
            do {_ = try await pending.value;fatalError("Stopped permission setup returned success")}
            catch is CancellationError {checks+=1}
            check(Date().timeIntervalSince(began)<4,"Stop cancels helper setup promptly")
            check(await MainActor.run { NativePermissionSetup.shared.recoveryNeeded },"Stopped setup cannot mark permissions ready")
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
                        "Driver/OpenAIComputerUseProbe.swift", "Driver/NativePermissionReadiness.swift",
                        "Driver/OpenAIComputerUseSession.swift", "Driver/NativeComputerUseServer.swift", "Notch Magic/SidekickWorkWindow.swift"]],
                    str(APP.parent / "Scripts/Fixtures/NativeHelperPermissionNoteStub.swift"), "-o", str(executable)], check=True, env=env, timeout=60)
    subprocess.run([str(executable)], check=True, env=env, timeout=45)
