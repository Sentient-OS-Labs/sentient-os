#!/usr/bin/env python3
"""Exercise explicit account teardown and connector consent with inert provider services."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'

def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

owner = (APP/'Views/Settings/ProviderAccountControls.swift').read_text().split('struct ProviderAccountControls:')[0].replace('import SwiftUI', 'import Foundation\nimport Observation')
forget = declaration((APP/'Cloud/ConnectorCensus.swift').read_text(), 'static func forgetAccount(').replace('UserDefaults.standard', 'Fixture.defaults')
fixture = r'''
import Foundation
import Observation
@MainActor enum Fixture {
    static let defaults = UserDefaults(suiteName: UUID().uuidString)!
    static var trace: [String] = []
    static var failLogout = false
}
enum ModelBackend: String { case chatgpt, claude, custom, sentient }
@MainActor enum CodexAuth { static func clearAccountPreferences() { Fixture.trace.append("clear-plan") } }
@MainActor class Conversation {
    var busy = false
    var maintenance = false
    func beginMaintenance() -> Bool { if busy { return false }; maintenance = true; return true }
    func endMaintenance() { maintenance = false }
    func drainBackgroundWork() async { Fixture.trace.append("drain-background") }
}
@MainActor class Run {
    let conversation = Conversation()
    var drains = true
    func stopAndDrain() async -> Bool { Fixture.trace.append("drain-task"); return drains }
}
@MainActor class Coordinator { let run = Run() }
@MainActor class Processing {
    var isBusy = false
    var suspended = false
    var pauses = 0
    func pause() { pauses += 1; Fixture.trace.append("pause") }
    func suspend() async { suspended = true; Fixture.trace.append("suspend") }
    func resumeMonitoring() { suspended = false; Fixture.trace.append("resume") }
}
@MainActor class Scheduler { func reevaluate() {} }
@MainActor class AppState {
    let commandCoordinator = Coordinator(), processing = Processing(), scheduler = Scheduler()
}
@MainActor final class CodexSetup {
    static let shared = CodexSetup()
    func signOut() async throws { Fixture.trace.append("logout-codex"); if Fixture.failLogout { throw ProviderAccountActions.AccountError.busy } }
}
@MainActor final class ClaudeSetup {
    static let shared = ClaudeSetup()
    func signOut() async throws { Fixture.trace.append("logout-claude") }
}
@MainActor enum DirectMCPStore { static func connection(_ slug: String) -> Bool? { slug == "notion" ? true : nil } }
@MainActor enum HostedConnectorStore { static func account(_ slug: String) -> Bool? { slug == "slack" ? true : nil } }
@MainActor enum ConnectorRegistry {
    static func setKBEnabled(_ slug: String, _ enabled: Bool) { Fixture.defaults.set(enabled, forKey: "mcp.\(slug).kb") }
    static func readGenerationKey(_ slug: String, _ origin: String) -> String { "generation.\(origin).\(slug)" }
}
@MainActor enum ConnectorCensus {
    struct DetectedConnector {
        let slug: String
        enum Origin: String {
            case chatgpt, claude
            init?(backend: ModelBackend) { guard let origin = Self(rawValue: backend.rawValue) else { return nil }; self = origin }
        }
    }
    static let dedicatedSourceSlugs: Set<String> = ["gmail", "google-calendar"]
    static func cached(for origin: DetectedConnector.Origin) -> [DetectedConnector] { [] }
    static func storageKey(for origin: DetectedConnector.Origin) -> String? { "cache.\(origin.rawValue)" }
    // FORGET
}
'''.replace('// FORGET', forget)
tests = r'''
@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1 }
        let d = Fixture.defaults
        for key in ["dbg.run.gmail", "dbg.gmail.connected", "dbg.run.calendar", "dbg.calendar.connected",
                    "dbg.run.whatsapp", "mcp.outlook.kb", "mcp.notion.kb", "mcp.slack.kb"] { d.set(true, forKey: key) }
        d.set(Data([1]), forKey: "cache.chatgpt")
        let state = AppState()
        let owner = ProviderAccountActions()
        try await owner.signOut(.chatgpt, appState: state)
        check(!d.bool(forKey: "dbg.run.gmail") && !d.bool(forKey: "dbg.calendar.connected"), "dedicated subscription sources require setup again")
        check(!d.bool(forKey: "mcp.outlook.kb"), "selected source resets even when inventory is missing")
        check(d.bool(forKey: "mcp.notion.kb") && d.bool(forKey: "mcp.slack.kb"), "independent connections keep consent")
        check(d.bool(forKey: "dbg.run.whatsapp"), "local source consent preserved")
        check(d.data(forKey: "cache.chatgpt") == nil, "old account cache removed")
        check(state.processing.pauses == 0, "idle schedule is not explicitly paused")
        check(!state.processing.suspended && !state.commandCoordinator.run.conversation.maintenance && !owner.changing, "maintenance always released")
        check(Fixture.trace.firstIndex(of: "logout-codex")! > Fixture.trace.firstIndex(of: "drain-background")!, "old work drains before logout")
        Fixture.trace = []; state.commandCoordinator.run.drains = false
        do { try await owner.signOut(.chatgpt, appState: state); fatalError("Expected drain failure") } catch {}
        check(!Fixture.trace.contains("logout-codex") && !owner.changing && !state.processing.suspended, "failed drain never logs out and leaves UI usable")
        state.commandCoordinator.run.drains = true; state.processing.isBusy = true; Fixture.failLogout = true
        do { try await owner.signOut(.chatgpt, appState: state); fatalError("Expected logout failure") } catch {}
        check(!owner.changing && !state.processing.suspended && state.processing.pauses == 1, "failed logout releases maintenance after pausing active work")
        Fixture.failLogout = false
        try await owner.signOut(.claude, appState: state)
        check(Fixture.trace.contains("logout-claude"), "Claude uses existing provider logout")
        print("PASS \(count) provider account-change assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-account-change-') as tmp:
    root = Path(tmp)
    (root/'Test.swift').write_text(fixture + owner.replace('UserDefaults.standard', 'Fixture.defaults') + tests)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', str(root/'Test.swift'), '-o', str(root/'test')], check=True)
    subprocess.run([str(root/'test')], check=True)
