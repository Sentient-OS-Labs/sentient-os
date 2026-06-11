//
//  SelfTest_FileSkipping.swift — deterministic harness for FilesSource skipping & caps
//  Sentient OS macOS
//
//  Two no-model modes, dispatched from SelfTest.runIfRequested():
//    SENTIENT_SELFTEST=skipping    builds a synthetic fixture tree in /tmp (code repos, datasets,
//                                  screenshot dumps, an Obsidian vault…) and asserts EXACTLY what
//                                  survives scan() — pruning rules, per-dir/per-root caps, age cutoff.
//    SENTIENT_SELFTEST=skipcensus  read-only walk of the REAL standard folders: every pruned
//                                  subtree with its reason + the top contributing directories.
//                                  This is the tuning tool — run it on all three Macs and eyeball.
//

#if DEBUG
import Foundation

enum SelfTestFileSkipping {

    // MARK: - Synthetic fixture assertions

    static func synthetic(emit: (String) -> Void) {
        let fm = FileManager.default
        var base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sentient-skiptest-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        // The enumerator yields canonical /private/var/… paths while NSTemporaryDirectory() hands
        // out the /var/… symlink form — canonicalize so the prefix grouping below matches.
        if let canon = try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            base = URL(fileURLWithPath: canon, isDirectory: true)
        }
        defer { try? fm.removeItem(at: base) }

        var pass = 0, fail = 0
        func check(_ name: String, expected: Int, actual: Int) {
            let ok = expected == actual
            if ok { pass += 1 } else { fail += 1 }
            emit("\(ok ? "✅" : "❌") \(name): expected \(expected), got \(actual)")
        }
        func dir(_ path: String) -> URL {
            let u = base.appendingPathComponent(path)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        func touch(_ folder: URL, _ name: String, age: TimeInterval = 0) {
            let p = folder.appendingPathComponent(name).path
            fm.createFile(atPath: p, contents: Data("x".utf8))
            if age > 0 {
                let then = Date().addingTimeInterval(-age)
                try? fm.setAttributes([.creationDate: then, .modificationDate: then], ofItemAtPath: p)
            }
        }
        /// Survivor count per top-level fixture dir for one scan.
        func counts(_ source: FilesSource) -> [String: Int] {
            let rootPath = source.root.path + "/"
            var by: [String: Int] = [:]
            for c in (try? source.scan(since: nil)) ?? [] {
                guard let p = c.metadata["path"], p.hasPrefix(rootPath) else { continue }
                by[String(p.dropFirst(rootPath.count).split(separator: "/").first ?? "?"), default: 0] += 1
            }
            return by
        }

        // ── Root 1: pruning rules ────────────────────────────────────────────────
        let docs = dir("prune/docs")
        touch(docs, "resume.pdf"); touch(docs, "notes.md"); touch(docs, "photo.jpg")
        let npm = dir("prune/npm-app");   touch(npm, "package.json"); touch(npm, "README.md")
        let mk  = dir("prune/make-tool"); touch(mk, "Makefile");      touch(mk, "README.md")
        let gc  = dir("prune/git-code");  touch(dir("prune/git-code/.git"), "HEAD")
        touch(gc, "main.py"); touch(gc, "README.md")
        let gn  = dir("prune/git-notes"); touch(dir("prune/git-notes/.git"), "HEAD")
        for i in 1...6 { touch(gn, "idea \(i).md") }
        let ob  = dir("prune/obsidian");  touch(dir("prune/obsidian/.obsidian"), "app.json")
        touch(ob, "package.json")   // stray manifest — the .obsidian exemption must win
        for i in 1...5 { touch(ob, "journal \(i).md") }
        let lg  = dir("prune/logseq-graph"); _ = dir("prune/logseq-graph/logseq")
        touch(dir("prune/logseq-graph/.git"), "HEAD")   // git-synced Logseq graph — exemption must win
        for i in 1...4 { touch(lg, "page \(i).md") }
        let xc  = dir("prune/xcode");     _ = dir("prune/xcode/Foo.xcodeproj"); touch(xc, "README.md")
        let den = dir("prune/density")
        for i in 1...12 { touch(den, "module\(i).py") }
        touch(den, "README.md"); touch(den, "guide.md")
        let ds  = dir("prune/dataset-txt")
        for i in 1...120 { touch(ds, String(format: "chunk_%04d.txt", i)) }
        let sc  = dir("prune/screenshots")
        for i in 1...120 { touch(sc, "Screenshot 2026-06-09 at 9.41.\(i) AM.png") }
        touch(dir("prune/node_modules"), "README.md")

        let pruneRoot = FilesSource(root: base.appendingPathComponent("prune"), label: "Prune")
        let p = counts(pruneRoot)
        check("docs survive untouched",            expected: 3,   actual: p["docs"] ?? 0)
        check("package.json repo pruned",          expected: 0,   actual: p["npm-app"] ?? 0)
        check("Makefile repo pruned (new manifest)", expected: 0, actual: p["make-tool"] ?? 0)
        check(".git + code pruned",                expected: 0,   actual: p["git-code"] ?? 0)
        check(".git markdown-only repo pruned too (June 11)", expected: 0, actual: p["git-notes"] ?? 0)
        check(".obsidian beats stray manifest",    expected: 5,   actual: p["obsidian"] ?? 0)
        check("logseq marker beats .git",          expected: 4,   actual: p["logseq-graph"] ?? 0)
        check(".xcodeproj sibling pruned",         expected: 0,   actual: p["xcode"] ?? 0)
        check("code-density (no manifest) pruned", expected: 0,   actual: p["density"] ?? 0)
        check("120× chunk_NNNN.txt dataset pruned", expected: 0,  actual: p["dataset-txt"] ?? 0)
        check("120 screenshots exempt from dataset rule", expected: 120, actual: p["screenshots"] ?? 0)
        check("node_modules pruned by name",       expected: 0,   actual: p["node_modules"] ?? 0)

        // ── Root 2: per-root cap (4 dirs × 280 → 1,120 files → newest 1,000) ────
        for d in 1...4 {
            let bulk = dir("caps/bulk\(d)")
            for i in 1...280 { touch(bulk, "meeting notes \(i).md") }
        }
        let capsTotal = counts(FilesSource(root: base.appendingPathComponent("caps"), label: "Caps"))
            .values.reduce(0, +)
        check("per-root cap (1,120 files → 1,000)", expected: FilesSource.perRootCap, actual: capsTotal)

        // ── Root 3: per-directory cap on a screenshot dump (350 files) ──────────
        let shots = dir("screens/shots")
        for i in 1...350 { touch(shots, "Screenshot 2026-06-09 at 10.\(i) AM.png") }
        let screensRoot = base.appendingPathComponent("screens")
        check("per-dir cap 300 (350 screenshots → 300)", expected: 300,
              actual: counts(FilesSource(root: screensRoot, label: "S", perDirectoryCap: 300))["shots"] ?? 0)
        check("per-dir cap 100 — the Downloads number", expected: 100,
              actual: counts(FilesSource(root: screensRoot, label: "S", perDirectoryCap: 100))["shots"] ?? 0)

        // ── Root 4: age cutoff (2 fresh + 3 two-year-old files) ─────────────────
        let aged = dir("age/stuff")
        touch(aged, "new one.md"); touch(aged, "new two.md")
        for i in 1...3 { touch(aged, "ancient \(i).md", age: 2 * 365 * 24 * 3_600) }
        let ageRoot = base.appendingPathComponent("age")
        check("no age cutoff → all 5", expected: 5,
              actual: counts(FilesSource(root: ageRoot, label: "A"))["stuff"] ?? 0)
        check("1-year cutoff → only the 2 fresh", expected: 2,
              actual: counts(FilesSource(root: ageRoot, label: "A", maxAge: 365 * 24 * 3_600))["stuff"] ?? 0)

        emit("\n# \(fail == 0 ? "✅ ALL PASS" : "❌ FAILURES") — \(pass) passed · \(fail) failed")
    }

    // MARK: - Real-Mac census (read-only; the threshold-tuning tool)

    static func census(emit: (String) -> Void) {
        let home = NSHomeDirectory()
        func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

        for root in FileRoot.standard {
            guard let source = root.source else { continue }
            emit("\n══════════ \(root.label) ══════════")

            // Every pruned subtree + why (same walk options as scan()).
            if let en = FileManager.default.enumerator(
                at: source.root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                var pruned = 0
                for case let url as URL in en {
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                    if let reason = FilesSource.pruneReason(url) {
                        en.skipDescendants(); pruned += 1
                        emit("  ⛔ \(tilde(url.path))  [\(reason)]")
                    }
                }
                emit("  (\(pruned) subtrees pruned)")
            }

            // What survives, and which directories contribute the most.
            let candidates = (try? source.scan(since: nil)) ?? []
            var byDir: [String: Int] = [:]
            for c in candidates {
                byDir[((c.metadata["path"] ?? "?") as NSString).deletingLastPathComponent, default: 0] += 1
            }
            let age = source.maxAge.map { "\(Int($0 / 86_400))d" } ?? "∞"
            emit("  → \(candidates.count) candidates from \(byDir.count) dirs "
                 + "(caps: \(source.perDirectoryCap)/dir · \(FilesSource.perRootCap)/root · age \(age))")
            for (d, n) in byDir.sorted(by: { $0.value > $1.value }).prefix(15) {
                emit("    \(String(format: "%4d", n))  \(tilde(d))")
            }
        }
    }
}
#endif
