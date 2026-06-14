//
//  VaultActivity.swift
//  Sentient OS macOS
//
//  The editor-idle / mirror-push seam (Part II §C). The Phase-5 vault editor doesn't exist
//  yet, so this is deliberately just the SEAM, not the feature:
//   - editorBusy:  true while the editor has unsaved changes (always false today; the editor
//                  sets it later). A future scheduler will check it and skip rather than wait.
//                  (No consumer today — the old DaysEndJob that checked it was removed in the
//                  files-iterative rebuild.)
//   - vaultDirty:  set by ANYTHING that changes the local vault (initial gen, FileVaultCloud's
//                  create/update, future editor saves). Cleared only after a successful mirror
//                  push (FileVaultCloud.markDirtyAndPush). Persisted in UserDefaults so a quit
//                  between change and push can't lose the pending push.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class VaultActivity {
    static let shared = VaultActivity()

    /// The vault editor has unsaved changes — a future scheduler will skip and retry next trigger.
    var editorBusy = false

    private static let dirtyKey = "vault.dirty"

    /// The local vault changed since the last successful mirror push.
    var vaultDirty: Bool {
        didSet { UserDefaults.standard.set(vaultDirty, forKey: Self.dirtyKey) }
    }

    private init() {
        vaultDirty = UserDefaults.standard.bool(forKey: Self.dirtyKey)
    }
}
