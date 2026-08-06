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

/// User-added folder roots, persisted. Stored as ONE newline-joined string of absolute paths so
/// views can watch it with a plain `@AppStorage(CustomRoots.key)` and react to edits made from
/// any window (Settings, Dev Tools).
enum CustomRoots {
    static let key = "files.customRoots"

    static func decode(_ raw: String) -> [URL] {
        raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
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

/// One-shot reader of the source-picker prefs (same keys as the @AppStorage copies in the views;
/// defaults must match: folder toggles ON, DB sources OFF).
///
/// ⚠️ The `dbg.*` prefix is HISTORICAL — these ARE the production preference keys (Settings, the
/// home popover, Dev Tools, and the 3am run all share them). Never rename them casually: they're
/// persisted on user machines, and a rename without a migration silently resets everyone's setup.
enum SourceSelection {
    enum CloudSource: String, Sendable, Codable, CaseIterable {
        case gmail, calendar

        var connectedKey: String { self == .gmail ? "dbg.gmail.connected" : "dbg.calendar.connected" }
        var selectedKey: String { self == .gmail ? "dbg.run.gmail" : "dbg.run.calendar" }
        var bucketKey: String { rawValue }
        var displayName: String { self == .gmail ? "Gmail" : "Google Calendar" }
    }

    enum AuthorizationError: LocalizedError {
        case notAuthorized(CloudSource)
        var errorDescription: String? {
            switch self {
            case .notAuthorized(let source):
                return "\(source.displayName) is not enabled for Sentient."
            }
        }
    }

    /// The only production authorization predicate for account-backed data. A linked account is
    /// not consent to use it, and a selected source cannot run on a backend without connectors.
    static func isAuthorized(_ source: CloudSource) -> Bool {
        ModelBackend.connectorsAvailable
            && bool(source.connectedKey, default: false)
            && bool(source.selectedKey, default: false)
    }

    static func requireAuthorized(_ source: CloudSource) throws {
        guard isAuthorized(source) else { throw AuthorizationError.notAuthorized(source) }
    }

    /// Privacy stop: leave the OpenAI account link intact, disable Sentient's use immediately,
    /// and erase the source's summaries and high-water cursor so re-enabling starts transparently.
    static func stopUsing(_ source: CloudSource) async {
        UserDefaults.standard.set(false, forKey: source.selectedKey)
        await CycleStore.shared.clearBucket(source.bucketKey)
    }

    static var chatJIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.whatsapp.chats") ?? "")
            .split(separator: ",").map(String.init))
    }
    static var imessageGUIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.imessage.chats") ?? "")
            .split(separator: ",").map(String.init))
    }

    /// How many SELECTIONS are armed — every folder (default or custom), each chat source with
    /// chats picked, Notes, and each connected cloud source counts as ONE. The shared minimum
    /// (at least 4) that onboarding's ready screen and Settings both enforce: the defaults alone
    /// (three folders) deliberately don't pass, so starting always takes one deliberate connect.
    static let minimumSelections = 4
    static var selectionCount: Int {
        var n = 0
        if bool("dbg.run.downloads", default: true) { n += 1 }
        if bool("dbg.run.desktop", default: true) { n += 1 }
        if bool("dbg.run.documents", default: true) { n += 1 }
        n += CustomRoots.urls.count
        if bool("dbg.run.whatsapp", default: false) && !chatJIDs.isEmpty { n += 1 }
        if bool("dbg.run.imessage", default: false) && !imessageGUIDs.isEmpty { n += 1 }
        if bool("dbg.run.notes", default: false) { n += 1 }
        // The cloud connectors ride ChatGPT auth inside codex — on a custom frontier backend
        // they can't run, so they don't count toward the minimum either.
        if isAuthorized(.gmail) { n += 1 }
        if isAuthorized(.calendar) { n += 1 }
        return n
    }

    static func current(fdaGranted: Bool) -> [RunSource] {
        var s: [RunSource] = []
        if bool("dbg.run.downloads", default: true) { s.append(.files(.downloads)) }
        if bool("dbg.run.desktop", default: true) { s.append(.files(.desktop)) }
        if bool("dbg.run.documents", default: true) { s.append(.files(.documents)) }
        s.append(contentsOf: CustomRoots.urls.map { .files(.custom($0)) })
        if bool("dbg.run.whatsapp", default: false) && fdaGranted && WhatsAppSource.isInstalled && !chatJIDs.isEmpty {
            s.append(.whatsapp(chatJIDs: chatJIDs))
        }
        if bool("dbg.run.imessage", default: false) && fdaGranted && !imessageGUIDs.isEmpty {
            s.append(.imessage(chatGUIDs: imessageGUIDs))
        }
        if bool("dbg.run.notes", default: false) && fdaGranted { s.append(.notes) }
        return s
    }

    private static func bool(_ key: String, default def: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? def
    }
}
