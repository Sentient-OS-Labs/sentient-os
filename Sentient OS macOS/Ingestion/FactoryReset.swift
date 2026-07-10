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
    static func run(appState: AppState? = nil) async {
        await CycleStore.shared.wipeEverything()
        try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
        ProactiveCycle.resetAll()
        LifetimeStats.reset()
        try? await MirrorClient.shared.deleteRemote()   // best-effort — offline reset still works
        let d = UserDefaults.standard
        d.removeObject(forKey: "onboarding.step")
        d.removeObject(forKey: CodexAuth.kbOnlyKey)     // the crossroads re-detects the plan fresh
        d.removeObject(forKey: AppState.onboardingKey)
        d.removeObject(forKey: ComputerUseGate.screenRecordingOfferedKey)   // re-offer Sentient's screen recording on rebuild
        // The overnight scheduler starts over too: the 18h clock re-stamps at the REBUILD's first
        // cycle (not the wiped one's), the auto-enable one-shot is re-armed, and the production
        // flag comes off — otherwise a 3am run could fire mid-onboarding, racing the user's own
        // first analysis on an empty store. (The dev toggle and the installed helper survive —
        // one is a dev choice, the other a grant, not a learning.)
        d.removeObject(forKey: OvernightScheduler.firstCycleAtKey)
        d.removeObject(forKey: OvernightScheduler.autoEnableFiredKey)
        d.removeObject(forKey: OvernightScheduler.prodEnabledKey)
        appState?.scheduler.needsSchedulerSetup = false
        appState?.scheduler.reevaluate()                // prod flag is gone → stops the loop + cancels the armed wake
        appState?.hasCompletedOnboarding = false        // live flip (didSet re-persists false)
        Log("FactoryReset: wiped cycle store + knowledge base + proactive traces + lifetime counters + cloud mirror copy + scheduler state · rewound to onboarding")
    }
}
