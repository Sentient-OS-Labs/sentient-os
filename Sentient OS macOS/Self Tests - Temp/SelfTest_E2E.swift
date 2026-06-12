//
//  SelfTest_E2E.swift — the full incremental loop, headless (analysis → updater → repeat)
//  Sentient OS macOS
//
//  The end-to-end proof of the iterative system on REAL machinery: the actual on-device
//  Engine summarizes a fixture folder through the actual Pipeline (pointers and all), then
//  the actual DaysEndJob folds the survivors into a fixture vault via codex. Then a NEW file
//  appears, and the loop runs again — asserting the pointer picks up ONLY the new file and
//  the updater reviews ONLY the new summaries. No 1-hour wait: the FilesSource test seams
//  (`testZeroHoldBack` / `testIgnoreDateAdded`) disable the freshness hold-back.
//
//    SENTIENT_SELFTEST=e2e SENTIENT_VAULT_ROOT=/tmp/scratch-vault
//
//  Spends: ~4 on-device inferences (seconds each) + 2 codex medium calls (~30s each).
//  REQUIRES the vault-root override (protects the real vault) and refuses to run if the
//  mirror is enabled without SENTIENT_MIRROR_BASE (the push would clobber the real mirror).
//

#if DEBUG
import Foundation
import SwiftData

enum SelfTestE2E {

    static func run(emit: (String) -> Void) async {
        let env = ProcessInfo.processInfo.environment

        // Gates: model on disk, codex working, scratch vault root, mirror safety.
        guard let modelPath = ModelLocator.resolve() else {
            emit("SKIP — on-device model not found (set SENTIENT_MODEL_PATH)"); return
        }
        let codex = await CodexCLI.shared.validate()
        guard case .available = codex else { emit("SKIP — Codex unavailable: \(codex)"); return }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sentient OS -- The Vault").path
        guard let scratch = env["SENTIENT_VAULT_ROOT"], !scratch.isEmpty, scratch != home else {
            emit("SET SENTIENT_VAULT_ROOT to a scratch dir (NOT the real vault) and re-run."); return
        }
        if await MirrorClient.shared.isEnabled && env["SENTIENT_MIRROR_BASE"] == nil {
            emit("ABORT — mirror enabled without SENTIENT_MIRROR_BASE; the push step would "
                 + "replace your real hosted mirror. Disable the mirror or set the override."); return
        }

        FilesSource.testIgnoreDateAdded = true
        FilesSource.testZeroHoldBack = true
        defer { FilesSource.testIgnoreDateAdded = false; FilesSource.testZeroHoldBack = false }

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            emit("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }

        let fm = FileManager.default

        // Fixture source folder — content concrete enough that triage keeps it.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentient-e2e-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func drop(_ name: String, _ body: String, mtimeAgo: TimeInterval) {
            let p = folder.appendingPathComponent(name)
            try? body.write(to: p, atomically: true, encoding: .utf8)
            let then = Date().addingTimeInterval(-mtimeAgo)
            try? fm.setAttributes([.creationDate: then, .modificationDate: then], ofItemAtPath: p.path)
        }
        drop("Lisbon Trip Plan.md",
             "Booked flights to Lisbon July 18–25. Staying in Alfama. Shortlist: Memmo Alfama vs "
             + "Santiago de Alfama. Need to reserve Sintra day-trip tickets before July 1.",
             mtimeAgo: 7_200)
        drop("Espresso Setup.md",
             "Ordered the Gaggia Classic Pro. Dial-in plan: 18g in, 36g out, 25–30s. Grinder is the "
             + "DF64. First service: replace the steam wand with the IMS tip.",
             mtimeAgo: 5_400)
        drop("Marathon Training.md",
             "Registered for the CIM marathon on December 6. 16-week block starts August 17: 4 runs "
             + "a week, long run Sundays, goal 3:25.",
             mtimeAgo: 3_600)

        // Fixture vault (the updater's target — we don't spend a high-effort initial gen here).
        let vault = URL(fileURLWithPath: scratch, isDirectory: true)
        try? fm.removeItem(at: vault)
        try? fm.createDirectory(at: vault.appendingPathComponent("Life"), withIntermediateDirectories: true)
        try? "# README\nFixture human: an SF engineer who travels, lifts, and tinkers.\n## Map\n- Life/\n"
            .write(to: vault.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? "---\ntitle: Hobbies\n---\n# Hobbies\nThe user enjoys coffee and running.\n"
            .write(to: vault.appendingPathComponent("Life/Hobbies.md"), atomically: true, encoding: .utf8)

        // Real store (in-memory), real engine, real pipeline.
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Summary.self, SourceCursor.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch { emit("ModelContainer FAILED: \(error)"); return }
        let store = Store(modelContainer: container)
        let source = FilesSource(root: folder, label: "Fixture", cursorKey: "file:e2e")
        let engine = Engine(modelPath: modelPath, maxNumTokens: 4096)
        do { try await engine.load() } catch { emit("engine load FAILED: \(error)"); return }
        defer { Task { await engine.unload() } }
        let pipeline = Pipeline(engine: engine, store: store)

        // ── Round 1: initial analysis + first fold ───────────────────────────────
        emit("ROUND 1 — analyzing 3 fixture files on-device…")
        let p1: PipelineProgress
        do { p1 = try await pipeline.run(source: source, currentDate: Date()) }
        catch { emit("pipeline FAILED: \(error)"); return }
        let survivors1 = await store.unsyncedSummaries().count
        check("analyzed all 3 files", p1.done == 3, "done \(p1.done)")
        check("at least 1 survivor (triage kept real content)", survivors1 >= 1,
              "survivors \(survivors1) · junk \(p1.junk)")

        emit("ROUND 1 — running DaysEndJob (real codex call)…")
        let s1 = await DaysEndJob.shared.run(store: store)
        emit("status: \(s1)")
        check("round-1 status is a Done", s1.hasPrefix("Done"), s1)
        check("round-1 reviewed the survivors", s1.contains("reviewed \(survivors1)"), s1)
        check("round-1 stamped exactly the queue", await store.unsyncedSummaries().isEmpty)

        // ── Round 2: ONE new file → pointer picks up only it → second fold ──────
        drop("Dentist Appointment.md",
             "Dentist cleaning booked for June 24 at 2:30 PM with Dr. Yu at SF Dental on Mission. "
             + "Bring the new insurance card.",
             mtimeAgo: 1_800)
        emit("\nROUND 2 — one NEW file added; re-analyzing…")
        let p2: PipelineProgress
        do { p2 = try await pipeline.run(source: source, currentDate: Date()) }
        catch { emit("pipeline FAILED: \(error)"); return }
        let survivors2 = await store.unsyncedSummaries().count
        check("pointer picked up ONLY the new file", p2.done == 1, "done \(p2.done)")

        let s2 = await DaysEndJob.shared.run(store: store)
        emit("status: \(s2)")
        if survivors2 >= 1 {
            check("round-2 reviewed only the new summaries", s2.contains("reviewed \(survivors2)"), s2)
            check("round-2 stamped them", await store.unsyncedSummaries().isEmpty)
        } else {
            check("round-2 no-op (triage junked the new file)", s2.contains("nothing new to fold"), s2)
        }

        // ── Round 3: nothing changed → full no-op ────────────────────────────────
        let p3 = (try? await pipeline.run(source: source, currentDate: Date()))
        let s3 = await DaysEndJob.shared.run(store: store)
        check("round-3 analysis is a no-op", (p3?.done ?? -1) == 0, "done \(p3?.done ?? -1)")
        check("round-3 update is a no-op", s3.contains("nothing new to fold"), s3)

        emit("\nvault skeleton after:\n\(VaultUpdater.skeleton(of: vault))")
        emit("\n# \(fail == 0 ? "✅ ALL PASS" : "❌ FAILURES") — \(pass) passed · \(fail) failed")
    }
}
#endif
