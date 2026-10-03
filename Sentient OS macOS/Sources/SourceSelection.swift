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
    static var chatJIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.whatsapp.chats") ?? "")
            .split(separator: ",").map(String.init))
    }
    static var imessageGUIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.imessage.chats") ?? "")
            .split(separator: ",").map(String.init))
    }

    /// How many SELECTIONS are armed — every folder (default or custom), each chat source with
    /// chats picked, Notes, and each selected cloud source counts as ONE. The shared minimum
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
        if !AppleMailSelection.accounts.isEmpty { n += 1 }
        if AppleCalendarSource.isEnabled { n += 1 }
        // Hosted Gmail and Calendar need a subscription backend, so they cannot count
        // toward the minimum on a custom endpoint.
        if ModelBackend.connectorsAvailable {
            if bool("dbg.run.gmail", default: false) { n += 1 }
            if bool("dbg.run.calendar", default: false) { n += 1 }
        }
        // The registry gates hosted and direct sources separately. Direct connections also
        // work on custom backends and must count toward onboarding's minimum there.
        n += ConnectorRegistry.kbEnabledConnectors().count
        return n
    }

    /// The onboarding recommendation follows the sources selected for the first analysis.
    /// A connected account that the user opted out of reading does not supply this context.
    /// Use curated identities so Gmail/Google Calendar, Outlook, and mixed pairs all count.
    static var hasEmailAndCalendar: Bool {
        let packs = ConnectorRegistry.kbEnabledConnectors().compactMap { ConnectorRegistry.pack(for: $0) }
        let email = (ModelBackend.connectorsAvailable && bool("dbg.run.gmail", default: false))
            || !AppleMailSelection.accounts.isEmpty
            || packs.contains { $0.slug == OutlookMailConnector.slug }
        let calendar = (ModelBackend.connectorsAvailable && bool("dbg.run.calendar", default: false))
            || packs.contains { $0.providesCalendarContext }
            || AppleCalendarSource.isEnabled
        return email && calendar
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
        // Include selected Mail even when the broad FDA probe fails: its own read reports a
        // useful error instead of silently disappearing from analysis.
        if !AppleMailSelection.accounts.isEmpty { s.append(.appleMail(accounts: AppleMailSelection.accounts)) }
        if AppleCalendarSource.isEnabled { s.append(.appleCalendar(calendarIDs: AppleCalendarSource.selectedIDs)) }
        return s
    }

    private static func bool(_ key: String, default def: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? def
    }
}
