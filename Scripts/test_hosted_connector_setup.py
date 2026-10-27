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
    case chatgpt, claude, custom
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
    static var ready: Set<String> = []
    static var holdVerifications = false
    static var startedVerifications = 0
    static var pendingVerifications: [Int: CheckedContinuation<Bool, Never>] = [:]
    static func isReady(slug: String, backend: ModelBackend) -> Bool { ready.contains(slug) }
    static func verifyConnection(slug: String, backend: ModelBackend) async -> Bool {
        startedVerifications += 1
        guard holdVerifications else { return ready.contains(slug) }
        let id = startedVerifications
        // Deliberately return late success even after cancellation. The real coordinator's
        // consent revision must independently reject this stale network result.
        return await withCheckedContinuation { pendingVerifications[id] = $0 }
    }
    static func finishVerification(_ id: Int, ready: Bool = true) {
        pendingVerifications.removeValue(forKey: id)!.resume(returning: ready)
    }
    static func invalidateReadiness(slug: String, backend: ModelBackend) { ready.remove(slug) }
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
        ConnectorCensus.ready = []
        ConnectorCensus.holdVerifications = false; ConnectorCensus.startedVerifications = 0
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
        await Fixture.reset()
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "unverified declaration cannot select a source")
        ConnectorCensus.ready = ["gmail", "google-calendar", "google-drive", "outlook-mail"]
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "verified source can save explicit selection")
        try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.run.gmail") && Fixture.pending() != nil,
                          "verified Done saves source and deferred contact consent")
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
        try Fixture.check(HostedConnectorSetup.confirm(slug: "google-drive") && UserDefaults.standard.bool(forKey: "mcp.google-drive.kb"), "verified explicit Done enables reviewed source")
        try Fixture.check(HostedConnectorSetup.confirm(slug: "google-calendar") && UserDefaults.standard.bool(forKey: "dbg.calendar.connected"), "verified Calendar preserves production connected key")
        HostedConnectorSetup.settingsOpened(slug: "gmail")
        try Fixture.check(!ConnectorCensus.ready.contains("gmail") && UserDefaults.standard.bool(forKey: "dbg.run.gmail"), "reconnect invalidates proof while preserving selected intent")
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "stale readiness cannot be reconfirmed without a native check")
        ConnectorCensus.ready.insert("gmail")
        ModelBackend.selected = .chatgpt
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail", backend: .claude), "wrong backend cannot save selection")
        ModelBackend.selected = .custom
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "custom backend cannot declare a hosted source")
        ModelBackend.selected = .claude
        try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "verified declaration remains available after returning to correct backend")
        Fixture.contactBlocked = true
        HostedConnectorSetup.processingStarted(slug: "gmail")
        try await Fixture.wait { Fixture.contacts.count == 3 }
        await HostedConnectorSetup.beginTeardown()
        try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "teardown prevents new source or consent writes")
        HostedConnectorSetup.endTeardown()
        try Fixture.check(Fixture.pending() != nil && Fixture.contactCompletions == 3, "teardown cancels and drains contact work without losing pending consent")
        Fixture.contactBlocked = false
        await Fixture.reset()
        ConnectorCensus.ready = ["gmail"]
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
            ConnectorCensus.ready = [slug]
            try Fixture.check(HostedConnectorSetup.confirm(slug: slug), "fixture starts with selected " + slug)
            ConnectorCensus.holdVerifications = true
            let pending = Task { await HostedConnectorSetup.verifyAndConfirm(slug: slug) }
            try await Fixture.wait { ConnectorCensus.pendingVerifications[1] != nil }
            HostedConnectorSetup.stopReading(slug: slug)
            try Fixture.check(!UserDefaults.standard.bool(forKey: key), "Stop reading immediately opts out " + slug)
            ConnectorCensus.finishVerification(1)
            let accepted = await pending.value
            try Fixture.check(!accepted && !UserDefaults.standard.bool(forKey: key)
                              && ConnectorCensus.declarations.count == 1,
                              "late verification from another window cannot reverse opt-out for " + slug)
            try Fixture.check(Fixture.pending() == nil && Fixture.pending(.claude, .outlook) == nil,
                              "opt-out retires pending contact consent for " + slug)
        }
        await Fixture.reset()
        ConnectorCensus.ready = ["gmail", "google-drive"]
        ConnectorCensus.holdVerifications = true
        let old = Task { await HostedConnectorSetup.verifyAndConfirm(slug: "gmail") }
        try await Fixture.wait { ConnectorCensus.pendingVerifications[1] != nil }
        HostedConnectorSetup.settingsOpened(slug: "gmail")
        ConnectorCensus.ready.insert("gmail")
        ConnectorCensus.finishVerification(1)
        try Fixture.check(!(await old.value) && ConnectorCensus.declarations.isEmpty,
                          "reconnect in another window invalidates older verification")
        let first = Task { await HostedConnectorSetup.verifyAndConfirm(slug: "gmail") }
        try await Fixture.wait { ConnectorCensus.pendingVerifications[2] != nil }
        let latest = Task { await HostedConnectorSetup.verifyAndConfirm(slug: "gmail") }
        try await Fixture.wait { ConnectorCensus.pendingVerifications[3] != nil }
        let unrelated = Task { await HostedConnectorSetup.verifyAndConfirm(slug: "google-drive") }
        try await Fixture.wait { ConnectorCensus.pendingVerifications[4] != nil }
        ConnectorCensus.finishVerification(2)
        ConnectorCensus.finishVerification(3)
        ConnectorCensus.finishVerification(4)
        let firstAccepted = await first.value, latestAccepted = await latest.value, unrelatedAccepted = await unrelated.value
        try Fixture.check(!firstAccepted && latestAccepted && unrelatedAccepted,
                          "newest Done wins for its source without cancelling another source")
        try Fixture.check(ConnectorCensus.declarations.count == 2,
                          "concurrent sources each confirm exactly once")
        HostedConnectorSetup.stopReading(slug: "gmail", backend: .chatgpt)
        try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.run.gmail"),
                          "a stale provider sheet cannot revoke the current selection")
        await Fixture.reset()
        ConnectorCensus.ready = ["outlook-mail"]; ConnectorCensus.holdVerifications = true
        let alias = Task { await HostedConnectorSetup.verifyAndConfirm(slug: "outlook-email") }
        try await Fixture.wait { ConnectorCensus.pendingVerifications[1] != nil }
        HostedConnectorSetup.stopReading(slug: "outlook-mail")
        ConnectorCensus.finishVerification(1)
        try Fixture.check(!(await alias.value) && !UserDefaults.standard.bool(forKey: "mcp.outlook-mail.kb"),
                          "aliases share the canonical source consent revision")
        print("PASS: \(Fixture.passed) verified setup and deferred-contact checks")
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
