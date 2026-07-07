//
//  FactoryReset.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  The one full wipe, shared by Settings → System (the user-facing Reset) and the dev tools'
//  "Reset everything": the cycle store (pointers + summaries), the knowledge base folder, every
//  persisted proactive trace, the lifetime counters, and the cloud mirror copy (best-effort
//  DELETE; an offline reset still succeeds locally, and the 30-day lease is the backstop).
//  Deliberately NOT touched: the mirror token + opt-in (the share URL pasted into the user's
//  connectors must survive — the next processed push recreates the copy), and the user's source
//  selections (those are choices, not learnings). A destructive sequence with two callers must
//  never drift — change it HERE only.
//

import Foundation

enum FactoryReset {
    @MainActor
    static func run() async {
        await CycleStore.shared.wipeEverything()
        try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
        ProactiveCycle.resetAll()
        LifetimeStats.reset()
        try? await MirrorClient.shared.deleteRemote()   // best-effort — offline reset still works
        Log("FactoryReset: wiped cycle store + knowledge base + proactive traces + lifetime counters + cloud mirror copy")
    }
}
