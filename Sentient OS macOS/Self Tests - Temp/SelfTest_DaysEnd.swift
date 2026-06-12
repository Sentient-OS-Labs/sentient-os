//
//  SelfTest_DaysEnd.swift — the iterative-updater harness (Part II)
//  Sentient OS macOS
//
//  One REAL-cloud mode (it spends a little cloud budget), dispatched from SelfTest:
//
//    SENTIENT_SELFTEST=daysend SENTIENT_VAULT_ROOT=/tmp/some-scratch-dir
//      Fixture vault + in-memory store seeded with unsynced summaries → DaysEndJob.run()
//      → asserts the vault changed, exactly the sent rows got stamped, and a second run
//      is a clean no-op. SENTIENT_VAULT_ROOT is REQUIRED (protects the real vault); add
//      SENTIENT_MIRROR_BASE for a local mirror push, otherwise the push step must be off.
//
//  Safety: daysend REFUSES to run if the mirror is enabled but SENTIENT_MIRROR_BASE isn't
//  set — the push step would replace the user's real hosted mirror with the fixture vault.
//

#if DEBUG
import Foundation
import SwiftData

enum SelfTestDaysEnd {

    // MARK: Shared plumbing

    private static func freshStore(emit: (String) -> Void) -> Store? {
        do {
            let container = try ModelContainer(for: Summary.self, SourceCursor.self,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            return Store(modelContainer: container)
        } catch { emit("ModelContainer FAILED: \(error)"); return nil }
    }

    /// Seed one survivor summary through the REAL record path (synthetic candidate → artifact).
    private static func seed(_ store: Store, id: String, title: String, text: String) async {
        let cand = Candidate(id: id, kind: .file,
                             cursorKey: "file:fixture", cursorValue: "\(Date().timeIntervalSince1970)|\(id)",
                             itemDate: Date(), metadata: ["folder": "Fixture", "name": title])
        let artifact = Artifact(candidate: cand, text: text)
        try? await store.record(artifact: artifact, verdict: .survivor,
                                summary: SummaryDraft(text: text, title: title))
    }

    private static func codexReady(emit: (String) -> Void) async -> Bool {
        let availability = await CodexCLI.shared.validate()
        guard case .available = availability else {
            emit("SKIP — Codex unavailable: \(availability)")
            return false
        }
        return true
    }

    // MARK: daysend

    static func daysend(emit: (String) -> Void) async {
        guard await codexReady(emit: emit) else { return }
        let env = ProcessInfo.processInfo.environment

        // The vault override is mandatory: this harness writes into the vault root.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sentient OS -- The Vault").path
        guard let scratch = env["SENTIENT_VAULT_ROOT"], !scratch.isEmpty, scratch != home else {
            emit("SET SENTIENT_VAULT_ROOT to a scratch dir (NOT the real vault) and re-run.")
            return
        }
        // Never let the push step clobber the user's real hosted mirror with a fixture vault.
        if await MirrorClient.shared.isEnabled && env["SENTIENT_MIRROR_BASE"] == nil {
            emit("ABORT — the mirror is enabled but SENTIENT_MIRROR_BASE isn't set: the push "
                 + "step would replace your real hosted mirror with the fixture vault. "
                 + "Set SENTIENT_MIRROR_BASE to a local server or disable the mirror first.")
            return
        }

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            emit("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }

        // Fixture vault: a README portrait + one domain note, like a miniature real vault.
        let fm = FileManager.default
        let vault = URL(fileURLWithPath: scratch, isDirectory: true)
        try? fm.removeItem(at: vault)
        try? fm.createDirectory(at: vault.appendingPathComponent("Life"), withIntermediateDirectories: true)
        try? """
        # README
        Fixture human. Software engineer in SF; plans a lot of trips; takes notes about coffee.
        ## Map
        - Life/ — everything so far
        """.write(to: vault.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? """
        ---
        title: Coffee Notes
        tags: [coffee]
        refs: [1]
        ---
        # Coffee Notes
        The user likes light-roast pour-overs.
        """.write(to: vault.appendingPathComponent("Life/Coffee Notes.md"), atomically: true, encoding: .utf8)
        let before = VaultUpdater.skeleton(of: vault)

        guard let store = freshStore(emit: emit) else { return }
        await seed(store, id: "file:/tmp/fixture/lisbon.md", title: "Lisbon Trip Planning",
                   text: "The user booked flights to Lisbon for July 18–25 and is comparing hotels in Alfama.")
        await seed(store, id: "file:/tmp/fixture/espresso.md", title: "New Espresso Machine",
                   text: "The user ordered a Gaggia Classic Pro and is researching dial-in recipes.")
        let queued = await store.unsyncedSummaries()
        check("seeded queue", queued.count == 2, "\(queued.count)")

        emit("\nrunning DaysEndJob (real cloud call — ~a minute)…")
        let status = await DaysEndJob.shared.run(store: store)
        emit("status: \(status)\n")

        let after = VaultUpdater.skeleton(of: vault)
        let readme = (try? String(contentsOf: vault.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        let coffee = (try? String(contentsOf: vault.appendingPathComponent("Life/Coffee Notes.md"), encoding: .utf8)) ?? ""
        check("status reports the review", status.contains("reviewed 2"), status)
        check("exactly the sent rows stamped", await store.unsyncedSummaries().isEmpty)
        check("vault actually changed",
              before != after || coffee.contains("Gaggia") || readme.contains("Lisbon")
              || after.contains("Lisbon") || after.contains("Espresso"),
              "skeleton before \(before.split(separator: "\n").count) → after \(after.split(separator: "\n").count) notes")

        let second = await DaysEndJob.shared.run(store: store)
        check("second run is a no-op", second.contains("nothing new to fold"), second)

        emit("\nvault skeleton after:\n\(after)")
        emit("\n# \(fail == 0 ? "✅ ALL PASS" : "❌ FAILURES") — \(pass) passed · \(fail) failed")
    }
}
#endif
