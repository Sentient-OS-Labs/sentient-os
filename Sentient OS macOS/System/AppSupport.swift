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
    /// first access; idempotent. Nonisolated on purpose: pure filesystem, read from actors and
    /// background helpers alike (the cycle store, the disk-space guard, the model download).
    nonisolated static var sentientSupport: URL {
        #if DEBUG
        // The native prompt-path acceptance lab must redirect storage before AppState creates
        // its conversation singleton. A different bundle ID alone does not isolate this path.
        // Fail closed: an incomplete fixture configuration must never open real app data.
        if ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "sidekickapp" {
            guard let path = ProcessInfo.processInfo.environment["LAB_SIDEKICK_ROOT"], path.hasPrefix("/") else {
                preconditionFailure("Sidekick app acceptance requires an isolated fixture root")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard root.lastPathComponent.hasPrefix("sentient-sidekick-app-"),
                  root.resolvingSymlinksInPath() == root,
                  (try? String(contentsOf: root.appendingPathComponent(".sidekick-app-fixture"), encoding: .utf8)) == "1\n" else {
                preconditionFailure("Sidekick app acceptance root is not an owned fixture")
            }
            let dir = root.appendingPathComponent("support", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return dir
        }
        #endif
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SentientOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
