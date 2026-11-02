#!/usr/bin/env python3
"""Exercise the production hosted connector setup coordinator with isolated fixtures.

Compiles the actual Swift coordinator with in-memory preference/census storage and
controlled provider jobs. No account, network, model, keychain, or app state is used.
Run on macOS with Xcode command line tools: python3 Scripts/test_hosted_connector_setup.py
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sentient OS macOS/Cloud/HostedConnectorSetup.swift"

FIXTURE = r'''
import Foundation

nonisolated enum ModelBackend: String, Sendable {
    case chatgpt, claude, custom, sentient
    var hasSubscriptionConnectors: Bool { self == .chatgpt || self == .claude }
    @TaskLocal static var runOverride: ModelBackend?
    nonisolated(unsafe) static var selected: ModelBackend = .claude
    static var current: ModelBackend { runOverride ?? selected }
}
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func set(_ value: Int, forKey key: String) { values[key] = value }
    func set(_ value: String, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func string(forKey key: String) -> String? { values[key] as? String }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
@MainActor enum ConnectorCensus {
    static var declarations: [(String, ModelBackend, Bool)] = []
    static func confirmSelection(slug: String, reconnected: Bool) {
        declarations.append((slug, ModelBackend.current, reconnected))
    }
}
@MainActor enum ConnectorRegistry {
    struct Server { let claudeServerURL: String? }
    static func canonicalSlug(_ slug: String) -> String { slug == "outlook-email" ? "outlook-mail" : slug }
    static func kbEligible(_ slug: String, backend: ModelBackend) -> Bool { slug == "google-drive" || slug == "outlook-mail" }
    static func setKBEnabled(_ slug: String, _ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: "mcp.\(slug).kb") }
    static func isKBEnabled(_ slug: String) -> Bool { UserDefaults.standard.bool(forKey: "mcp.\(slug).kb") }
    static func readGenerationKey(_ slug: String, _ origin: String) -> String { "mcp.\(slug).readGeneration.\(origin)" }
    static func server(for slug: String) -> Server? { slug == "unknown" ? nil : .init(claudeServerURL: "https://example.invalid") }
}
nonisolated enum OutlookMailConnector { static func isMail(_ slug: String) -> Bool { slug == "outlook-mail" } }
nonisolated enum MailAccount {
    enum Engine: String, Sendable { case chatgpt, claude }
    enum Provider: String, Sendable { case gmail, outlook }
}
nonisolated enum CodexCLI {
    struct Invocation: Sendable {
        enum Model: Sendable { case gpt6luna }
        enum Effort: Sendable { case low }
        enum Sandbox: Sendable { case readOnly }
        let prompt: String
        var feature = ""
        var model: Model = .gpt6luna
        var effort: Effort = .low
        var sandbox: Sandbox = .readOnly
        var webSearch = true
        var timeout: Double = 0
        var cwd: String?
        var mcpAttachServer: String?
        var connectorOnlyRead = false
        var includeUserConfig = true
        var toolsDisabled = false
    }
}
nonisolated enum CodexTrigger: Sendable { case probe; @TaskLocal static var current: CodexTrigger? }
enum FixtureFailure: Error { case expected, assertion(String) }
@MainActor enum Fixture {
    static var blocked = false
    static var contactBlocked = false
    static var failWarm = false
    static var failCollect = false
    static var collectionOutcome = MailAccountCollection.Outcome.saved
    static var calls: [(ModelBackend, CodexCLI.Invocation)] = []
    static var contacts: [(MailAccount.Engine, MailAccount.Provider, ModelBackend)] = []
    static var contactCompletions = 0
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) throws {
        if !condition { throw FixtureFailure.assertion(name) }
        passed += 1; print("PASS: \(name)")
    }
    static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureFailure.assertion("fixture timeout")
    }
    static func reset() async {
        await HostedConnectorSetup.beginTeardown(); HostedConnectorSetup.endTeardown()
        blocked = false; contactBlocked = false; failWarm = false; failCollect = false
        collectionOutcome = .saved; contactCompletions = 0
        calls = []; contacts = []; ConnectorCensus.declarations = []; UserDefaults.standard.values = [:]
        ModelBackend.selected = .claude
    }
    static func pending(_ backend: ModelBackend = .claude, _ provider: MailAccount.Provider = .gmail) -> String? {
        UserDefaults.standard.string(forKey: "connectedEmail.pendingCollection.\(backend.rawValue).\(provider.rawValue)")
    }
    static func settle() async throws { try await Task.sleep(for: .milliseconds(35)) }
}
@MainActor enum FrontierRun {
    static func run(_ invocation: CodexCLI.Invocation) async throws -> Int {
        Fixture.calls.append((ModelBackend.current, invocation))
        while Fixture.blocked { try await Task.sleep(for: .milliseconds(10)) }
        if Fixture.failWarm { throw FixtureFailure.expected }
        return 0
    }
}
@MainActor enum MailAccountCollection {
    enum Outcome { case noConnection, noAddress, saved, pending }
    static func collect(engine: MailAccount.Engine, provider: MailAccount.Provider) async throws -> Outcome {
        Fixture.contacts.append((engine, provider, ModelBackend.current))
        defer { Fixture.contactCompletions += 1 }
        while Fixture.contactBlocked { try await Task.sleep(for: .milliseconds(10)) }
        if Fixture.failCollect { throw FixtureFailure.expected }
        return Fixture.collectionOutcome
    }
}
@MainActor func Log(_ message: String) {}
func ErrorLabel(_ error: Error) -> String { "fixture_error" }

@main struct Main {
    @MainActor static func main() async throws {
        for backend in [ModelBackend.chatgpt, .claude] {
            for slug in ["gmail", "google-calendar", "google-drive"] {
                await Fixture.reset()
                ModelBackend.selected = backend
                let key = HostedConnectorSetup.pageProgressKey(slug: slug, backend: backend)
                let otherBackend: ModelBackend = backend == .claude ? .chatgpt : .claude
                try Fixture.check(key.hasPrefix("mcp.")
                    && key != HostedConnectorSetup.pageProgressKey(slug: slug, backend: otherBackend)
                    && key != HostedConnectorSetup.pageProgressKey(slug: "another-source", backend: backend),
                    "browser history is resettable and scoped to its source and reader")
                HostedConnectorSetup.settingsOpened(slug: slug, backend: backend)
                try Fixture.check(UserDefaults.standard.string(forKey: key) == "awaitingConfirmation",
                                  "successful browser handoff survives loss of the sheet")
                try Fixture.check(ConnectorCensus.declarations.isEmpty && Fixture.pending() == nil
                    && !UserDefaults.standard.bool(forKey: "dbg.run.gmail")
                    && !UserDefaults.standard.bool(forKey: "dbg.run.calendar")
                    && !UserDefaults.standard.bool(forKey: "mcp.google-drive.kb"),
                    "remembering a browser handoff does not select a source")
                try Fixture.check(HostedConnectorSetup.confirm(slug: slug, backend: backend)
                    && ConnectorCensus.declarations.last?.2 == true
                    && UserDefaults.standard.string(forKey: key) == "confirmed",
                    "Done from a reopened sheet completes the pending reconnect")
                try Fixture.check(HostedConnectorSetup.confirm(slug: slug, backend: backend)
                    && ConnectorCensus.declarations.last?.2 == false,
                    "previous browser history does not repeatedly request backfill")
                HostedConnectorSetup.stopReading(slug: slug, backend: backend)
                try Fixture.check(UserDefaults.standard.string(forKey: key) == "confirmed",
                                  "Done remains available after an explicit opt-out")
                HostedConnectorSetup.settingsOpened(slug: slug, backend: otherBackend)
                try Fixture.check(UserDefaults.standard.string(forKey:
                    HostedConnectorSetup.pageProgressKey(slug: slug, backend: otherBackend)) == nil,
                    "a stale sheet cannot create browser history for another reader")
                await HostedConnectorSetup.beginTeardown()
                HostedConnectorSetup.settingsOpened(slug: slug, backend: backend)
                try Fixture.check(UserDefaults.standard.string(forKey: key) == "confirmed",
                                  "teardown prevents late browser history writes")
                HostedConnectorSetup.endTeardown()
            }
        }
        await Fixture.reset()
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "Done saves explicit selection without connection verification")
        try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.run.gmail") && Fixture.pending() != nil,
                          "Done saves source and deferred contact consent")
        try Fixture.check(Fixture.calls.isEmpty && Fixture.contacts.isEmpty, "Done starts no model warmup or contact read")
        Fixture.contactBlocked = true
        HostedConnectorSetup.processingStarted(slug: "gmail")
        HostedConnectorSetup.processingStarted(slug: "gmail")
        try await Fixture.wait { Fixture.contacts.count == 1 }
        try Fixture.check(Fixture.pending() != nil, "actual processing owns one in-flight contact collection")
        let original = Fixture.pending()
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "new explicit consent remains possible while old contact work drains")
        let newer = Fixture.pending()
        Fixture.contactBlocked = false
        try await Fixture.wait { Fixture.contactCompletions == 1 }
        try Fixture.check(original != newer && Fixture.pending() == newer, "old collection cannot consume a newer consent token")
        HostedConnectorSetup.processingStarted(slug: "gmail")
        try await Fixture.wait { Fixture.pending() == nil }
        try Fixture.check(Fixture.contacts.count == 2, "next processing run completes deferred newer contact consent")
        try Fixture.check(HostedConnectorSetup.confirm(slug: "google-drive") && UserDefaults.standard.bool(forKey: "mcp.google-drive.kb"), "explicit Done enables reviewed source")
        try Fixture.check(HostedConnectorSetup.confirm(slug: "google-calendar") && UserDefaults.standard.bool(forKey: "dbg.calendar.connected"), "Calendar declaration preserves production connected key")
        HostedConnectorSetup.settingsOpened(slug: "gmail")
        try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.run.gmail"), "opening settings preserves selected intent")
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "reconnect does not wait for native metadata")
        ModelBackend.selected = .chatgpt
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail", backend: .claude), "wrong backend cannot save selection")
        ModelBackend.selected = .custom
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "custom backend cannot declare a hosted source")
        ModelBackend.selected = .sentient
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "Sentient funding cannot declare a subscription connector")
        ModelBackend.selected = .claude
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "declaration remains available after returning to correct backend")
        Fixture.contactBlocked = true
        HostedConnectorSetup.processingStarted(slug: "gmail")
        try await Fixture.wait { Fixture.contacts.count == 3 }
        await HostedConnectorSetup.beginTeardown()
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "teardown prevents new source or consent writes")
        HostedConnectorSetup.endTeardown()
        try Fixture.check(Fixture.pending() != nil && Fixture.contactCompletions == 3, "teardown cancels and drains contact work without losing pending consent")
        Fixture.contactBlocked = false
        await Fixture.reset()
        _ = HostedConnectorSetup.confirm(slug: "gmail")
        Fixture.contactBlocked = true
        HostedConnectorSetup.processingStarted(slug: "gmail")
        try await Fixture.wait { Fixture.contacts.count == 1 }
        HostedConnectorSetup.stopReading(slug: "gmail")
        try await Fixture.wait { Fixture.contactCompletions == 1 }
        try Fixture.check(Fixture.pending() == nil && !UserDefaults.standard.bool(forKey: "dbg.run.gmail"),
                          "Stop reading cancels an active deferred contact job and retires its consent")
        for (slug, key) in [("gmail", "dbg.run.gmail"), ("google-calendar", "dbg.run.calendar"),
                            ("google-drive", "mcp.google-drive.kb"), ("outlook-mail", "mcp.outlook-mail.kb")] {
            await Fixture.reset()
            try Fixture.check(HostedConnectorSetup.confirm(slug: slug), "fixture starts with selected " + slug)
            HostedConnectorSetup.stopReading(slug: slug)
            await Task.yield()
            try Fixture.check(!UserDefaults.standard.bool(forKey: key) && ConnectorCensus.declarations.count == 1,
                              "Stop reading stays opted out with no delayed verification for " + slug)
            try Fixture.check(Fixture.pending() == nil && Fixture.pending(.claude, .outlook) == nil,
                              "opt-out retires pending contact consent for " + slug)
        }
        await Fixture.reset()
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail") && HostedConnectorSetup.confirm(slug: "google-drive"),
                          "independent source confirmations complete synchronously")
        try Fixture.check(ConnectorCensus.declarations.count == 2, "each source confirms exactly once")
        HostedConnectorSetup.stopReading(slug: "gmail", backend: .chatgpt)
        try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.run.gmail"),
                          "a stale provider sheet cannot revoke the current selection")
        await Fixture.reset()
        try Fixture.check(HostedConnectorSetup.confirm(slug: "outlook-email")
            && UserDefaults.standard.bool(forKey: "mcp.outlook-mail.kb"), "alias confirmation uses canonical source")
        HostedConnectorSetup.stopReading(slug: "outlook-mail")
        try Fixture.check(!UserDefaults.standard.bool(forKey: "mcp.outlook-mail.kb") && Fixture.pending(.claude, .outlook) == nil,
                          "canonical opt-out clears alias consent")
        let priorDeclarations = ConnectorCensus.declarations.count
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "direct-fixture")
            && ConnectorCensus.declarations.count == priorDeclarations, "direct OAuth never uses hosted confirmation")
        print("PASS: \(Fixture.passed) immediate setup and deferred-contact checks")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-hosted-setup-") as tmp:
    temporary = Path(tmp)
    fixture = temporary / "HostedConnectorSetupFixture.swift"
    fixture.write_text(FIXTURE)
    binary = temporary / "fixture"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(fixture), str(SOURCE), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
