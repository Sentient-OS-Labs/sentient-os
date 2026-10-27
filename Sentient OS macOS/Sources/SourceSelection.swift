//
//  SourceSelection.swift
//  Sentient OS macOS  ·  Sources/
//
//  The ONE shared reader of the source-selection prefs (dbg.run.* toggles + the chat CSVs +
//  custom folder roots), so the home's Analyze Now, Dev Tools, the Settings sources pane, and
//  the 3am overnight run all act on EXACTLY the same selection. Lived in DevToolsView until the
//  real Settings shipped; moved here because it stopped being a dev-only concern.
//
//  CustomRoots is the persistent store for user-added folders — this replaces the old
//  session-only `@State customRoots` (whose known caveat was that a 3am run saw none of them).
//

import Foundation
import Darwin

/// User-added folder roots, persisted. Stored as ONE newline-joined string of absolute paths so
/// views can watch it with a plain `@AppStorage(CustomRoots.key)` and react to edits made from
/// any window (Settings, Dev Tools).
enum CustomRoots {
    static let key = "files.customRoots"

    static func decode(_ raw: String) -> [URL] {
        Array(Set(raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)).standardizedFileURL }))
            .sorted { $0.path < $1.path }
    }

    static var urls: [URL] {
        decode(UserDefaults.standard.string(forKey: key) ?? "")
    }

    static func add(_ url: URL) {
        var u = urls
        guard !u.contains(url) else { return }
        u.append(url)
        save(u)
    }

    static func remove(_ url: URL) {
        save(urls.filter { $0 != url })
    }

    private static func save(_ u: [URL]) {
        UserDefaults.standard.set(u.map(\.path).joined(separator: "\n"), forKey: key)
    }
}

/// A protected source is inspected only after its explicit selection or Connect action.
/// Opening the picker does not probe unrelated databases or request any system grant.
enum ProtectedLocalSource: String, Identifiable {
    case whatsapp, imessage, notes, mail
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whatsapp: "WhatsApp"
        case .imessage: "iMessage"
        case .notes: "Apple Notes"
        case .mail: "Apple Mail"
        }
    }
    var isReadable: Bool {
        let path: String
        switch self {
        case .whatsapp:
            guard WhatsAppSource.isInstalled else { return false }
            path = WhatsAppSource().dbPath
        case .imessage: path = iMessageSource().dbPath
        case .notes: path = NotesSource().dbPath
        case .mail:
            guard AppleMailSource.isSupported, let root = try? AppleMailSource.root() else { return false }
            path = root.appendingPathComponent("MailData/Envelope Index").path
        }
        // Open and close only this source; do not copy a database or read its contents.
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}

/// The historical dbg.* names are production preferences. All sources are opt-in on a new
/// installation; migration preserves the implicit folder choices of completed legacy setups.
enum SourceSelection {
    static let minimumSelections = 3
    static let pendingProtectedSourceKey = "sources.pendingProtectedSource"
    static let folderMigrationKey = "sources.explicitFolderConsent.v1"
    static let folderKeys = ["dbg.run.downloads", "dbg.run.desktop", "dbg.run.documents"]

    /// Call before constructing any AppStorage-backed picker. Never infer consent from merely
    /// finding a database, folder, installed app, or a connected account.
    static func migrateLegacyFolderDefaults(hadPersonalSetup: Bool, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: folderMigrationKey) else { return }
        for key in folderKeys where defaults.object(forKey: key) == nil {
            defaults.set(hadPersonalSetup, forKey: key)
        }
        defaults.set(true, forKey: folderMigrationKey)
    }

    static var shouldShowWhatsApp: Bool { WhatsAppSource.isInstalled || isSelected("dbg.run.whatsapp") }
    static var chatJIDs: Set<String> { csv("dbg.whatsapp.chats") }
    static var imessageGUIDs: Set<String> { csv("dbg.imessage.chats") }
    private static func csv(_ key: String) -> Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
    }
    static func isSelected(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var selectedProtectedSources: [ProtectedLocalSource] {
        var sources: [ProtectedLocalSource] = []
        if isSelected("dbg.run.whatsapp") && !chatJIDs.isEmpty { sources.append(.whatsapp) }
        if isSelected("dbg.run.imessage") && !imessageGUIDs.isEmpty { sources.append(.imessage) }
        if isSelected("dbg.run.notes") { sources.append(.notes) }
        if !AppleMailSelection.accounts.isEmpty { sources.append(.mail) }
        return sources
    }

    /// A connection belongs to the selected backend. Old global connected flags cannot prove
    /// a connection after a provider switch; preserve them, but require confirmation in that
    /// provider's census before counting the source. No live probe runs.
    static func hostedSourceReady(_ service: String) -> Bool {
        guard ModelBackend.connectorsAvailable,
              !(ModelBackend.current == .chatgpt && UserDefaults.standard.bool(forKey: CodexAuth.kbOnlyKey)),
              isSelected("dbg.run.\(service)"), isSelected("dbg.\(service).connected"),
              let origin = ConnectorCensus.DetectedConnector.Origin(backend: ModelBackend.current) else { return false }
        let slug = service == "calendar" ? "google-calendar" : service
        return ConnectorCensus.cached(for: origin).first(where: { $0.slug == slug })?.isReady ?? false
    }

    static var readyConnectors: [ConnectorCensus.DetectedConnector] {
        ConnectorRegistry.kbEnabledConnectors().filter(\.isReady)
    }

    /// Legacy completed users keep attempting explicitly selected healthy sources. A missing
    /// new verification marker is not a disconnection; first-setup counts remain stricter.
    static func hostedSourceCanAttempt(_ service: String) -> Bool {
        if hostedSourceReady(service) { return true }
        guard ProcessingPlan.initialCompletedAt() != nil, ModelBackend.connectorsAvailable,
              isSelected("dbg.run.\(service)"), isSelected("dbg.\(service).connected"),
              let origin = ConnectorCensus.DetectedConnector.Origin(backend: ModelBackend.current) else { return false }
        let slug = service == "calendar" ? "google-calendar" : service
        return ConnectorCensus.cached(for: origin).first(where: { $0.slug == slug })?.canAttempt(legacyCompleted: true) == true
    }
    static var connectorsToAttempt: [ConnectorCensus.DetectedConnector] {
        let completed = ProcessingPlan.initialCompletedAt() != nil
        return ConnectorRegistry.kbEnabledConnectors().filter { $0.canAttempt(legacyCompleted: completed) }
    }

    /// Each usable selected folder, conversation service, local app or connected cloud service
    /// counts once. Empty accounts/folders can be connected; readiness does not inspect content
    /// or promise that analysis will discover useful material.
    static var selectionCount: Int {
        current().count
            + (hostedSourceReady("gmail") ? 1 : 0)
            + (hostedSourceReady("calendar") ? 1 : 0)
            + readyConnectors.count
    }

    /// Preserve unavailable intent separately from runnable sources. A successful read of the
    /// remaining sources must never turn missing access into an apparently complete setup.
    static var unavailableSourceMessages: [String: String] {
        var issues: [String: String] = [:]
        let standard: [(String, FileRoot)] = [("dbg.run.downloads", .downloads),
            ("dbg.run.desktop", .desktop), ("dbg.run.documents", .documents)]
        for (key, root) in standard where isSelected(key) {
            if root.url.map({ folderIsReadable($0) }) != true {
                issues[root.label] = "This folder is unavailable. Restore access or remove it in Knowledge Sources, then retry."
            }
        }
        for url in CustomRoots.urls where !folderIsReadable(url) {
            issues[url.lastPathComponent] = "This folder is unavailable. Re-add it or remove it in Knowledge Sources, then retry."
        }
        if isSelected(SiYuanSource.enabledKey) && !SiYuanSource.isInstalled {
            issues["SiYuan"] = "Restore your SiYuan workspace or turn this source off in Knowledge Sources, then retry."
        }
        if !AppleMailSource.isSupported,
           !(UserDefaults.standard.string(forKey: AppleMailSelection.key) ?? "").isEmpty {
            issues["Apple Mail"] = "Apple Mail requires macOS 26 or later. Remove this source in Knowledge Sources or use a supported connection."
        }
        for source in selectedProtectedSources where !source.isReadable {
            issues[source.title] = "Open Knowledge Sources to restore access to \(source.title) and check its synced data, or remove this source."
        }
        if isSelected("dbg.run.imessage") && imessageGUIDs.isEmpty {
            issues["iMessage"] = "Choose at least one iMessage chat in Knowledge Sources, or turn this source off."
        }
        if isSelected("dbg.run.whatsapp") && chatJIDs.isEmpty {
            issues["WhatsApp"] = "Choose at least one WhatsApp chat in Knowledge Sources, or turn this source off."
        }
        if !AppleCalendarSource.selectedIDs.isEmpty && (!AppleCalendarSource.hasAccess
            || UserDefaults.standard.string(forKey: AppleCalendarSource.issueKey) == "missing") {
            issues["Apple Calendar"] = "Review Calendar access and selected calendars in Knowledge Sources, then retry or remove the source."
        }
        for (service, title) in [("gmail", "Gmail"), ("calendar", "Google Calendar")] {
            if isSelected("dbg.run.\(service)") && !hostedSourceCanAttempt(service) {
                issues[title] = "Reconnect \(title) for your current AI in Knowledge Sources, or turn this source off."
            }
        }
        for connector in ConnectorRegistry.kbEnabledConnectors() where !connector.canAttempt(legacyCompleted: ProcessingPlan.initialCompletedAt() != nil) {
            issues[connector.displayName] = "Reconnect this source in Knowledge Sources, or turn it off, then retry."
        }
        for pack in ConnectorRegistry.packs where ConnectorRegistry.isKBEnabled(pack.slug)
            && !ConnectorRegistry.kbEligible(pack.slug) {
            issues[pack.displayName] = "This selected source is unavailable with your current AI. Choose a supported connection or turn it off."
        }
        return issues
    }

    static var unavailableConnectorSlugs: Set<String> {
        var slugs = Set(ConnectorRegistry.kbEnabledConnectors().filter { !$0.canAttempt(legacyCompleted: ProcessingPlan.initialCompletedAt() != nil) }.map(\.slug))
        if isSelected("dbg.run.gmail") && !hostedSourceCanAttempt("gmail") { slugs.insert("gmail") }
        if isSelected("dbg.run.calendar") && !hostedSourceCanAttempt("calendar") { slugs.insert("google-calendar") }
        return slugs
    }

    static var hasEmailAndCalendar: Bool {
        let packs = readyConnectors.compactMap { ConnectorRegistry.pack(for: $0) }
        let email = hostedSourceReady("gmail")
            || (!AppleMailSelection.accounts.isEmpty && ProtectedLocalSource.mail.isReadable)
            || packs.contains { $0.slug == OutlookMailConnector.slug }
        let calendar = hostedSourceReady("calendar")
            || packs.contains { $0.providesCalendarContext }
            || AppleCalendarSource.isEnabled
        return email && calendar
    }

    static func current() -> [RunSource] { current(fdaGranted: true) }

    /// Compatibility argument for existing run callers. A broad FDA verdict alone never makes
    /// a source usable: each explicitly selected protected source must itself be readable.
    static func current(fdaGranted: Bool) -> [RunSource] {
        var sources: [RunSource] = []
        let standard: [(String, FileRoot)] = [("dbg.run.downloads", .downloads),
            ("dbg.run.desktop", .desktop), ("dbg.run.documents", .documents)]
        var seenFolders = Set<URL>()
        for (key, root) in standard where isSelected(key) {
            if let url = root.url?.standardizedFileURL, folderIsReadable(url), seenFolders.insert(url).inserted {
                sources.append(.files(root))
            }
        }
        for url in CustomRoots.urls where folderIsReadable(url) && seenFolders.insert(url).inserted {
            sources.append(.files(.custom(url)))
        }
        if SiYuanSource.isEnabled { sources.append(.siyuan) }
        if fdaGranted {
            for source in selectedProtectedSources where source.isReadable {
                switch source {
                case .whatsapp: sources.append(.whatsapp(chatJIDs: chatJIDs))
                case .imessage: sources.append(.imessage(chatGUIDs: imessageGUIDs))
                case .notes: sources.append(.notes)
                case .mail: sources.append(.appleMail(accounts: AppleMailSelection.accounts))
                }
            }
        }
        if AppleCalendarSource.isEnabled,
           UserDefaults.standard.string(forKey: AppleCalendarSource.issueKey) != "missing" {
            sources.append(.appleCalendar(calendarIDs: AppleCalendarSource.selectedIDs))
        }
        return sources
    }

    private static func folderIsReadable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }
}
