//
//  AddressBookNames.swift
//  Sentient OS macOS
//
//  Maps raw iMessage handles ("+14155551234" / "friend@icloud.com") → contact display names by
//  reading the Mac's AddressBook SQLite stores directly. chat.db stores no names at all, and the
//  official Contacts framework would add a brand-new permission prompt to onboarding — Full Disk
//  Access already covers these files, so we read them like every other DB source: WAL-safe copy →
//  read → delete.
//
//  Matching: emails compare lowercased; phones compare on a LAST-10-DIGIT suffix, because chat.db
//  holds E.164 ("+14155551234") while AddressBook holds whatever the user typed ("(415) 555-1234").
//  Key methods: loadMap() → [key: name] over every store · resolve(_:in:) for one handle.
//

import Foundation

enum AddressBookNames {
    /// One pass over every AddressBook store on this Mac (the root store + one per synced
    /// account under Sources/) → [normalized handle key: display name]. Best-effort: a missing
    /// or unreadable store contributes nothing. Build once per scan, not per message.
    static func loadMap() -> [String: String] {
        var map: [String: String] = [:]
        let fm = FileManager.default
        let abRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AddressBook")

        var stores = [abRoot.appendingPathComponent("AddressBook-v22.abcddb").path]
        // §7.6: the ROOT store being absent is the classic `v22 → v23` file-rename tripwire — contact
        // resolution then silently returns nothing (everyone shows as a raw phone/email). (A column
        // rename is caught separately by SQLiteDB's `db.schema_error`, §7.7.)
        if !fm.fileExists(atPath: stores[0]) {
            CrashReporting.captureEvent("addressbook.no_store", level: .warning,
                tags: ["path_version": "v22"], fingerprint: ["addressbook", "no_store"])
        }
        let sourcesDir = abRoot.appendingPathComponent("Sources")
        if let accounts = try? fm.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil) {
            stores += accounts.map { $0.appendingPathComponent("AddressBook-v22.abcddb").path }
        }
        for store in stores where fm.fileExists(atPath: store) {
            merge(store: store, into: &map)
        }
        return map
    }

    /// Resolve one chat.db handle against the map. nil = not in Contacts (caller shows a
    /// cleaned raw handle instead).
    static func resolve(_ handle: String, in map: [String: String]) -> String? {
        map[key(for: handle)]
    }

    /// Normalize a handle/phone/email into a lookup key: lowercased for emails, last-10-digit
    /// suffix for phones (short codes with fewer digits key as-is).
    static func key(for handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    // MARK: One store → the map

    private static func merge(store: String, into map: inout [String: String]) {
        guard let (dbURL, tempDir) = try? SQLiteDB.walSafeCopy(of: store) else { return }
        defer { try? FileManager.default.removeItem(at: tempDir) }
        guard let reader = try? SQLiteReader(path: dbURL.path) else { return }

        // Record pk → display name ("First Last" → organization → nickname).
        var names: [Int64: String] = [:]
        try? reader.forEachRow("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION, ZNICKNAME FROM ZABCDRECORD") { r in
            let person = [r.text(1), r.text(2)].compactMap { $0 }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let name = !person.isEmpty ? person : (r.text(3) ?? r.text(4) ?? "")
            if !name.isEmpty { names[r.int(0)] = name }
        }

        try? reader.forEachRow("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER") { r in
            guard let name = names[r.int(0)], let number = r.text(1) else { return }
            let k = key(for: number)
            if !k.isEmpty, map[k] == nil { map[k] = name }
        }
        try? reader.forEachRow("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS") { r in
            guard let name = names[r.int(0)], let address = r.text(1) else { return }
            let k = key(for: address)
            if !k.isEmpty, map[k] == nil { map[k] = name }
        }
    }
}
