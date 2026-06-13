//
//  SelfTest_UpdaterE2E.swift — the comprehensive, content-verified iterative-updater proof
//  Sentient OS macOS
//
//    SENTIENT_SELFTEST=updater SENTIENT_VAULT_ROOT=/tmp/scratch-vault
//
//  The rigorous end-to-end test of the iterative updater (`VaultUpdater` + the `DaysEndJob`
//  entry point). It does NOT trust status strings — after every fold it READS the vault's
//  .md files and asserts the new facts actually landed and the old ones survived. Summaries
//  are seeded deterministically (real `Store.record` path, no on-device engine), so the
//  updater's correctness assertions are reliable rather than at the mercy of triage variance.
//  (The real-engine full-chain smoke test is a separate mode: `SENTIENT_SELFTEST=e2e`.)
//
//  Phases:
//    0. Empty queue        → no-op, no cloud call, vault untouched
//    1. No vault on disk   → throws .noVault (the guard the missing-vault bug tripped)
//    2. First fold         → 3 distinct facts land in the vault; existing notes preserved;
//                            exactly the 3 rows stamped
//    3. Incremental fold   → ONE new file; queue holds only it; fold reviews 1 (not 4);
//                            new fact lands; previously-folded facts still present
//    4. Idempotent no-op   → nothing unsynced → no cloud, vault byte-identical
//    5. Versioned edit     → re-summarize the same source (newer); " — Edit" title; the
//                            UPDATED fact (August) folds in as the current truth; the corpus
//                            (latest-per-source) stays 4, not 5
//    6. DaysEndJob wrapper → the actual button entry point: "Done —", "reviewed 1",
//                            "mirror: off", queue drained, no hang
//
//  Spends ~4 medium codex calls (~2–3 min). REQUIRES SENTIENT_VAULT_ROOT (protects the real
//  vault); refuses to run if the mirror is enabled without SENTIENT_MIRROR_BASE (the push
//  would clobber the real hosted mirror with this fixture).
//

#if DEBUG
import Foundation
import SwiftData

enum SelfTestUpdaterE2E {

    static func run(emit: (String) -> Void) async {
        let env = ProcessInfo.processInfo.environment

        // ── Gates ────────────────────────────────────────────────────────────────
        let codex = await CodexCLI.shared.validate()
        guard case .available = codex else { emit("SKIP — Codex unavailable: \(codex)"); return }
        let realVault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Sentient OS -- The Vault").path
        guard let scratch = env["SENTIENT_VAULT_ROOT"], !scratch.isEmpty, scratch != realVault else {
            emit("SET SENTIENT_VAULT_ROOT to a scratch dir (NOT the real vault) and re-run."); return
        }
        if await MirrorClient.shared.isEnabled && env["SENTIENT_MIRROR_BASE"] == nil {
            emit("ABORT — mirror enabled without SENTIENT_MIRROR_BASE; the push step would "
                 + "replace your real hosted mirror with this fixture. Disable the mirror first."); return
        }

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            emit("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }

        let fm = FileManager.default
        let vault = URL(fileURLWithPath: scratch, isDirectory: true)

        // ── Phase 0 — empty queue is a no-op (own store + own vault, NO cloud) ─────
        emit("── Phase 0 — empty queue → no-op")
        do {
            let empty = freshStore(emit: emit)
            let v0 = fm.temporaryDirectory.appendingPathComponent("updater-p0-\(UUID().uuidString)")
            buildFixtureVault(at: v0)
            // VaultUpdater always targets VaultGenerator.vaultRoot (= SENTIENT_VAULT_ROOT here),
            // so Phase 0/1 use that root too — build it, snapshot its bytes, assert no change.
            try? fm.removeItem(at: vault); buildFixtureVault(at: vault)
            let before = digest(of: vault)
            let n = try await VaultUpdater.shared.runDailyUpdate(store: empty!)
            check("empty queue returns 0", n == 0, "\(n)")
            check("vault untouched by a no-op", digest(of: vault) == before)
            try? fm.removeItem(at: v0)
        } catch { check("empty-queue phase did not throw", false, "\(error)") }

        // ── Phase 1 — no vault on disk → .noVault (the missing-vault guard) ────────
        emit("\n── Phase 1 — no vault on disk → .noVault guard")
        do {
            let s = freshStore(emit: emit)!
            await seed(s, id: "file:/fixture/guard.md", title: "Guard", text: "A real keeper fact.")
            try? fm.removeItem(at: vault)                       // no vault present
            _ = try await VaultUpdater.shared.runDailyUpdate(store: s)
            check("missing vault throws", false, "no error thrown")
        } catch let VaultUpdater.UpdaterError.noVault {
            check("missing vault throws .noVault", true)
        } catch { check("missing vault throws .noVault", false, "wrong error: \(error)") }

        // ── The incremental narrative: ONE shared store + ONE shared vault ─────────
        let store = freshStore(emit: emit)!
        try? fm.removeItem(at: vault); buildFixtureVault(at: vault)

        // ── Phase 2 — first fold: 3 distinct facts must actually land ──────────────
        emit("\n── Phase 2 — first fold (3 distinct facts; real codex call ~30s)")
        await seed(store, id: "file:/fixture/lisbon.md", title: "Lisbon Trip",
                   text: "The user booked flights to Lisbon for July 18–25, staying in the Alfama "
                       + "district, and wants to reserve a Sintra day-trip before July 1.")
        await seed(store, id: "file:/fixture/espresso.md", title: "Espresso Setup",
                   text: "The user bought a Gaggia Classic Pro espresso machine with a DF64 grinder "
                       + "and is dialing in an 18g-in / 36g-out recipe.")
        await seed(store, id: "file:/fixture/marathon.md", title: "Marathon Training",
                   text: "The user registered for the CIM marathon on December 6 and starts a "
                       + "16-week training block in late summer, targeting a 3:25 finish.")
        // (No fixture mentions "August" — so Phase 5's August check cleanly proves the Lisbon
        //  edit folded, not some other note's wording.)
        let q2 = await store.unsyncedSummaries().count
        check("queue holds the 3 seeded summaries", q2 == 3, "\(q2)")

        let notesBefore = noteCount(vault)
        let n2 = try? await VaultUpdater.shared.runDailyUpdate(store: store)
        check("fold reviewed all 3", n2 == 3, "\(n2 ?? -1)")
        check("queue fully drained (3 rows stamped)", await store.unsyncedSummaries().isEmpty)

        let text2 = vaultText(vault)
        check("Lisbon trip folded in",   containsAny(text2, ["lisbon", "alfama", "sintra"]), evidence(text2, "lisbon"))
        check("Espresso setup folded in", containsAny(text2, ["gaggia", "espresso", "df64"]), evidence(text2, "gaggia"))
        check("Marathon folded in",      containsAny(text2, ["marathon", "cim", "3:25"]), evidence(text2, "marathon"))
        check("README still present",    fm.fileExists(atPath: vault.appendingPathComponent("README.md").path))
        check("no notes deleted wholesale", noteCount(vault) >= notesBefore, "\(notesBefore) → \(noteCount(vault))")
        check("corpus is 3 distinct sources", await store.survivorSummaries().count == 3,
              "\(await store.survivorSummaries().count)")

        // ── Phase 3 — incremental: one NEW file, only it is pending ────────────────
        emit("\n── Phase 3 — incremental fold (one new file; real codex call)")
        await seed(store, id: "file:/fixture/dentist.md", title: "Dentist Appointment",
                   text: "The user has a dentist cleaning booked for June 24 at 2:30 PM with Dr. Yu.")
        let q3 = await store.unsyncedSummaries().count
        check("ONLY the new file is queued (not the 3 already folded)", q3 == 1, "\(q3)")

        let n3 = try? await VaultUpdater.shared.runDailyUpdate(store: store)
        check("incremental fold reviewed exactly 1", n3 == 1, "\(n3 ?? -1)")
        let text3 = vaultText(vault)
        check("new dentist fact folded in", containsAny(text3, ["dentist", "june 24", "dr. yu", "dr yu"]),
              evidence(text3, "dentist"))
        check("previously-folded facts NOT lost", containsAny(text3, ["lisbon", "alfama"])
              && containsAny(text3, ["gaggia", "espresso"]))
        check("queue drained after incremental fold", await store.unsyncedSummaries().isEmpty)

        // ── Phase 4 — idempotent no-op (nothing unsynced) ──────────────────────────
        emit("\n── Phase 4 — idempotent no-op")
        let beforeNoop = digest(of: vault)
        let n4 = try? await VaultUpdater.shared.runDailyUpdate(store: store)
        check("no-op returns 0", n4 == 0, "\(n4 ?? -1)")
        check("vault byte-identical after no-op", digest(of: vault) == beforeNoop)

        // ── Phase 5 — versioned edit folds the NEWEST truth ────────────────────────
        emit("\n── Phase 5 — versioned edit (trip moves July → August; real codex call)")
        await seed(store, id: "file:/fixture/lisbon.md", title: "Lisbon Trip",
                   text: "Update: the user MOVED the Lisbon trip to August 12–20 (still Alfama); "
                       + "the July dates are cancelled.")
        let edited = await store.unsyncedSummaries()
        check("only the edited version is queued", edited.count == 1, "\(edited.count)")
        check("edit got the ' — Edit' title suffix", edited.first?.title?.hasSuffix(" — Edit") == true,
              edited.first?.title ?? "nil")
        check("corpus still 4 sources (versions dedup)", await store.survivorSummaries().count == 4,
              "\(await store.survivorSummaries().count)")

        let n5 = try? await VaultUpdater.shared.runDailyUpdate(store: store)
        check("versioned fold reviewed 1", n5 == 1, "\(n5 ?? -1)")
        let text5 = vaultText(vault)
        check("the UPDATED fact (August) is now the vault's truth", containsAny(text5, ["august", "aug 12", "8/12"]),
              evidence(text5, "august"))
        check("the stale July dates were superseded", !text5.contains("july 18"),
              evidence(text5, "july 18"))

        // ── Phase 6 — the actual button entry point (DaysEndJob.run) ───────────────
        emit("\n── Phase 6 — DaysEndJob.run() (the button's real path)")
        await seed(store, id: "file:/fixture/passport.md", title: "Passport Renewal",
                   text: "The user's passport expires in October; they plan to renew it in July before Lisbon.")
        let status = await DaysEndJob.shared.run(store: store)
        emit("status: \(status)")
        check("status starts with 'Done —' (not a disguised failure)", status.hasPrefix("Done —"), status)
        check("status reports reviewed 1", status.contains("reviewed 1"), status)
        check("mirror correctly reported off", status.contains("mirror: off"), status)
        check("DaysEndJob drained the queue", await store.unsyncedSummaries().isEmpty)
        check("passport fact folded in", containsAny(vaultText(vault), ["passport", "renew"]),
              evidence(vaultText(vault), "passport"))

        emit("\nfinal vault skeleton:\n\(VaultUpdater.skeleton(of: vault))")
        emit("\n# \(fail == 0 ? "✅ ALL PASS" : "❌ \(fail) FAILED") — \(pass) passed · \(fail) failed")
    }

    // MARK: Fixtures & helpers

    private static func freshStore(emit: (String) -> Void) -> Store? {
        do {
            let c = try ModelContainer(for: Summary.self, SourceCursor.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            return Store(modelContainer: c)
        } catch { emit("ModelContainer FAILED: \(error)"); return nil }
    }

    /// Seed one survivor through the REAL `Store.record` path (synthetic candidate → artifact),
    /// so versioning / stamping / queueing behave exactly as in production.
    private static func seed(_ store: Store, id: String, title: String, text: String) async {
        let cand = Candidate(id: id, kind: .file, cursorKey: "file:fixture",
                             cursorValue: "\(Date().timeIntervalSince1970)|\(id)",
                             itemDate: Date(), metadata: ["folder": "Fixture", "name": title])
        try? await store.record(artifact: Artifact(candidate: cand, text: text),
                                verdict: .survivor, summary: SummaryDraft(text: text, title: title))
    }

    /// A miniature but realistic vault: a portrait README + two domain notes that partially
    /// cover the seeded topics (so the updater both edits existing notes and creates new ones).
    private static func buildFixtureVault(at vault: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: vault.appendingPathComponent("Life"), withIntermediateDirectories: true)
        try? """
        # README
        A software engineer in San Francisco who travels, drinks good coffee, and runs.
        ## Map
        - Life/ — hobbies and routines
        """.write(to: vault.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? """
        ---
        title: Hobbies
        tags: [coffee, running]
        ---
        # Hobbies
        The user enjoys pour-over coffee and recreational running.
        """.write(to: vault.appendingPathComponent("Life/Hobbies.md"), atomically: true, encoding: .utf8)
    }

    /// Concatenated, lowercased text of every .md in the vault — the content oracle.
    private static func vaultText(_ vault: URL) -> String {
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: vault.path)) ?? []
        return paths.filter { $0.hasSuffix(".md") }
            .compactMap { try? String(contentsOf: vault.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n").lowercased()
    }

    private static func noteCount(_ vault: URL) -> Int {
        ((try? FileManager.default.subpathsOfDirectory(atPath: vault.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.count
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0.lowercased()) }
    }

    /// On a content miss, show the line that should have matched (or a note that nothing did) —
    /// "don't assume; show the evidence."
    private static func evidence(_ text: String, _ near: String) -> String {
        if let line = text.split(separator: "\n").first(where: { $0.contains(near) }) {
            return "found: …\(line.prefix(80))…"
        }
        return "no line mentions '\(near)' — vault has \(text.count) chars"
    }

    /// A cheap content fingerprint (path + size + mtime of every .md) — detects ANY change for
    /// the no-op assertions without hashing file bodies.
    private static func digest(of vault: URL) -> String {
        let fm = FileManager.default
        let paths = ((try? fm.subpathsOfDirectory(atPath: vault.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.sorted()
        return paths.map { p -> String in
            let attrs = (try? fm.attributesOfItem(atPath: vault.appendingPathComponent(p).path)) ?? [:]
            let size = (attrs[.size] as? Int) ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(p):\(size):\(mtime)"
        }.joined(separator: "|")
    }
}
#endif
