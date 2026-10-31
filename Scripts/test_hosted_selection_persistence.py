#!/usr/bin/env python3
"""Exercise real hosted selection, census persistence, registry and request assembly.

Only provider metadata, direct accounts and unrelated local sources are fixtures.
Foundation UserDefaults uses unique suites; fresh processes verify failed/missing
discovery never revokes saved intent. No app, provider process or network is used.
"""
from pathlib import Path
import subprocess
import tempfile
import uuid

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'


def member(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


census = (APP / 'Cloud/ConnectorCensus.swift').read_text()
registry = (APP / 'Cloud/ConnectorRegistry.swift').read_text()
setup = (APP / 'Cloud/HostedConnectorSetup.swift').read_text()
run = (APP / 'Ingestion/ProcessingRun.swift').read_text()

fixture = r'''
import Foundation

// Keep production .standard call sites while using a real, uniquely named suite.
final class UserDefaults {
    static let standard = UserDefaults()
    let native = Foundation.UserDefaults(suiteName: CommandLine.arguments[2])!
    func bool(forKey key: String) -> Bool { native.bool(forKey: key) }
    func integer(forKey key: String) -> Int { native.integer(forKey: key) }
    func string(forKey key: String) -> String? { native.string(forKey: key) }
    func data(forKey key: String) -> Data? { native.data(forKey: key) }
    func object(forKey key: String) -> Any? { native.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) { native.set(value, forKey: key) }
    func removeObject(forKey key: String) { native.removeObject(forKey: key) }
}
enum ModelBackend: String {
    case chatgpt, claude, custom, sentient
    static var current = Self(rawValue: CommandLine.arguments[3])!
    var hasSubscriptionConnectors: Bool { self == .chatgpt || self == .claude }
    static var connectorsAvailable: Bool { current.hasSubscriptionConnectors }
}
enum CodexRuntime { static let sessionScope = "fixture"; static var accountIdentity: String? = "account-a" }
enum ClaudeAuth { static var cachedAccountIdentity: String? = "account-a" }
enum CodexAuth { static let kbOnlyKey = "fixture.kbOnly" }
enum Analytics { static func signal(_ name: String, parameters: [String: String]) {} }
struct DirectMCPProvider: Sendable { let kbVerified: Bool; let reviewedReads: Set<String> }
struct DirectConnection: Codable {
    enum State: String, Codable { case connected, reconnect, unavailable, policyRequired }
    let slug: String, state: State
    var kbEligible: Bool { true }
    var connected: Bool { state == .connected }
    var detected: ConnectorCensus.DetectedConnector {
        .init(slug: slug, displayName: slug, origin: .direct, serverURL: nil, catalogID: nil,
              iconPath: nil, healthy: connected, lastSeen: .distantPast)
    }
}
enum DirectMCPStore {
    static func connection(_ slug: String) -> DirectConnection? { connections().first { $0.slug == slug } }
    static func connections() -> [DirectConnection] {
        guard let data = UserDefaults.standard.data(forKey: "fixture.direct.accounts") else { return [] }
        return try! JSONDecoder().decode([DirectConnection].self, from: data)
    }
    static func save(_ accounts: [DirectConnection]) {
        UserDefaults.standard.set(try! JSONEncoder().encode(accounts), forKey: "fixture.direct.accounts")
    }
}
enum ConnectorCensus {
    static let dedicatedSourceSlugs: Set<String> = ["gmail", "google-calendar"]
    static let codexSystemSlugs: Set<String> = ["openai-templates", "plugin-management"]
    // CENSUS
}
enum HostedConnectorStore {
    struct Account { let connected: Bool; let detected: ConnectorCensus.DetectedConnector }
    static func accounts() -> [Account] { [] }
    static func account(_ slug: String) -> Account? { nil }
}
enum ConnectorRegistry {
    // PACK_SHAPE
    static let packs: [CuratedConnector] = ["gmail", "google-calendar", "google-drive", "slack", "outlook-mail", "outlook-calendar"].map {
        .init(slug: $0, displayName: $0, claudeServerURL: "https://fixture.invalid/" + $0,
              claudeToolPrefix: "mcp__fixture_" + $0 + "__", readTools: ["read"], codexReadTools: ["read"])
    } + [.init(slug: "task-only", displayName: "Tasks only"),
         .init(slug: "granola", displayName: "Granola", directProvider: .init(kbVerified: true, reviewedReads: ["read"]))]
    static func pack(forSlug slug: String) -> CuratedConnector? { packs.first { $0.slug == slug } }
    static func pack(for record: ConnectorCensus.DetectedConnector) -> CuratedConnector? { pack(forSlug: record.slug) }
    static func canonicalSlug(_ slug: String) -> String { slug }
    // REGISTRY
}
enum Microsoft365Connector {
    static let url = "https://fixture.invalid/microsoft365", name = "Microsoft 365"
    static func contains(_ slug: String) -> Bool { slug == "microsoft-365" }
}
enum OutlookMailConnector {
    static let slug = "outlook-mail", codexSlug = "microsoft_outlook_email"
    static let claudeName = "Outlook Mail", claudeURL = "https://fixture.invalid/outlook-mail"
    static func isMail(_ slug: String) -> Bool { slug == Self.slug }
}
enum MailAccount { enum Engine: String { case chatgpt, claude }; enum Provider: String { case gmail, outlook } }
@MainActor enum HostedConnectorSetup {
    static var teardownDepth = 0
    static var collectionJobs: [String: Task<Void, Never>] = [:]
    // SETUP
}
struct FileRoot {
    let name: String
    static let downloads = Self(name: "Downloads"), desktop = Self(name: "Desktop"), documents = Self(name: "Documents")
    static func custom(_ url: URL) -> Self { .init(name: url.path) }
    var label: String { name }
    var url: URL? { nil }
}
protocol Connector {}
enum RunSource {
    case files(FileRoot), whatsapp(chatJIDs: Set<String>), imessage(chatGUIDs: Set<String>), notes, siyuan
    case appleMail(accounts: Set<String>), appleCalendar(calendarIDs: Set<String>)
    static func connectors(from sources: [Self]) -> [any Connector] { precondition(sources.isEmpty); return [] }
}
enum SiYuanSource {
    static let enabledKey = "siyuan.enabled"
    static let isInstalled = false, isEnabled = false
}
struct WhatsAppSource { static var isInstalled = false; var dbPath: String { "/nonexistent/synthetic" } }
struct iMessageSource { var dbPath: String { "/nonexistent/synthetic" } }
struct NotesSource { var dbPath: String { "/nonexistent/synthetic" } }
enum AppleMailSource { static let isSupported = false; static func root() throws -> URL { URL(fileURLWithPath: "/nonexistent/synthetic") } }
enum AppleMailSelection { static let key = "fixture.mail"; static let accounts: Set<String> = [] }
enum AppleCalendarSource {
    static let issueKey = "fixture.calendar", hasAccess = false, isEnabled = false
    static let selectedIDs: Set<String> = []
}
enum IterativeRun { enum Mode { case auto, initial, iterative } }
enum ModelLocator { static func resolve() -> String? { fatalError("Hosted-only selection must not resolve a local model") } }
'''

fixture = fixture.replace('// CENSUS', '\n'.join(('@discardableResult\n' if signature == 'static func persist(' else '') + member(census, signature) for signature in (
    'struct DetectedConnector:', 'static func readinessAccountIdentity(', 'static func recordReadOutcome(',
    'static func confirmSelection(', 'static func cached(', 'static func logicalService(',
    'static func logicalServices(', 'private static func storageKey(', 'static func persist(',
    'static func preservingReadiness(', 'static func titleCased(',
)))
fixture = fixture.replace('// PACK_SHAPE', '\n'.join(member(registry, signature) for signature in (
    'enum KBAdapter:', 'struct CuratedConnector:',
)))
fixture = fixture.replace('// REGISTRY', '\n'.join(member(registry, signature) for signature in (
    'static func kbKey(', 'static func isKBEnabled(', 'static func setKBEnabled(',
    'static func advanceKnowledgeSelectionRevision(',
    'static func kbEnabledConnectors(', 'static func contributesToKnowledgeBase(',
    'static func kbEligible(', 'static func readGenerationKey(',
)))
fixture = fixture.replace('// SETUP', '\n'.join(('@discardableResult\n' if signature == 'static func confirm(' else '') + member(setup, signature) for signature in (
    'static func confirm(', 'static func stopReading(', 'private static func mailCollectionRequest(',
)))

checks = r'''
@main struct Test {
    @MainActor static func main() throws {
        let phase = CommandLine.arguments[1], backend = ModelBackend.current
        let defaults = UserDefaults.standard
        let origin = ConnectorCensus.DetectedConnector.Origin(backend: backend)!
        let generic: Set<String> = ["google-drive", "slack", "outlook-mail", "outlook-calendar"]
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); print("PASS \(backend.rawValue)/\(phase): \(message)")
        }
        func checkSelected(_ message: String) {
            let request = ProcessingRequest.current()
            check(request.runGmail && request.runCalendar && Set(request.mcpSlugs) == generic
                && request.readySelectionCount == 6 && request.connectors.isEmpty && request.modelPath == nil,
                  message)
            check(request.unavailableSources.isEmpty && request.unavailableConnectorSlugs.isEmpty,
                  "cached health creates no unavailable source or proactive exclusion")
        }
        func loseMetadata() {
            CodexRuntime.accountIdentity = nil; ClaudeAuth.cachedAccountIdentity = nil
        }
        if phase == "write" {
            defaults.native.removePersistentDomain(forName: CommandLine.arguments[2])
            loseMetadata()
            check(ProcessingRequest.current().readySelectionCount == 0, "fresh empty state enrolls no sources")
            for slug in ["gmail", "google-calendar"] + generic.sorted() {
                check(HostedConnectorSetup.confirm(slug: slug), "Done saves \(slug) with no account metadata")
            }
            checkSelected("actual request includes every chosen hosted source with absent metadata")
            CodexRuntime.accountIdentity = "account-a"; ClaudeAuth.cachedAccountIdentity = "account-a"
            for slug in ["gmail", "google-calendar"] + generic.sorted() {
                HostedConnectorSetup.confirm(slug: slug)
                ConnectorCensus.recordReadOutcome(slug: slug, backend: backend, connected: false)
            }
            check(ConnectorCensus.cached(for: origin).allSatisfy { !$0.healthy && $0.readinessVerified == false },
                  "real read failures remain unhealthy diagnostic evidence")
            checkSelected("actual request still attempts selected sources after recorded authentication failures")
            check(defaults.native.synchronize(), "isolated preferences saved for a new process")
        } else if phase == "reopen" {
            check(ConnectorCensus.cached(for: origin).count == 6
                && ConnectorCensus.cached(for: origin).allSatisfy { !$0.healthy },
                  "new process reloads actual persisted failed census records")
            checkSelected("new process reloads saved intent without reconfirmation")
            ConnectorCensus.persist([], for: origin)
            checkSelected("empty catalog refresh cannot revoke selected sources")
            let stale = ConnectorCensus.cached(for: origin).map { record in
                ConnectorCensus.DetectedConnector(slug: record.slug, displayName: record.displayName, origin: origin,
                    serverURL: record.serverURL, catalogID: record.catalogID, iconPath: nil, healthy: false, lastSeen: .distantPast)
            }
            ConnectorCensus.persist(stale, for: origin)
            checkSelected("stale unhealthy catalog refresh cannot revoke selected sources")
            for key in defaults.native.dictionaryRepresentation().keys where key.hasPrefix("mcp.connectors.") {
                defaults.removeObject(forKey: key)
            }
            checkSelected("deleted census cache falls back to saved source choices")
            loseMetadata()
            checkSelected("lost account metadata after relaunch cannot revoke saved source choices")
            CodexRuntime.accountIdentity = "account-b"; ClaudeAuth.cachedAccountIdentity = "account-b"
            checkSelected("newly observed account metadata leaves admission to the user's choices")
            defaults.set(true, forKey: ConnectorRegistry.kbKey("task-only"))
            let unsupported = ProcessingRequest.current()
            check(Set(unsupported.mcpSlugs) == generic && unsupported.readySelectionCount == 6
                && unsupported.unavailableSources["Tasks only"] != nil,
                  "unsupported task-only connector is reported but not enrolled into analysis")
            defaults.set(false, forKey: ConnectorRegistry.kbKey("task-only"))
            ModelBackend.current = .custom
            check(ProcessingRequest.current().readySelectionCount == 0, "custom backend still excludes hosted sources")
            ModelBackend.current = backend
            check(defaults.native.synchronize(), "cache-loss fixture persists independently of selected intent")
        } else if phase == "stop" {
            checkSelected("saved choices survive a second cache-free process restart")
            for slug in ["gmail", "google-calendar"] + generic.sorted() { HostedConnectorSetup.stopReading(slug: slug) }
            check(ProcessingRequest.current().readySelectionCount == 0, "explicit Stop removes every hosted source from admission")
            check(defaults.bool(forKey: "dbg.gmail.connected") && defaults.bool(forKey: "dbg.calendar.connected"),
                  "saved connection flags cannot override explicit reading opt-out")
            check(defaults.native.synchronize(), "explicit stop is persisted")
        } else if phase == "reopen-stopped" {
            check(ProcessingRequest.current().readySelectionCount == 0, "explicit Stop survives process restart")
            let discovered = ["gmail", "google-calendar"] + generic.sorted()
            ConnectorCensus.persist(discovered.map {
                .init(slug: $0, displayName: $0, origin: origin, serverURL: nil, catalogID: nil,
                      iconPath: nil, healthy: true, lastSeen: .now, readinessVerified: true)
            }, for: origin)
            check(ProcessingRequest.current().readySelectionCount == 0,
                  "healthy discovery never reenrolls sources after explicit Stop")
            defaults.set(true, forKey: "dbg.run.gmail")
            defaults.set(false, forKey: "dbg.gmail.connected")
            check(!ProcessingRequest.current().runGmail, "explicit disconnected preference remains authoritative")
        } else if phase == "write-direct" {
            defaults.native.removePersistentDomain(forName: CommandLine.arguments[2])
            let accounts = [DirectConnection.State.connected, .reconnect, .unavailable, .policyRequired].map {
                DirectConnection(slug: "direct-" + $0.rawValue, state: $0)
            }
            DirectMCPStore.save(accounts)
            check(ProcessingRequest.current().mcpSlugs.isEmpty, "stored direct accounts never imply reading consent")
            for account in accounts { ConnectorRegistry.setKBEnabled(account.slug, true) }
            check(Set(ProcessingRequest.current().mcpSlugs) == Set(accounts.map(\.slug)),
                  "every explicitly selected stored direct account is admitted regardless of previous health")
            check(ProcessingRequest.current().unavailableConnectorSlugs.isEmpty,
                  "prior direct failure states create no admission or proactive exclusion")
            check(defaults.native.synchronize(), "direct failed states and selections persist")
        } else if phase == "reopen-direct" {
            let accounts = DirectMCPStore.connections()
            check(accounts.count == 4 && accounts.filter { !$0.connected }.count == 3,
                  "fresh process retains failed direct state separately from user intent")
            check(Set(ProcessingRequest.current().mcpSlugs) == Set(accounts.map(\.slug)),
                  "failed direct accounts remain retryable after process restart")
            ModelBackend.current = .custom
            check(Set(ProcessingRequest.current().mcpSlugs) == Set(accounts.map(\.slug)),
                  "custom backend retains explicitly selected direct accounts")
            ModelBackend.current = backend
            ConnectorRegistry.setKBEnabled("granola", true)
            ConnectorRegistry.setKBEnabled("direct-deleted", true)
            check(Set(ProcessingRequest.current().mcpSlugs) == Set(accounts.map(\.slug)).union(["granola"]),
                  "saved hosted intent is attempted separately and never invents an absent direct account")
            let removed = accounts[0].detected
            DirectMCPStore.save(Array(accounts.dropFirst()))
            ConnectorRegistry.setKBEnabled(removed.slug, false)
            check(!removed.canAttempt && !ProcessingRequest.current().mcpSlugs.contains(removed.slug),
                  "explicit disconnected account is removed from admission and stale presentation")
            for account in accounts.dropFirst() { ConnectorRegistry.setKBEnabled(account.slug, false) }
            DirectMCPStore.save([])
            check(defaults.native.synchronize(), "direct disconnect is persisted")
        } else if phase == "reopen-disconnected" {
            check(DirectMCPStore.connections().isEmpty && ProcessingRequest.current().mcpSlugs == ["granola"],
                  "direct disconnect survives restart while independent hosted intent is preserved")
            ConnectorRegistry.setKBEnabled("granola", false)
            check(ProcessingRequest.current().mcpSlugs.isEmpty,
                  "explicit hosted opt-out removes the remaining unsupported-route attempt")
        } else { preconditionFailure("Unknown phase") }
    }
}
'''

source = '\n'.join((fixture, (APP / 'Sources/SourceSelection.swift').read_text(),
                    member(run, 'struct ProcessingRequest'), checks))
with tempfile.TemporaryDirectory(prefix='sentient-hosted-selection-') as directory:
    root = Path(directory)
    (root / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(root / 'main.swift'), '-o', str(root / 'check')], check=True)
    for backend in ['chatgpt', 'claude']:
        suite = 'sentient-hosted-selection-' + str(uuid.uuid4())
        try:
            for phase in ['write', 'reopen', 'stop', 'reopen-stopped', 'write-direct', 'reopen-direct', 'reopen-disconnected']:
                subprocess.run([str(root / 'check'), phase, suite, backend], check=True, timeout=30)
        finally:
            subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('PASS hosted source choices: actual selection/census/registry/request code, fresh-process preferences')
