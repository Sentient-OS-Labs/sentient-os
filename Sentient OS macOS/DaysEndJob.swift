//
//  DaysEndJob.swift
//  Sentient OS macOS
//
//  THE day's-end entry point (Part II §A) — the one function the knowledge-base lifecycle
//  hangs off: editor-idle check → iterative updater → mirror push → notification. Idempotent
//  and safe to re-invoke (an empty unsynced queue is a cheap no-op); single-flight (a trigger
//  while running is ignored).
//
//  Proactive intelligence is deliberately NOT in this pipeline (June 11 decision — it's being
//  built separately, with its own trigger, scheduled to run AFTER a knowledge-base update;
//  the removed working scaffold lives in git history at 67d8078).
//
//  TRIGGERS: today, only the dev "Update Knowledge Base" button in RootView. The
//  condition-gate scheduler (Phase 3, deliberately NOT built yet) will simply call
//  `DaysEndJob.shared.run(...)` on its own clock — no logic lives in the button that the
//  scheduler would need to duplicate.
//
//  Doc: Documentation/Days-End Job (Living System).md
//

import Foundation

actor DaysEndJob {

    static let shared = DaysEndJob()

    /// Single-flight: an actor bool, not a queue (per the handoff — no bookkeeping).
    private var running = false

    /// The day's-end pipeline. Returns a one-line status for the dev button / logs.
    @discardableResult
    func run(store: Store) async -> String {
        guard !running else { return "Already running — trigger ignored." }
        running = true
        defer { running = false }

        // Editor-idle guard: never block/wait — skip and let the next trigger retry.
        if await VaultActivity.shared.editorBusy {
            return "Vault editor is busy — skipped (next trigger retries)."
        }

        var parts: [String] = []

        // 1) The iterative updater (the heart). A usage limit keeps its session for resume;
        //    any other failure restored the vault snapshot — either way the unstamped rows
        //    re-enter the queue and the run continues to the push step (vaultDirty may still
        //    be set from an earlier change).
        var folded = 0
        do {
            folded = try await VaultUpdater.shared.runDailyUpdate(store: store)
            // N = summaries the updater REVIEWED (and stamped) — it folds in only what's
            // worth keeping; reviewing everything and changing nothing is a valid outcome.
            parts.append(folded == 0 ? "nothing new to fold" : "reviewed \(folded) new memories")
        } catch {
            parts.append((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        // 2) Mirror push — any run that ends with a dirty vault and the mirror enabled.
        parts.append(await pushIfDirty())

        // 3) Quiet by design: notify only when there was something to review.
        if folded > 0 {
            await Notify.now(title: "Your knowledge base is up to date",
                             body: "Caught up on \(folded) new \(folded == 1 ? "memory" : "memories") while your Mac rested.")
        }
        let status = "Done — " + parts.joined(separator: " · ")
        Log("DaysEndJob: \(status)")
        return status
    }

    /// The push rule (Part II §C): vaultDirty + mirror enabled → push; clear the flag ONLY on
    /// success (a transient network failure keeps it set for the next run). Also called after
    /// initial generation — the auto-push wiring file 2 §7 flagged as missing.
    func pushIfDirty() async -> String {
        guard await VaultActivity.shared.vaultDirty else { return "mirror: nothing to push" }
        guard await MirrorClient.shared.isEnabled else { return "mirror: off" }
        do {
            try await MirrorClient.shared.push()
            await MainActor.run { VaultActivity.shared.vaultDirty = false }
            return "mirror: pushed ✓"
        } catch {
            return "mirror: push failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)")) — will retry next run"
        }
    }
}
