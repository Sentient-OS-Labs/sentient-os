//
//  SelfTest_Incremental.swift — pointer-architecture proof (Kill the Ledger, June 11 +
//  newest-first backfill, June 12)
//  Sentient OS macOS
//
//  Deterministic, no model. Dispatched from SelfTest.runIfRequested():
//    SENTIENT_SELFTEST=incremental
//  Drives the REAL FilesSource + Store (in-memory container) through the pointer lifecycle:
//    1. the first run is a BACKFILL: everything consumes NEWEST-first, then the cursor
//       collapses to a plain pointer
//    2. immediate re-run is a complete no-op (nothing past the pointer)
//    3. a new file → only the new file processes (ascending incremental)
//    4. an edited file → re-processes as a NEW summary version with a " — Edit" title
//    5. a junk verdict advances the pointer while persisting NOTHING (zero trace)
//    6. markCorpusSynced stamps the queue; new versions re-enter it
//    7. an INTERRUPTED backfill resumes: mid-flight cursor is a BackfillCursor, files arriving
//       mid-backfill process BEFORE the dig resumes, the dig descends, the budget's last item
//       collapses the cursor
//    8. a backfill whose below-lo items vanish completes via the scan's completion report
//
//  Uses the mtime-only/zero-hold-back test seams (fixtures can't backdate dateAdded).
//

#if DEBUG
import Foundation
import SwiftData

enum SelfTestIncremental {

    static func run(emit: (String) -> Void) async {
        FilesSource.testIgnoreDateAdded = true
        defer { FilesSource.testIgnoreDateAdded = false }

        let fm = FileManager.default
        var base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentient-incremental-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        // The enumerator yields canonical /private/var/… paths while NSTemporaryDirectory()
        // hands out the /var/… symlink form — canonicalize so the pointer-suffix checks match.
        if let canon = try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            base = URL(fileURLWithPath: canon, isDirectory: true)
        }
        defer { try? fm.removeItem(at: base) }

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            emit("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func touch(_ dir: URL, _ name: String, mtimeAgo: TimeInterval) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = dir.appendingPathComponent(name).path
            if !fm.fileExists(atPath: p) { fm.createFile(atPath: p, contents: Data("x".utf8)) }
            let then = Date().addingTimeInterval(-mtimeAgo)
            try? fm.setAttributes([.creationDate: then, .modificationDate: then], ofItemAtPath: p)
        }

        let container: ModelContainer
        do {
            container = try ModelContainer(for: Summary.self, SourceCursor.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch { emit("ModelContainer FAILED: \(error)"); return }
        let store = Store(modelContainer: container)

        /// One simulated pipeline pass: scan past the pointers, apply completions (as the real
        /// Pipeline does), "judge" up to `limit` candidates with the given verdict, record
        /// (summary + pointer advance — the real Store path). Returns names in processing order.
        func runPass(_ source: FilesSource, verdict: Verdict = .survivor, limit: Int? = nil) async -> [String] {
            let scan = (try? source.scan(since: await store.cursors()))
                ?? ScanResult(candidates: [])
            for (key, value) in scan.completions {
                try? await store.advanceCursor(value, forKey: key)
            }
            var cands = scan.candidates
            if let limit, cands.count > limit { cands = Array(cands.prefix(limit)) }
            for c in cands {
                guard let artifact = try? source.load(c) else { continue }
                let draft = verdict == .survivor
                    ? SummaryDraft(text: "Synthetic summary of \(c.metadata["name"] ?? "?").",
                                   title: c.metadata["name"])
                    : nil
                try? await store.record(artifact: artifact, verdict: verdict, summary: draft)
            }
            return cands.map { $0.metadata["name"] ?? "?" }
        }

        // ── A. The straight-through lifecycle ───────────────────────────────────
        let rootA = base.appendingPathComponent("a")
        let sourceA = FilesSource(root: rootA, label: "Fixture", cursorKey: "file:fixture")

        // 1) Backfill: everything, NEWEST-first; a completed backfill collapses to a plain pointer.
        touch(rootA, "a.md", mtimeAgo: 7_200)
        touch(rootA, "b.md", mtimeAgo: 3_600)
        let first = await runPass(sourceA)
        check("backfill consumes everything newest-first", first == ["b.md", "a.md"], "\(first)")
        let cursorA = await store.cursor(forKey: "file:fixture") ?? ""
        check("completed backfill collapsed to a plain pointer",
              !cursorA.isEmpty && !cursorA.hasPrefix("{"), cursorA)
        check("plain pointer sits at the NEWEST item", cursorA.hasSuffix("|" + rootA.appendingPathComponent("b.md").path))

        // 2) Immediate re-run: complete no-op.
        let second = await runPass(sourceA)
        check("re-run is a no-op", second.isEmpty, "\(second)")

        // 3) New file: only the new file (ascending incremental).
        touch(rootA, "c.md", mtimeAgo: 1_800)
        let third = await runPass(sourceA)
        check("only the NEW file processes", third == ["c.md"], "\(third)")

        // 4) Edited file: re-processes as a new VERSION with the " — Edit" title suffix.
        touch(rootA, "a.md", mtimeAgo: 900)   // mtime moves past the pointer
        let fourth = await runPass(sourceA)
        check("only the EDITED file re-processes", fourth == ["a.md"], "\(fourth)")
        let all = await store.allSummaries()
        let aVersions = all.filter { $0.sourceID.hasSuffix("/a.md") }
        check("edit created a second version", aVersions.count == 2, "\(aVersions.count) versions")
        check("new version title carries ' — Edit'",
              aVersions.contains { $0.title?.hasSuffix(" — Edit") == true },
              "\(aVersions.compactMap(\.title))")

        // 5) The updater queue self-populates; a full generation stamps it; new rows re-enter.
        let queued = await store.unsyncedSummaries()
        check("unsynced queue holds every version", queued.count == 4, "\(queued.count)")
        await store.markCorpusSynced(await store.survivorSummaries())
        let drained = await store.unsyncedSummaries()
        check("corpus stamp drains the queue", drained.isEmpty, "\(drained.count) left")

        // 6) Junk advances the pointer and leaves ZERO trace.
        let before = await store.counts()
        touch(rootA, "d.md", mtimeAgo: 600)
        let fifth = await runPass(sourceA, verdict: .junk)
        check("junk item was scanned once", fifth == ["d.md"], "\(fifth)")
        let sixth = await runPass(sourceA)
        check("junk never re-scans (pointer passed it)", sixth.isEmpty, "\(sixth)")
        let after = await store.counts()
        check("junk persisted nothing", after.versions == before.versions,
              "versions \(before.versions) → \(after.versions)")

        // ── B. The interrupted backfill: resume digs down; mid-backfill arrivals go first ──
        let rootB = base.appendingPathComponent("b")
        let sourceB = FilesSource(root: rootB, label: "Fixture2", cursorKey: "file:fixture2")
        touch(rootB, "w.md", mtimeAgo: 8_000)
        touch(rootB, "x.md", mtimeAgo: 6_000)
        touch(rootB, "y.md", mtimeAgo: 4_000)
        touch(rootB, "z.md", mtimeAgo: 2_000)

        let b1 = await runPass(sourceB, limit: 2)   // "stopped midway"
        check("interrupted backfill consumed the newest first", b1 == ["z.md", "y.md"], "\(b1)")
        let midCursor = BackfillCursor.decode(await store.cursor(forKey: "file:fixture2"))
        check("mid-backfill cursor is a BackfillCursor", midCursor != nil)
        check("…with hi at the newest item and 2 budget left",
              midCursor?.remaining == 2
              && (midCursor?.hi.hasSuffix("|" + rootB.appendingPathComponent("z.md").path) ?? false),
              "remaining \(midCursor?.remaining ?? -1)")

        touch(rootB, "n.md", mtimeAgo: 1_000)       // arrives mid-backfill, newer than hi
        let b2 = await runPass(sourceB)
        check("resume: the NEW file first, then the dig descends",
              b2 == ["n.md", "x.md", "w.md"], "\(b2)")
        let doneCursor = await store.cursor(forKey: "file:fixture2") ?? ""
        check("spent budget collapsed the cursor to the swept-up hi",
              doneCursor.hasSuffix("|" + rootB.appendingPathComponent("n.md").path)
              && !doneCursor.hasPrefix("{"), doneCursor)
        let b3 = await runPass(sourceB)
        check("post-backfill re-run is a no-op", b3.isEmpty, "\(b3)")

        // ── C. A starved dig completes via the scan's completion report ─────────
        let rootC = base.appendingPathComponent("c")
        let sourceC = FilesSource(root: rootC, label: "Fixture3", cursorKey: "file:fixture3")
        touch(rootC, "t1.md", mtimeAgo: 6_000)
        touch(rootC, "t2.md", mtimeAgo: 4_000)
        touch(rootC, "t3.md", mtimeAgo: 2_000)
        let c1 = await runPass(sourceC, limit: 1)
        check("backfill interrupted after the newest item", c1 == ["t3.md"], "\(c1)")
        try? fm.removeItem(at: rootC.appendingPathComponent("t1.md"))
        try? fm.removeItem(at: rootC.appendingPathComponent("t2.md"))
        let c2 = await runPass(sourceC)
        let cCursor = await store.cursor(forKey: "file:fixture3") ?? ""
        check("emptied dig yields no candidates", c2.isEmpty, "\(c2)")
        check("…and the scan completion collapsed the cursor",
              cCursor.hasSuffix("|" + rootC.appendingPathComponent("t3.md").path)
              && !cCursor.hasPrefix("{"), cCursor)

        emit("\n# \(fail == 0 ? "✅ ALL PASS" : "❌ FAILURES") — \(pass) passed · \(fail) failed")
    }
}
#endif
