//
//  VaultActivity.swift
//  Sentient OS macOS
//
//  The vault-change / mirror-sync seam. Anything that mutates the local knowledge base — the cloud
//  KB build/update, and the Knowledge editor's saves / deletes / note-and-folder creation — routes
//  through here:
//   - vaultDirty:  set by any local vault change. Cleared only after a successful mirror push
//                  (VaultCloud.pushIfDirty). Persisted so a quit between change and push can't lose
//                  the pending push.
//   - editorBusy:  true while the Knowledge editor is mid-edit (a future scheduler skips + retries).
//   - markChanged() + syncState: the Knowledge editor calls markChanged() after every change; it
//                  DEBOUNCES the mirror push (one push 30s after the last change, so a delete/create
//                  spree coalesces into one) and drives the sidebar's sync-status line.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class VaultActivity {
    static let shared = VaultActivity()

    /// The Knowledge editor is mid-edit — a future scheduler will skip and retry next trigger.
    var editorBusy = false

    private static let dirtyKey = "vault.dirty"

    /// The local vault changed since the last successful mirror push.
    var vaultDirty: Bool {
        didSet { UserDefaults.standard.set(vaultDirty, forKey: Self.dirtyKey) }
    }

    // MARK: Debounced mirror sync (drives the Knowledge header's status line)

    enum SyncState { case synced, pending, syncing }
    private(set) var syncState: SyncState

    private var syncTask: Task<Void, Never>?
    private static let debounce: Duration = .seconds(30)

    private init() {
        let dirty = UserDefaults.standard.bool(forKey: Self.dirtyKey)
        vaultDirty = dirty
        syncState = dirty ? .pending : .synced
    }

    /// Call after ANY local vault change (editor save, note/folder create, delete). Marks the vault
    /// dirty and (re)schedules the debounced mirror push — a spree coalesces into ONE push 30s after
    /// the last change. Safe to call when the mirror is off (the push is a no-op and the state
    /// settles to `.synced`; the Knowledge header only shows the line when the mirror is on anyway).
    func markChanged() {
        vaultDirty = true
        syncState = .pending
        syncTask?.cancel()
        syncTask = Task { [self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            guard await MirrorClient.shared.isEnabled, vaultDirty else { syncState = .synced; return }
            syncState = .syncing
            await VaultCloud.pushIfDirty()                 // clears vaultDirty on success
            syncState = vaultDirty ? .pending : .synced    // still dirty → push failed → retries later
        }
    }
}
