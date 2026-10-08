//
//  FactoryReset.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  The one full wipe, shared by Settings → System (the user-facing Reset) and the dev tools'
//  "Reset everything": the cycle store (pointers + summaries), the knowledge base folder, every
//  persisted proactive trace, the lifetime counters, the cloud mirror copy (best-effort DELETE;
//  an offline reset still succeeds locally, and the 30-day lease is the backstop) — and the
//  rewind to the START of onboarding (step, completion flag, the knowledge-base-only plan mode),
//  because "start over from scratch" means the setup too, and the free→Plus upgrade path's
//  "Reset & Rebuild" depends on re-running it. Deliberately NOT touched: the mirror token +
//  opt-in (the share URL pasted into the user's connectors must survive — the next processed
//  push recreates the copy), and the user's source selections (those are choices, not
//  learnings). A destructive sequence with two callers must never drift — change it HERE only.
//

import Foundation

enum FactoryReset {
    /// `appState` (both callers have it) gets the live rewind — the main window flips back to
    /// onboarding the moment the wipe finishes; the persisted flags below guarantee the same on
    /// the next launch regardless.
    @MainActor
    @discardableResult
    static func run(appState: AppState? = nil) async -> Bool {
        // Invalidate in-flight learning before any suspension; explicit settings survive.
        SidekickInstructionStore.resetLearning()
        await HostedConnectorSetup.beginTeardown()
        defer { HostedConnectorSetup.endTeardown() }
        // Retain contact records and their local identity, like invitation access. Reset clears
        // learned knowledge and app connections, not the founders' feedback contact list.
        do { try await DirectMCPConnections.shared.removeAll() }
        catch {
            Diagnostics.report(.cleanupFailed, phase: .reset, reason: "connector_credentials", error: error)
            Log("FactoryReset: direct-connection Keychain cleanup needs retry"); return false
        }
        await CycleStore.shared.wipeEverything()
        Diagnostics.removeForCleanup(VaultGenerator.vaultRoot, phase: .reset, reason: "vault")
        ProactiveCycle.resetAll()
        Diagnostics.removeForCleanup(OutlookCalendarToolPolicy.pendingDirectory, phase: .reset, reason: "pending_actions")
        LifetimeStats.reset()
        try? await MirrorClient.shared.deleteRemote()   // best-effort — offline reset still works
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("connectedEmail.") {
            d.removeObject(forKey: key)
        }
        d.removeObject(forKey: "onboarding.step")
        d.removeObject(forKey: CodexAuth.kbOnlyKey)     // the crossroads re-detects the plan fresh
        d.removeObject(forKey: CodexAuth.assertedPlusKey)   // …and asks again before trusting
        // The Frontier Model Choice (ModelBackend/CustomProvider + its Keychain key) SURVIVES
        // reset on purpose — like the wake helper it's a setup choice, not a learning; a rebuild
        // should come back up on the same engine. Uninstall is what destroys it.
        d.removeObject(forKey: AppState.onboardingKey)
        d.removeObject(forKey: ComputerUseGate.micSpeechOfferedKey)         // re-offer the optional voice grant on rebuild
        d.removeObject(forKey: HealthCaution.nativeComputerUseEverReadyKey)
        d.removeObject(forKey: HealthCaution.computerUseEverReadyKey)       // the home's computer-use banner re-arms at the rebuild's own gate
        SidekickHistory.reset()                                          // paired requests and outcomes start blank on rebuild
        // The overnight scheduler starts over too: the 14h clock re-stamps at the REBUILD's first
        // cycle (not the wiped one's), the auto-enable one-shot is re-armed, and the production
        // flag comes off — otherwise a 3am run could fire mid-onboarding, racing the user's own
        // first analysis on an empty store. (The dev toggle and the installed helper survive —
        // one is a dev choice, the other a grant, not a learning.)
        d.removeObject(forKey: OvernightScheduler.firstCycleAtKey)
        d.removeObject(forKey: OvernightScheduler.autoEnableFiredKey)
        d.removeObject(forKey: OvernightScheduler.prodEnabledKey)
        // Connectors: one namespaced sweep for the whole `mcp.` key family — the detected lists
        // (`mcp.connectors.*`), every per-connector KB toggle (`mcp.<slug>.kb`), and every
        // classifier cache (`mcp.classified.<slug>`), present and future. The rebuild re-detects
        // and re-classifies from scratch. ⚠️ `mcp.mirror.*` shares the prefix but belongs to the
        // MCP MIRROR, whose opt-in + last-push state deliberately SURVIVE reset (the share URL in
        // the user's connectors must keep working; see the header note) — hence the carve-out.
        for key in d.dictionaryRepresentation().keys
            where key.hasPrefix("mcp.") && !key.hasPrefix("mcp.mirror.") {
            d.removeObject(forKey: key)
        }
        appState?.scheduler.needsSchedulerSetup = false
        appState?.scheduler.reevaluate()                // prod flag is gone → stops the loop + cancels the armed wake
        appState?.hasCompletedOnboarding = false        // live flip (didSet re-persists false)
        ComputerUseUpgrade.shared.reset()              // clear pending migration after the onboarding rewind
        Log("FactoryReset: cleanup attempts finished; individual failures are reported · rewound to onboarding")
        return true
    }
}
