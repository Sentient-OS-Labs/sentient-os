#!/usr/bin/env python3
"""Production broker/eligibility/consent with inert native transport and no UI or network."""
from pathlib import Path
import platform
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
SUPPORT = r'''
import Foundation
import AppKit
nonisolated enum ModelBackend: Sendable { case chatgpt; static let current = ModelBackend.chatgpt }
nonisolated final class SidekickInteraction: Sendable {
    static let current: SidekickInteraction? = nil
    let computerUseCheckConsent = ComputerUseDiagnosticConsent()
}
nonisolated enum Permissions {
    enum TCCState { case granted, denied, notAsked, unavailable }
    enum AutomationState { case granted, denied, notAsked, unavailable }
    nonisolated(unsafe) static var screen = true
    nonisolated(unsafe) static var tcc = TCCState.granted
    nonisolated(unsafe) static var automation = AutomationState.granted
    static func hasScreenRecording() -> Bool { screen }
    static func tccState(service: String, clientBundleID: String) -> TCCState { tcc }
    static func nativeAutomationState(ask: Bool) async -> AutomationState { precondition(!ask); return automation }
}
nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture.native"
    struct Configuration: Sendable { let script: Script }
}
actor Script {
    var failure: NativeComputerUseFailure? = .init(kind: .connection, code: nil, detail: .unexpectedEOF, stage: .appState)
    var closes = 0
    var reads = 0
    func set(_ value: NativeComputerUseFailure?) { failure = value }
    func close() { closes += 1 }
    func invoke() throws -> Data {
        reads += 1
        if let failure { throw failure }
        return try JSONSerialization.data(withJSONObject: ["content": [["type":"text","text":"Usable synthetic app state"]]])
    }
}
actor OpenAIComputerUseSession {
    let script: Script
    init(script: Script) { self.script = script }
    static func open(_ config: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession { .init(script: config.script) }
    func catalog() throws -> Data {
        let names = ["list_apps","get_app_state","click","perform_secondary_action","set_value","select_text","scroll","drag","press_key","type_text"]
        return try JSONSerialization.data(withJSONObject:["data":[["name":"sentient_native","tools":Dictionary(uniqueKeysWithValues:names.map {($0,["name":$0])})]]])
    }
    func call(_ name: String, arguments: Data, timeout: TimeInterval = 125) async throws -> Data { try await script.invoke() }
    func close() async { await script.close() }
    func isUsable() -> Bool { true }
}
actor LocalMCPServer {
    nonisolated struct Connection: Sendable {}
    init(name: String, tools: [String], timeout: TimeInterval, maximumBody: Int,
         response: @escaping @Sendable (Data) async throws -> Data) {}
    func start() async throws -> Connection { .init() }
    func stop() {}
}
nonisolated struct CaptureDiagnostics: Sendable {
    enum Source { case native, healthProbe }; enum Outcome { case started, passed, failed, recovered, cancelled, skipped }
    init(source: Source, context: CaptureDiagnostics? = nil) {}
    @MainActor static func environment(target: NSRunningApplication? = nil) -> [String:String] { [:] }
    func record(_ value: Outcome, attempt: Int = 1, failure: NativeComputerUseFailure? = nil, fields: [String:String] = [:]) {}
}
@MainActor final class ComputerUseDoctor {
    static let shared = ComputerUseDoctor()
    var started = 0
    func checkFromAgent(authorization: ComputerUseDiagnosticAuthorization, backend: ModelBackend,
                       call: @escaping @Sendable (String, Data) async throws -> Data) async throws -> Data {
        started += 1
        return Data("{\"outcome\":\"passed\"}".utf8)
    }
}
'''
TESTS = r'''
import Foundation
@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static var next = 0
    @MainActor static func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    @MainActor static func invoke(_ server: NativeComputerUseServer, _ tool: String, args: [String:Any] = [:]) async throws -> Data {
        next += 1
        return try await server.respond(JSONSerialization.data(withJSONObject:["id":next,"method":"tools/call","params":["name":tool,"arguments":args]]))
    }
    static func status(_ data: Data) throws -> [String:Any] {
        let rpc = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let result = rpc["result"] as! [String:Any]
        let content = result["content"] as! [[String:Any]]
        return try JSONSerialization.jsonObject(with:Data((content[0]["text"] as! String).utf8)) as! [String:Any]
    }
    @MainActor static func server(_ interaction: SidekickInteraction? = .init()) async throws -> (NativeComputerUseServer, Script, SidekickInteraction?) {
        let script = Script()
        let server = NativeComputerUseServer(configuration:.init(script:script), interaction:interaction, resolveTarget:{$0})
        _ = try await server.start()
        return (server,script,interaction)
    }
    @MainActor static func fail(_ server: NativeComputerUseServer, apps: [String]) async throws {
        for app in apps { _ = try await invoke(server,"get_app_state",args:["app":app]) }
    }
    @MainActor static func main() async throws {
        for apps in [Array(repeating:"com.apple.Safari",count:5),
                     ["com.apple.Safari","com.google.Chrome","com.microsoft.edgemac","com.google.Chrome"],
                     Array(repeating:"com.microsoft.Word",count:4)] {
            let (s,script,_) = try await server()
            try await fail(s,apps:apps)
            let reply = try status(await invoke(s,"diagnose_computer_use"))
            check(reply["status"] as? String == "not_needed","One app or browser-only failures never offer diagnostics")
            check(await script.closes == 0,"Ineligible check does not reset the connection")
            await s.stop()
        }
        for detail in [NativeComputerUseFailure.Detail.focusChanged,.inputInterrupted,.staleState,.chromiumAppChanged,.noWindowsAvailable,.permissionDenied] {
            let (s,script,_) = try await server()
            await script.set(.init(kind: detail == .permissionDenied ? .permission : .unknown, code:nil,detail:detail))
            try await fail(s,apps:["com.apple.TextEdit","com.apple.finder","com.apple.TextEdit"])
            check(try status(await invoke(s,"diagnose_computer_use"))["status"] as? String == "not_needed","Ordinary interruptions and known permissions never qualify")
            await s.stop()
        }
        for permission in ["screen", "accessibility", "automation", "unknown-tcc", "unknown-automation"] {
            let (s,script,_) = try await server()
            for _ in 0..<3 { _ = try await invoke(s,"list_apps") }
            Permissions.screen = permission != "screen"
            Permissions.tcc = permission == "accessibility" ? .denied : permission == "unknown-tcc" ? .unavailable : .granted
            Permissions.automation = permission == "automation" ? .denied : permission == "unknown-automation" ? .unavailable : .granted
            let reply = try status(await invoke(s,"diagnose_computer_use"))
            check(reply["status"] as? String == (permission.hasPrefix("unknown") ? "permission_unverified" : "permission_needed"),
                  "Missing or unverified grants suppress diagnostics even after broad failures")
            check(await script.closes == 0 && ComputerUseDoctor.shared.started == 0,
                  "Permission guidance never resets the connection or starts a diagnostic")
            Permissions.screen = true; Permissions.tcc = .granted; Permissions.automation = .granted
            await s.stop()
        }
        do {
            let script = Script()
            let s = NativeComputerUseServer(configuration:.init(script:script), interaction:.init(), resolveTarget:{ _ in "one-canonical-app" })
            _ = try await s.start()
            try await fail(s,apps:["com.example.One","/Applications/One.app","One"])
            check(try status(await invoke(s,"diagnose_computer_use"))["status"] as? String == "not_needed",
                  "Different selectors for the same app cannot fabricate a multi-app failure")
            await s.stop()
        }
        do {
            let (s,script,interaction) = try await server()
            try await fail(s,apps:["com.apple.TextEdit","com.apple.finder","com.apple.TextEdit"])
            let request = try status(await invoke(s,"diagnose_computer_use"))
            check(request["status"] as? String == "needs_confirmation","Broad outage first returns a consent request")
            let id = UUID(uuidString:request["approval_id"] as! String)!
            check(await script.closes == 0 && ComputerUseDoctor.shared.started == 0,"No reset or window before consent")
            check(try status(await invoke(s,"diagnose_computer_use",args:["approval_id":id.uuidString]))["status"] as? String == "not_approved","Model-provided ID is not approval")
            interaction!.computerUseCheckConsent.recordAnswer(id:id,selectedAnswer:1,text:"Not now")
            check(try status(await invoke(s,"diagnose_computer_use",args:["approval_id":id.uuidString]))["status"] as? String == "not_approved","Decline cannot authorize the check")
            check(try status(await invoke(s,"diagnose_computer_use"))["status"] as? String == "already_offered","Decline suppresses repeated offers for this task")
            check(await script.closes == 0,"Decline preserves connection")
            await script.set(nil)
            _ = try await invoke(s,"get_app_state",args:["app":"com.apple.TextEdit"])
            check(await script.reads == 4,"The original task still uses its tools after decline")
            await s.stop()
        }
        do {
            let (s,script,interaction) = try await server()
            for _ in 0..<3 { _ = try await invoke(s,"list_apps") }
            let request = try status(await invoke(s,"diagnose_computer_use"))
            let id = UUID(uuidString:request["approval_id"] as! String)!
            interaction!.computerUseCheckConsent.recordAnswer(id:id,selectedAnswer:0,text:"Run check")
            _ = try await invoke(s,"diagnose_computer_use",args:["approval_id":id.uuidString])
            check(await script.closes == 1 && ComputerUseDoctor.shared.started == 1,"Only actual approval permits reset and check")
            _ = try await invoke(s,"diagnose_computer_use",args:["approval_id":id.uuidString])
            check(ComputerUseDoctor.shared.started == 1,"Approval is single-use")
            await s.stop()
        }
        do {
            let (s,script,interaction) = try await server()
            for _ in 0..<3 { _ = try await invoke(s,"list_apps") }
            let request = try status(await invoke(s,"diagnose_computer_use"))
            let id = UUID(uuidString:request["approval_id"] as! String)!
            interaction!.computerUseCheckConsent.recordAnswer(id:id,selectedAnswer:0,text:"Run check")
            await script.set(nil)
            _ = try await invoke(s,"get_app_state",args:["app":"com.apple.TextEdit"])
            check(try status(await invoke(s,"diagnose_computer_use",args:["approval_id":id.uuidString]))["status"] as? String == "not_needed","Recovered UI cancels an unnecessary approved check")
            check(await script.closes == 0,"Recovery avoids resetting a now-working connection")
            await s.stop()
        }
        do {
            let (s,_,_) = try await server(nil)
            for _ in 0..<3 { _ = try await invoke(s,"list_apps") }
            check(try status(await invoke(s,"diagnose_computer_use"))["status"] as? String == "approval_unavailable","Headless runs cannot invent consent or create a popup")
            await s.stop()
        }
        for answer in ["later", "maybe", "yes, later", "don't run check", ""] {
            let store = ComputerUseDiagnosticConsent(), owner = UUID()
            let request = store.request(owner:owner)!
            store.recordAnswer(id:request.id,selectedAnswer:nil,text:answer)
            check(store.consume(id:request.id,owner:owner) == nil,"Ambiguous, negative or delayed replies are not consent")
            check(store.request(owner:owner) == nil,"No repeat consent question after a decline")
        }
        let store = ComputerUseDiagnosticConsent(), owner = UUID()
        let request = store.request(owner:owner)!
        store.recordAnswer(id:request.id,selectedAnswer:0,text:"Run check")
        check(store.consume(id:request.id,owner:UUID()) == nil,"Approval cannot cross runs")
        check(store.consume(id:request.id,owner:owner) != nil,"Correct run consumes approval")
        check(store.consume(id:request.id,owner:owner) == nil,"Consumed approval cannot replay")
        print("PASS \(checks) diagnostic eligibility, consent and no-side-effect checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-diagnostic-consent-') as directory:
    p = Path(directory)
    (p/'Support.swift').write_text(SUPPORT)
    (p/'Tests.swift').write_text(TESTS)
    files = ['Diagnostics/NativeComputerUseFailure.swift','Diagnostics/ComputerUseDiagnosticConsent.swift',
             'Diagnostics/ComputerUseDiagnosticPolicy.swift','Driver/NativeAppStateRetry.swift',
             'Driver/OpenAIComputerUseProbe.swift','Driver/NativeComputerUseServer.swift']
    binary = p/'tests'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',
                    str(p/'Support.swift'),str(p/'Tests.swift'),*[str(APP/f) for f in files],'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=30)
