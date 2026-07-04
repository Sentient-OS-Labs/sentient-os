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
enum SourceSelection {
    static var chatJIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.whatsapp.chats") ?? "")
            .split(separator: ",").map(String.init))
    }
    static var imessageGUIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: "dbg.imessage.chats") ?? "")
            .split(separator: ",").map(String.init))
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
