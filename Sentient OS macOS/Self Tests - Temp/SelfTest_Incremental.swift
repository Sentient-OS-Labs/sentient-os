//
//  SelfTest_Incremental.swift — pointer-architecture proof (Kill the Ledger, June 11)
//  Sentient OS macOS
//
//  Deterministic, no model. Dispatched from SelfTest.runIfRequested():
//    SENTIENT_SELFTEST=incremental
//  Drives the REAL FilesSource + Store (in-memory container) through the pointer lifecycle:
//    1. full pass consumes everything, oldest-first
//    2. immediate re-run is a complete no-op (nothing past the pointer)
//    3. a new file → only the new file processes
//    4. an edited file → re-processes as a NEW summary version with a " — Edit" title
//    5. a junk verdict advances the pointer while persisting NOTHING (zero trace)
//    6. markCorpusSynced stamps the queue; new versions re-enter it
//
//  Uses the mtime-only/zero-hold-back test seams (fixtures can't backdate dateAdded).
//

#if DEBUG
import Foundation
import SwiftData

enum SelfTestIncremental {

    static func run(emit: (String) -> Void) async {
        FilesSource.testIgnoreDateAdded = true
        FilesSource.testZeroHoldBack = true
        defer { FilesSource.testIgnoreDateAdded = false; FilesSource.testZeroHoldBack = false }

        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentient-incremental-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { pass += 1 } else { fail += 1 }
            emit("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        }
        func touch(_ name: String, mtimeAgo: TimeInterval) {
            let p = base.appendingPathComponent(name).path
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
        let source = FilesSource(root: base, label: "Fixture", cursorKey: "file:fixture")

        /// One simulated pipeline pass: scan past the pointers, "judge" each candidate with the
        /// given verdict, record (summary + pointer advance — the real Store path). Returns the
        /// processed file names in processing order.
        func runPass(verdict: Verdict = .survivor) async -> [String] {
            let cands = (try? source.scan(since: await store.cursors())) ?? []
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

        // 1) Initial pass: everything, oldest-first.
        touch("a.md", mtimeAgo: 7_200)
        touch("b.md", mtimeAgo: 3_600)
        let first = await runPass()
        check("initial pass consumes everything oldest-first", first == ["a.md", "b.md"], "\(first)")

        // 2) Immediate re-run: complete no-op.
        let second = await runPass()
        check("re-run is a no-op", second.isEmpty, "\(second)")

        // 3) New file: only the new file.
        touch("c.md", mtimeAgo: 1_800)
        let third = await runPass()
        check("only the NEW file processes", third == ["c.md"], "\(third)")

        // 4) Edited file: re-processes as a new VERSION with the " — Edit" title suffix.
        touch("a.md", mtimeAgo: 900)   // mtime moves past the pointer
        let fourth = await runPass()
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
        touch("d.md", mtimeAgo: 600)
        let fifth = await runPass(verdict: .junk)
        check("junk item was scanned once", fifth == ["d.md"], "\(fifth)")
        let sixth = await runPass()
        check("junk never re-scans (pointer passed it)", sixth.isEmpty, "\(sixth)")
        let after = await store.counts()
        check("junk persisted nothing", after.versions == before.versions,
              "versions \(before.versions) → \(after.versions)")

        emit("\n# \(fail == 0 ? "✅ ALL PASS" : "❌ FAILURES") — \(pass) passed · \(fail) failed")
    }
}
#endif
