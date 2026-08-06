//
//  DerivedKnowledgeReset.swift
//  Sentient OS macOS
//
//  Privacy removal for one cloud source. Because the synthesized vault has source-level rather
//  than claim-level lineage, removal wipes all derived knowledge and rebuilds from the remaining
//  selected sources while preserving account links, setup, backend, onboarding, and preferences.
//

import Foundation

extension Notification.Name {
    static let sentientRebuildRequested = Notification.Name("sentient.rebuild-requested")
}

enum DerivedKnowledgeReset {
    enum ResetError: LocalizedError {
        case pipelineRunning
        var errorDescription: String? {
            "Wait for the current analysis to finish before removing imported knowledge."
        }
    }

    @MainActor
    static func removeImportedKnowledge(from source: SourceSelection.CloudSource) async throws {
        guard !PipelineActivity.shared.isRunning else { throw ResetError.pipelineRunning }

        // Disable first. If the app quits anywhere below, the forbidden source cannot be read again.
        await SourceSelection.stopUsing(source)
        await VaultCloud.shared.discardResumableBuilds()
        await CycleStore.shared.wipeEverything()       // all pointers + summaries; remaining sources backfill
        try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
        ProactiveCycle.resetAll()
        LifetimeStats.reset()
        OvernightCaution.clear()
        await VaultProvenanceStore.shared.reset()
        await CodexAccessLedger.shared.clear(source: source)
        try? await MirrorClient.shared.deleteRemote()  // keeps mirror opt-in and credentials
        VaultActivity.shared.vaultDirty = false

        if SourceSelection.selectionCount > 0 {
            NotificationCenter.default.post(name: .sentientRebuildRequested, object: nil)
        }
        Log("DerivedKnowledgeReset: removed \(source.rawValue) knowledge and requested a clean rebuild")
    }
}
