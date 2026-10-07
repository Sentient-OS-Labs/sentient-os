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
    @MainActor static func main() async {
        do {
            await Fixture.reset()
            Fixture.blocked = true
            try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail", backend: .claude), "Done accepted synchronously")
            try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.gmail.connected") && UserDefaults.standard.bool(forKey: "dbg.run.gmail"), "Gmail connected and selected before warmup")
            try Fixture.check(Fixture.calls.isEmpty && Fixture.contacts.isEmpty && Fixture.pending() != nil, "Done records durable intent without probing")
            try await Fixture.wait { Fixture.calls.count == 1 }
            try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail", backend: .claude), "duplicate Done still records declaration")
            try await Fixture.settle()
            try Fixture.check(Fixture.calls.count == 1, "duplicate warm jobs coalesce")
            HostedConnectorSetup.processingStarted(slug: "gmail", backend: .claude)
            HostedConnectorSetup.processingStarted(slug: "gmail", backend: .claude)
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty && Fixture.pending() != nil, "processing returns immediately while collection waits for warmup")
            ModelBackend.selected = .chatgpt
            Fixture.blocked = false
            try await Fixture.wait { Fixture.contactCompletions == 1 }
            try Fixture.check(Fixture.calls[0].0 == .claude && Fixture.contacts[0].0 == .claude && Fixture.contacts[0].2 == .claude, "warmup and collection retain processing backend after settings switch")
            try Fixture.check(Fixture.contacts.count == 1 && Fixture.pending() == nil, "coalesced successful collection consumes matching intent")
            let call = Fixture.calls[0].1
            try Fixture.check(call.mcpAttachServer == "gmail" && call.connectorOnlyRead && !call.webSearch && call.timeout == 60 && call.prompt.contains("Do not call tools"), "Claude wake uses attachment-only low-cost invocation")
            try Fixture.check(!FileManager.default.fileExists(atPath: call.cwd!), "warmup workspace removed")
            let count = ConnectorCensus.declarations.count
            try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail", backend: .claude) && ConnectorCensus.declarations.count == count, "stale backend cannot confirm")
            ModelBackend.selected = .custom
            try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail") && ConnectorCensus.declarations.count == count, "custom backend cannot confirm hosted source")

            await Fixture.reset()
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            try await Fixture.wait { Fixture.calls.count == 1 }
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty && Fixture.pending() != nil, "completed wake alone never collects")
            // Model quitting after Done: tear down jobs but retain the in-memory disk fixture.
            await HostedConnectorSetup.beginTeardown(); HostedConnectorSetup.endTeardown()
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contactCompletions == 1 }
            try Fixture.check(Fixture.pending() == nil && Fixture.contacts.count == 1, "durable intent survives coordinator restart until next processing")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.count == 1, "subsequent reads do not rediscover an already queued address")

            await Fixture.reset()
            ModelBackend.selected = .chatgpt
            UserDefaults.standard.set(false, forKey: "mcp.google-drive.kb")
            try Fixture.check(HostedConnectorSetup.confirm(slug: "google-drive") && UserDefaults.standard.bool(forKey: "mcp.google-drive.kb"), "explicit Done overrides disabled eligible source")
            try Fixture.check(HostedConnectorSetup.confirm(slug: "google-calendar") && UserDefaults.standard.bool(forKey: "dbg.calendar.connected") && UserDefaults.standard.bool(forKey: "dbg.run.calendar"), "calendar uses production connected and run keys")
            for slug in ["google-drive", "google-calendar", "outlook-calendar", "direct-synthetic", "unknown", "gmail"] { HostedConnectorSetup.processingStarted(slug: slug) }
            try await Fixture.wait { Fixture.calls.count == 2 }
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty && !UserDefaults.standard.values.keys.contains(where: { $0.hasPrefix("connectedEmail.") }), "only supported mail sources with disclosed intent can collect")
            try Fixture.check(Fixture.calls.allSatisfy { $0.0 == .chatgpt && !$0.1.includeUserConfig && !$0.1.toolsDisabled }, "ChatGPT wake keeps hosted apps available without user config")

            await Fixture.reset()
            try Fixture.check(HostedConnectorSetup.confirm(slug: "outlook-email") && UserDefaults.standard.bool(forKey: "mcp.outlook-mail.kb") && !UserDefaults.standard.bool(forKey: "mcp.outlook-email.kb"), "Outlook Email alias confirms canonical mail source")
            try await Fixture.wait { Fixture.calls.count == 1 }
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty && Fixture.pending(.claude, .outlook) != nil, "Outlook Done only records intent and warms")
            HostedConnectorSetup.processingStarted(slug: "outlook-email")
            try await Fixture.wait { Fixture.contactCompletions == 1 }
            try Fixture.check(ConnectorCensus.declarations.first?.0 == "outlook-mail" && Fixture.calls.first?.1.mcpAttachServer == "outlook-mail" && Fixture.contacts.first?.1 == .outlook, "Outlook alias declaration, wake and processing collection share canonical slug")

            for backend in [ModelBackend.chatgpt, .claude] {
                for (slug, provider) in [("gmail", MailAccount.Provider.gmail), ("outlook-mail", .outlook)] {
                    await Fixture.reset()
                    ModelBackend.selected = backend
                    _ = HostedConnectorSetup.confirm(slug: slug)
                    HostedConnectorSetup.processingStarted(slug: slug)
                    try await Fixture.wait { Fixture.contactCompletions == 1 }
                    let contact = Fixture.contacts[0]
                    try Fixture.check(contact.0.rawValue == backend.rawValue && contact.1 == provider && contact.2 == backend && Fixture.pending(backend, provider) == nil, "\(backend.rawValue) \(slug) processing collects only its confirmed account provider")
                }
            }
            await Fixture.reset()
            UserDefaults.standard.set(true, forKey: "dbg.gmail.connected")
            UserDefaults.standard.set(true, forKey: "dbg.run.gmail")
            UserDefaults.standard.set(true, forKey: "mcp.outlook-mail.kb")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            HostedConnectorSetup.processingStarted(slug: "outlook-mail")
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty, "pre-existing selected mail sources never imply new contact consent")

            for outcome in [MailAccountCollection.Outcome.noConnection, .noAddress, .pending, .saved] {
                await Fixture.reset()
                Fixture.collectionOutcome = outcome
                _ = HostedConnectorSetup.confirm(slug: "gmail")
                let request = Fixture.pending()
                HostedConnectorSetup.processingStarted(slug: "gmail")
                try await Fixture.wait { Fixture.contactCompletions == 1 }
                let shouldRetry: Bool
                switch outcome { case .noConnection, .noAddress: shouldRetry = true; case .pending, .saved: shouldRetry = false }
                try Fixture.check(shouldRetry ? Fixture.pending() == request : Fixture.pending() == nil, "collection outcome \(outcome) preserves or consumes intent correctly")
                try Fixture.check(UserDefaults.standard.bool(forKey: "dbg.run.gmail") && UserDefaults.standard.bool(forKey: "dbg.gmail.connected"), "collection outcome \(outcome) preserves declared source state")
                Fixture.collectionOutcome = .saved
                HostedConnectorSetup.processingStarted(slug: "gmail")
                try await Fixture.settle()
                try Fixture.check(Fixture.contacts.count == (shouldRetry ? 2 : 1), "collection outcome \(outcome) retries only on next processing when needed")
            }

            await Fixture.reset()
            Fixture.failWarm = true; Fixture.failCollect = true
            try Fixture.check(HostedConnectorSetup.confirm(slug: "gmail"), "Done accepted with downstream failures")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contactCompletions == 1 }
            try Fixture.check(Fixture.pending() != nil && UserDefaults.standard.bool(forKey: "dbg.run.gmail") && UserDefaults.standard.bool(forKey: "dbg.gmail.connected"), "failed warmup/probe leaves intent and selection for future processing")

            await Fixture.reset()
            Fixture.blocked = true
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            try await Fixture.wait { Fixture.calls.count == 1 }
            _ = HostedConnectorSetup.confirm(slug: "gmail", reconnected: true)
            _ = HostedConnectorSetup.confirm(slug: "gmail", reconnected: true)
            Fixture.blocked = false
            try await Fixture.wait { Fixture.calls.count == 2 }
            try await Fixture.settle()
            try Fixture.check(Fixture.calls.count == 2 && Fixture.contacts.isEmpty, "reconnect schedules one coalesced wake without collection")

            await Fixture.reset()
            Fixture.blocked = true
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.calls.count == 1 }
            let oldRequest = Fixture.pending()
            _ = HostedConnectorSetup.confirm(slug: "gmail", reconnected: true)
            let newerRequest = Fixture.pending()
            Fixture.blocked = false
            try await Fixture.wait { Fixture.calls.count == 2 }
            try await Fixture.settle()
            try Fixture.check(oldRequest != newerRequest && Fixture.pending() == newerRequest && Fixture.contacts.isEmpty, "superseded intent waiting on warmup cannot probe or consume newer request")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contactCompletions == 1 }
            try Fixture.check(Fixture.pending() == nil, "new intent runs on next processing opportunity")

            await Fixture.reset()
            Fixture.contactBlocked = true
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contacts.count == 1 }
            let inFlightRequest = Fixture.pending()
            _ = HostedConnectorSetup.confirm(slug: "gmail", reconnected: true)
            let replacementRequest = Fixture.pending()
            HostedConnectorSetup.processingStarted(slug: "gmail")
            Fixture.contactBlocked = false
            try await Fixture.wait { Fixture.contactCompletions == 1 }
            try Fixture.check(inFlightRequest != replacementRequest && Fixture.pending() == replacementRequest && Fixture.contacts.count == 1, "in-flight old result cannot consume reconnect intent and duplicate collectors coalesce")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contactCompletions == 2 }
            try Fixture.check(Fixture.pending() == nil, "replacement intent consumed only by matching new collector")

            await Fixture.reset()
            Fixture.blocked = true
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.calls.count == 1 }
            await HostedConnectorSetup.beginTeardown()
            try Fixture.check(Fixture.contacts.isEmpty && Fixture.pending() != nil, "teardown drains waiting collection without losing unfulfilled intent")
            try Fixture.check(!HostedConnectorSetup.confirm(slug: "gmail"), "teardown refuses new declarations")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            Fixture.blocked = false
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty, "teardown refuses processing-triggered collection")
            HostedConnectorSetup.endTeardown()
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contactCompletions == 1 }

            await Fixture.reset()
            Fixture.contactBlocked = true
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.wait { Fixture.contacts.count == 1 }
            try Fixture.check(Fixture.contactCompletions == 0 && Fixture.pending() != nil, "processing returns while actual address probe is blocked")
            await HostedConnectorSetup.beginTeardown()
            try Fixture.check(Fixture.contactCompletions == 1 && Fixture.pending() != nil, "teardown cancels and drains active collector while retaining intent")
            let contacts = Fixture.contacts.count
            Fixture.contactBlocked = false
            HostedConnectorSetup.endTeardown()
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.count == contacts, "drained collector cannot reappear after teardown")

            await Fixture.reset()
            _ = HostedConnectorSetup.confirm(slug: "gmail")
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                HostedConnectorSetup.processingStarted(slug: "gmail")
            }
            await cancelled.value
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty && Fixture.pending() != nil, "cancelled processing never starts address collection")
            ModelBackend.selected = .chatgpt
            HostedConnectorSetup.processingStarted(slug: "gmail")
            ModelBackend.selected = .custom
            HostedConnectorSetup.processingStarted(slug: "gmail")
            try await Fixture.settle()
            try Fixture.check(Fixture.contacts.isEmpty && Fixture.pending() != nil, "another backend and custom models cannot consume provider-specific intent")

            await Fixture.reset()
            _ = HostedConnectorSetup.confirm(slug: "unknown")
            try await Fixture.wait { Fixture.calls.count == 1 }
            try Fixture.check(Fixture.calls[0].1.toolsDisabled && !Fixture.calls[0].1.includeUserConfig, "unknown Claude server uses safe provider wake fallback")
            try Fixture.check(!HostedConnectorSetup.confirm(slug: "direct-synthetic"), "direct accounts excluded from hosted setup")
            await Fixture.reset()
            let defaults = UserDefaults.standard
            func generation(_ slug: String, _ backend: ModelBackend = .claude) -> Int {
                defaults.integer(forKey: ConnectorRegistry.readGenerationKey(slug, backend.rawValue))
            }
            HostedConnectorSetup.settingsOpened(slug: "gmail")
            try Fixture.check(generation("gmail") == 0 && defaults.values.isEmpty, "unselected settings opening changes no state")
            defaults.set(true, forKey: "dbg.run.gmail")
            HostedConnectorSetup.settingsOpened(slug: "gmail")
            try Fixture.check(generation("gmail") == 1 && ConnectorCensus.declarations.isEmpty, "selected Gmail requests backfill without needing cached declaration")
            try Fixture.check(defaults.bool(forKey: "dbg.run.gmail") && !defaults.bool(forKey: "dbg.gmail.connected"), "settings opening preserves selection and connection state")
            defaults.set(true, forKey: "dbg.run.calendar")
            HostedConnectorSetup.settingsOpened(slug: "google-calendar")
            try Fixture.check(generation("google-calendar") == 1, "selected calendar settings uses production generation key")
            defaults.set(true, forKey: "mcp.google-drive.kb")
            HostedConnectorSetup.settingsOpened(slug: "google-drive")
            try Fixture.check(generation("google-drive") == 1, "selected curated hosted source requests backfill")
            defaults.set(true, forKey: "mcp.outlook-mail.kb")
            HostedConnectorSetup.settingsOpened(slug: "outlook-email")
            try Fixture.check(generation("outlook-mail") == 1 && generation("outlook-email") == 0, "Outlook Email settings alias invalidates canonical selected source")
            defaults.set(true, forKey: "mcp.unknown.kb")
            HostedConnectorSetup.settingsOpened(slug: "unknown")
            HostedConnectorSetup.settingsOpened(slug: "direct-synthetic")
            try Fixture.check(generation("unknown") == 0 && generation("direct-synthetic") == 0, "task-only and direct sources do not invalidate hosted progress")
            ModelBackend.selected = .chatgpt
            HostedConnectorSetup.settingsOpened(slug: "gmail", backend: .claude)
            try Fixture.check(generation("gmail") == 1 && generation("gmail", .chatgpt) == 0, "stale settings provider cannot invalidate progress")
            ModelBackend.selected = .custom
            HostedConnectorSetup.settingsOpened(slug: "gmail")
            try Fixture.check(generation("gmail", .custom) == 0, "custom provider cannot invalidate hosted progress")
            ModelBackend.selected = .claude
            await HostedConnectorSetup.beginTeardown()
            HostedConnectorSetup.settingsOpened(slug: "gmail")
            HostedConnectorSetup.endTeardown()
            try Fixture.check(generation("gmail") == 1, "teardown refuses settings invalidation")
            try await Task.sleep(for: .milliseconds(25))
            try Fixture.check(Fixture.calls.isEmpty && Fixture.contacts.isEmpty && ConnectorCensus.declarations.isEmpty, "settings opening never starts provider work or records a new declaration")
            await Fixture.reset()
            print("RESULT: \(Fixture.passed) checks passed")
        } catch { print("FAIL: \(error)"); exit(1) }
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
