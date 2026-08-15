//
//  AppSupport.swift
//  Sentient OS macOS
//
//  The single owner of Sentient's on-disk home under Application Support. We're non-sandboxed (Full
//  Disk Access requires it), so ~/Library/Application Support is SHARED with every other app on the
//  Mac — nothing of ours may sit naked at its top level (that's how you collide with someone else's
//  "default.store"). Everything Sentient writes lives under ONE namespaced "SentientOS" root, so
//  "delete everything we wrote" is a single path. One accessor here means the path can never drift.
//

import Foundation

extension URL {
    /// `~/Library/Application Support/SentientOS/` — the root under which every Sentient on-disk
    /// artifact lives (the model + its cache, the iterative store, summary backups). Created on
    /// first access; idempotent.
    static var sentientSupport: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentientOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
