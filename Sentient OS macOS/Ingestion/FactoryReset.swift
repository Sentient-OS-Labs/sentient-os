//
//  FactoryReset.swift
//  Sentient OS macOS  ·  Ingestion/
//
//  The one full wipe, shared by Settings → Permissions & Health (the user-facing Reset) and the
//  dev tools' "Reset everything": the cycle store (pointers + summaries), the knowledge base
//  folder, every persisted proactive trace, and the lifetime counters. Deliberately NOT touched:
//  the cloud mirror (the next processed push whole-replaces it; the 30-day lease is the backstop
//  if the user never comes back), the mirror token (the share URL must survive), and the user's
//  source selections (those are choices, not learnings). A destructive sequence with two callers
//  must never drift — change it HERE only.
//

import Foundation

enum FactoryReset {
    @MainActor
    static func run() async {
        await CycleStore.shared.wipeEverything()
        try? FileManager.default.removeItem(at: VaultGenerator.vaultRoot)
        ProactiveCycle.resetAll()
        LifetimeStats.reset()
        Log("FactoryReset: wiped cycle store + knowledge base + proactive traces + lifetime counters")
    }
}
