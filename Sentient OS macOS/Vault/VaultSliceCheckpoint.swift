// A same-volume copy of the last completed vault batch. Restore only after the writing child
// stops; never copy a timed-out batch into the live knowledge base.
// Doc: Documentation - Knowledge Base (Vault).md

import Foundation

nonisolated struct VaultSliceCheckpoint {
    let staging: URL
    let backup: URL

    init(staging: URL) throws {
        self.staging = staging
        backup = staging.deletingLastPathComponent().appendingPathComponent(staging.lastPathComponent + "-checkpoint-" + UUID().uuidString)
        do { try FileManager.default.copyItem(at: staging, to: backup) }
        catch { try? FileManager.default.removeItem(at: backup); throw error }
    }

    func restore() throws {
        _ = try FileManager.default.replaceItemAt(staging, withItemAt: backup)
    }

    func discard() { try? FileManager.default.removeItem(at: backup) }
}
