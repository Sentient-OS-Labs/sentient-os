#!/usr/bin/env python3
"""Compile source readiness, migration and writing-sample scope against synthetic fixtures.
No app launch, real preferences, private data, network, TCC changes or source connections.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'


def declaration(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


stubs = r'''
import Foundation
import SQLite3
let fixtureRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
struct FileRoot {
    let name: String
    static let downloads = Self(name: "Downloads"), desktop = Self(name: "Desktop"), documents = Self(name: "Documents")
    static func custom(_ url: URL) -> Self { .init(name: url.path) }
    var label: String { name }
    var url: URL? { name.hasPrefix("/") ? URL(fileURLWithPath: name) : fixtureRoot.appendingPathComponent(name) }
}
enum RunSource { case files(FileRoot), whatsapp(chatJIDs: Set<String>), imessage(chatGUIDs: Set<String>), notes, siyuan, appleMail(accounts: Set<String>), appleCalendar(calendarIDs: Set<String>) }
enum SiYuanSource {
    static let enabledKey = "siyuan.enabled"
    static var isInstalled = true
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) && isInstalled }
}
struct WhatsAppSource {
    static var isInstalled = true
    var dbPath: String { fixtureRoot.appendingPathComponent("ChatStorage.sqlite").path }
    static func cleanName(_ value: String?) -> String? { value }
    static func handle(_ value: String) -> String { value.components(separatedBy: "@")[0] }
}
struct iMessageSource {
    var dbPath: String { fixtureRoot.appendingPathComponent("chat.db").path }
    static func typedstreamText(_ data: Data) -> String? { nil }
}
struct NotesSource { var dbPath: String { fixtureRoot.appendingPathComponent("NoteStore.sqlite").path } }
enum AppleMailSource {
    static var isSupported = true
    static func root() throws -> URL { fixtureRoot.appendingPathComponent("Mail") }
}
enum AppleMailSelection { static let key = "mail.accounts"; static var accounts: Set<String> = [] }
enum AppleCalendarSource {
    static let issueKey = "calendar.issue"
    static var hasAccess = false
    static var selectedIDs: Set<String> = []
    static var isEnabled: Bool { hasAccess && !selectedIDs.isEmpty }
}
enum ModelBackend: String {
    case chatgpt, claude, custom
    static var current = Self.chatgpt
    static var connectorsAvailable: Bool { current != .custom }
}
enum ConnectorCensus {
    struct DetectedConnector {
        enum Origin { case chatgpt, claude, direct
            init?(backend: ModelBackend) {
                switch backend { case .chatgpt: self = .chatgpt; case .claude: self = .claude; case .custom: return nil }
            }
        }
        let slug: String
        var displayName: String { slug }
        let healthy: Bool
        var readinessVerified: Bool? = true
        var isReady: Bool { healthy && readinessVerified == true }
        func canAttempt(legacyCompleted: Bool) -> Bool { isReady || (healthy && readinessVerified == nil && legacyCompleted) }
    }
    static var records: [DetectedConnector] = []
    static func cached(for origin: DetectedConnector.Origin) -> [DetectedConnector] { records }
}
enum ConnectorRegistry {
    struct Pack { let slug: String; let providesCalendarContext: Bool; var displayName: String { slug } }
    static let packs: [Pack] = []
    static func isKBEnabled(_ slug: String) -> Bool { selected.contains { $0.slug == slug } }
    static func kbEligible(_ slug: String) -> Bool { true }
    static var selected: [ConnectorCensus.DetectedConnector] = []
    static func kbEnabledConnectors() -> [ConnectorCensus.DetectedConnector] { selected }
    static func pack(for connector: ConnectorCensus.DetectedConnector) -> Pack? { nil }
    static func readOrigin(slug: String, backend: ModelBackend) -> String { backend.rawValue + slug }
}
enum ProcessingPlan {
    static var completed = false
    static func initialCompletedAt() -> Date? { completed ? Date(timeIntervalSince1970: 1) : nil }
}
enum CodexAuth { static let kbOnlyKey = "plan.kbOnly" }
enum OutlookMailConnector { static let slug = "outlook-mail" }
enum AddressBookNames { static func resolve(_ handle: String, in names: [String: String]) -> String? { names[handle] } }
func Log(_ value: String) {}
func ErrorLabel(_ error: Error) -> String { "fixture" }
enum Diagnostics {
    enum Event { case sourceSnapshotDegraded }; enum Phase { case snapshot }; enum Flag { case completeSnapshot, previousStateRetained }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error, flags: [Flag: Bool]) {}
}
enum CrashReporting {
    enum Level { case error }
    static func captureEvent(_ event: String, level: Level, tags: [String: String], extra: [String: String], fingerprint: [String]) {}
}
'''

checks = r'''
@main struct Test {
    @MainActor static func main() throws {
        let defaults = UserDefaults.standard
        // All production standard-default reads are shadowed by a complete volatile domain.
        var flags: [String: Any] = ["dbg.run.downloads": false, "dbg.run.desktop": false, "dbg.run.documents": false,
            "dbg.run.imessage": false, "dbg.run.whatsapp": false, "dbg.run.notes": false,
            "dbg.run.gmail": false, "dbg.gmail.connected": false, "dbg.run.calendar": false,
            "dbg.calendar.connected": false, "dbg.imessage.chats": "", "dbg.whatsapp.chats": "",
            CustomRoots.key: "", AppleCalendarSource.issueKey: "", AppleMailSelection.key: "", CodexAuth.kbOnlyKey: false,
            SiYuanSource.enabledKey: false]
        func apply() { defaults.setVolatileDomain(flags, forName: UserDefaults.argumentDomain) }
        func check(_ result: Bool, _ label: String) { precondition(result, label); print("PASS " + label) }
        let fm = FileManager.default
        for folder in ["Downloads", "Desktop", "Documents"] {
            try fm.createDirectory(at: fixtureRoot.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let suiteName = "sentient-source-consent-" + UUID().uuidString
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        SourceSelection.migrateLegacyFolderDefaults(hadPersonalSetup: false, defaults: suite)
        check(SourceSelection.folderKeys.allSatisfy { suite.object(forKey: $0) as? Bool == false }, "fresh folders are explicit opt-in")
        suite.removePersistentDomain(forName: suiteName)
        suite.set(false, forKey: "dbg.run.desktop")
        SourceSelection.migrateLegacyFolderDefaults(hadPersonalSetup: true, defaults: suite)
        check(!suite.bool(forKey: "dbg.run.desktop") && suite.bool(forKey: "dbg.run.downloads"), "legacy missing choices migrate while saved false survives")
        SourceSelection.migrateLegacyFolderDefaults(hadPersonalSetup: false, defaults: suite)
        check(suite.bool(forKey: "dbg.run.downloads"), "migration is idempotent on resume")
        apply()
        check(SourceSelection.minimumSelections == 3 && SourceSelection.selectionCount == 0, "fresh state counts zero sources")
        flags[SiYuanSource.enabledKey] = true; apply()
        check(SourceSelection.selectionCount == 1, "selected SiYuan counts exactly once toward personal setup")
        check(SourceSelection.current(fdaGranted: false).contains { if case .siyuan = $0 { return true }; return false }, "SiYuan stays available without a broad FDA grant")
        flags["dbg.run.downloads"] = true; flags["dbg.run.desktop"] = true; apply()
        check(SourceSelection.selectionCount == SourceSelection.minimumSelections, "SiYuan and two selected folders meet the new minimum")
        flags["dbg.run.downloads"] = false; flags["dbg.run.desktop"] = false; apply()
        SiYuanSource.isInstalled = false
        check(SourceSelection.selectionCount == 0 && SourceSelection.unavailableSourceMessages["SiYuan"] != nil, "missing SiYuan stays actionable without inflating the count")
        flags[SiYuanSource.enabledKey] = false; apply()
        check(SourceSelection.unavailableSourceMessages["SiYuan"] == nil, "SiYuan opt-out removes the unavailable selection")
        SiYuanSource.isInstalled = true
        check(SourceSelection.current().isEmpty, "an installed SiYuan workspace never grants implicit consent")
        WhatsAppSource.isInstalled = false; flags["dbg.run.whatsapp"] = true; apply()
        check(SourceSelection.shouldShowWhatsApp, "uninstalled selected WhatsApp remains visible for opt-out")
        flags["dbg.run.whatsapp"] = false; apply()
        check(!SourceSelection.shouldShowWhatsApp, "uninstalled unselected WhatsApp stays hidden")
        WhatsAppSource.isInstalled = true
        flags["dbg.run.downloads"] = true; flags["dbg.run.desktop"] = true
        flags[CustomRoots.key] = fixtureRoot.appendingPathComponent("Downloads").path + "\n" + fixtureRoot.appendingPathComponent("Downloads").path + "\n/missing/source"
        apply()
        check(SourceSelection.selectionCount == 2, "duplicate and unavailable folders do not inflate readiness")
        flags["dbg.run.downloads"] = false; flags["dbg.run.desktop"] = false; flags[CustomRoots.key] = ""
        flags["dbg.run.imessage"] = true; flags["dbg.imessage.chats"] = "selected"
        apply()
        check(SourceSelection.selectionCount == 0, "selected missing protected data is not ready")
        check(SourceSelection.unavailableSourceMessages["iMessage"] != nil, "missing selected local source remains an actionable issue")
        flags["dbg.run.gmail"] = true; apply()
        check(SourceSelection.selectionCount == 0, "selected disconnected hosted source is not ready")
        flags["dbg.gmail.connected"] = true; apply()
        check(SourceSelection.selectionCount == 0, "global connected flag cannot prove a current-provider connection")
        ConnectorCensus.records = [.init(slug: "gmail", healthy: false)]
        check(SourceSelection.selectionCount == 0, "cached disconnection overrides old connected flag")
        check(SourceSelection.unavailableSourceMessages["Gmail"] != nil
            && SourceSelection.unavailableConnectorSlugs.contains("gmail"), "disconnected selected mail is reported and excluded from downstream fetches")
        ConnectorCensus.records = [.init(slug: "gmail", healthy: true), .init(slug: "google-calendar", healthy: true)]
        flags["dbg.run.calendar"] = true; flags["dbg.calendar.connected"] = true; apply()
        ConnectorRegistry.selected = [.init(slug: "drive", healthy: true), .init(slug: "missing", healthy: false)]
        check(SourceSelection.selectionCount == 3 && SourceSelection.current().isEmpty, "three cloud sources complete selection without FDA or local data")
        ConnectorCensus.records = [.init(slug: "gmail", healthy: true, readinessVerified: nil), .init(slug: "google-calendar", healthy: true, readinessVerified: nil)]
        ConnectorRegistry.selected = [.init(slug: "drive", healthy: true, readinessVerified: nil)]
        check(SourceSelection.selectionCount == 0 && !SourceSelection.hostedSourceCanAttempt("gmail"), "three unverified declarations cannot admit a new first analysis")
        ProcessingPlan.completed = true
        check(SourceSelection.hostedSourceCanAttempt("gmail") && SourceSelection.connectorsToAttempt.count == 1,
              "completed legacy users still attempt healthy opted-in sources without a new marker")
        ConnectorCensus.records = [.init(slug: "gmail", healthy: false, readinessVerified: nil)]
        check(!SourceSelection.hostedSourceCanAttempt("gmail"), "known disconnected legacy sources do not become ready")
        ProcessingPlan.completed = false
        ConnectorCensus.records = [.init(slug: "gmail", healthy: true), .init(slug: "google-calendar", healthy: true)]
        ConnectorRegistry.selected = [.init(slug: "drive", healthy: true), .init(slug: "missing", healthy: false)]
        let enabled = WritingStyle.Selection()
        check(enabled.mail == ["gmail"] && !enabled.imessage && !enabled.whatsapp, "writing sources use enabled connected accounts only")
        flags["dbg.run.gmail"] = false; flags["dbg.run.imessage"] = false; apply()
        check(WritingStyle.Selection().mail.isEmpty, "saved mail opt-out excludes writing samples")
        ModelBackend.current = .custom
        check(SourceSelection.selectionCount == 1, "custom backend excludes hosted sources and retains direct readiness")
        ModelBackend.current = .chatgpt
        var db: OpaquePointer?
        let path = iMessageSource().dbPath
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ value: String) { precondition(sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK) }
        sql("CREATE TABLE chat (guid TEXT, chat_identifier TEXT, style INTEGER, is_filtered INTEGER, is_blackholed INTEGER)")
        sql("CREATE TABLE message (date INTEGER, text TEXT, attributedBody BLOB, is_from_me INTEGER, associated_message_type INTEGER, item_type INTEGER)")
        sql("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
        sql("INSERT INTO chat VALUES ('selected','Alex',45,0,0),('unselected','Other',45,0,0)")
        sql("INSERT INTO message VALUES (1,'SELECTED',NULL,1,0,0),(2,'DO NOT READ',NULL,1,0,0)")
        sql("INSERT INTO chat_message_join VALUES (1,1),(2,2)")
        check(try LocalWritingSamples.iMessage(path: path, names: [:], chatGUIDs: ["selected"]).map(\.text) == ["SELECTED"], "iMessage samples stay within selected chat IDs")
        check(try LocalWritingSamples.iMessage(path: path, names: [:], chatGUIDs: ["x') OR 1=1 --"]).isEmpty, "chat IDs cannot expand SQL scope")
        check(try LocalWritingSamples.iMessage(path: "/missing/never-opened", names: [:], chatGUIDs: []).isEmpty, "empty chat choices never open a database")
        flags["dbg.run.imessage"] = true; apply()
        check(WritingStyle.Selection().imessageGUIDs == ["selected"], "writing consent resumes exact saved chat selection")
        let consent = WritingStyle.selectionIdentity
        check(consent.hasSources && consent == WritingStyle.selectionIdentity, "writing selection identity is stable across repeated reads")
        flags["dbg.imessage.chats"] = "replacement"; apply()
        check(consent != WritingStyle.selectionIdentity, "a deliberate chat-scope change creates a distinct retry identity")
        flags["dbg.imessage.chats"] = "selected"; apply()
        flags["dbg.run.imessage"] = false; apply()
        check(!WritingStyle.Selection().imessage, "present readable local database never grants implicit consent")
        check(!WritingStyle.hasSources && !WritingStyle.selectionIdentity.hasSources, "no selected writing sources disables automatic collection")
        var wa: OpaquePointer?
        let waPath = WhatsAppSource().dbPath
        precondition(sqlite3_open(waPath, &wa) == SQLITE_OK)
        defer { sqlite3_close(wa) }
        func waSQL(_ value: String) { precondition(sqlite3_exec(wa, value, nil, nil, nil) == SQLITE_OK) }
        waSQL("CREATE TABLE ZWACHATSESSION (Z_PK INTEGER, ZCONTACTJID TEXT, ZSESSIONTYPE INTEGER, ZPARTNERNAME TEXT)")
        waSQL("CREATE TABLE ZWAMESSAGE (Z_PK INTEGER, ZCHATSESSION INTEGER, ZMESSAGEDATE REAL, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZTEXT TEXT)")
        waSQL("INSERT INTO ZWACHATSESSION VALUES (1,'selected@s.whatsapp.net',0,'Alex'),(2,'other@s.whatsapp.net',0,'Other')")
        waSQL("INSERT INTO ZWAMESSAGE VALUES (1,1,1,1,0,'SELECTED'),(2,2,2,1,0,'DO NOT READ')")
        check(try LocalWritingSamples.whatsApp(path: waPath, chatJIDs: ["selected@s.whatsapp.net"]).map(\.text) == ["SELECTED"], "WhatsApp samples stay within selected chat IDs")
        check(try LocalWritingSamples.whatsApp(path: "/missing/never-opened", chatJIDs: []).isEmpty, "empty WhatsApp choices never open a database")
        print("Source consent regression checks passed")
    }
}
'''

writing_source = (APP / 'Vault/WritingStyle.swift').read_text()
selection = '\n'.join(declaration(writing_source, signature) for signature in ('@MainActor struct Selection', '@MainActor static var selectionIdentity:', '@MainActor static var hasSources:'))
production = '\n'.join((APP / filename).read_text() for filename in (
    'Sources/SourceSelection.swift', 'Sources/SQLiteDB.swift', 'Sources/LocalWritingSamples.swift'))
source = stubs + production + '\nenum WritingStyle {\n' + selection + '\n}\n' + checks
with tempfile.TemporaryDirectory(prefix='sentient-source-consent-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check'), str(path)], check=True)
