//
//  SiYuanSource.swift
//  Sentient OS macOS
//
//  SiYuan reader: finds the user's SiYuan workspaces, walks every open notebook, and lists each
//  note (rendered by SiYuanNote) under a "SiYuan · Notebook › Parent › Title" path.
//
//  Workspaces come from SiYuan's own registry, `~/.config/siyuan/workspace.json` (a JSON array of
//  workspace paths). Layout inside one: `data/<notebook-id>/<doc-id>.sy`, and a sub-document lives
//  in a folder named after its parent: `<notebook-id>/<parent-id>/<child-id>.sy`. Only `data/` is
//  read, so SiYuan's internals (`history/` snapshots, the sync `repo/`, `temp/`) never are.
//
//  Keyed on each note's own "updated" stamp, NOT its creation date (unlike Apple Notes): notes in
//  SiYuan are living documents (a setup page rewritten when the setup changes), so an edited note
//  sorts past the high-water mark and is summarized again. Skipped: SiYuan's bundled User Guide
//  notebooks, closed notebooks, and title-only notes (folders for sub-documents, empty dailies).
//

import Foundation

struct SiYuanSource: Sendable {
    let kind: SourceKind = .siyuan

    static let maxNotes = 1_000          // newest-updated first, same cap as Apple Notes
    static let maxDepth = 8              // sub-document nesting below a notebook
    private static let maxContentChars = 8_000

    /// SiYuan's bundled User Guide notebooks (one per language). Read from the installed app when
    /// present; these are the IDs it ships today, kept as a fallback for a moved or deleted app.
    private static let bundledGuideIDs: Set<String> = [
        "20210808180117-6v0mkxr", "20210808180117-czj9bvb", "20211226090932-5lcq56f", "20240530133126-axarxgx",
    ]

    // MARK: Selection

    /// The Knowledge Sources pill's switch (no per-notebook picker: every open notebook is read).
    static let enabledKey = "siyuan.enabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) && isInstalled }

    // MARK: Discovery

    /// Every SiYuan workspace on this Mac that still exists on disk.
    static var workspaces: [URL] {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/siyuan/workspace.json")
        guard let data = try? Data(contentsOf: registry),
              let paths = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }.filter { isWorkspace($0) }
    }

    /// Whether the SiYuan pill should be offered at all.
    static var isInstalled: Bool { !workspaces.isEmpty }

    private static func isWorkspace(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("conf/conf.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("data").path)
    }

    private static var guideIDs: Set<String> {
        let shipped = (try? FileManager.default.contentsOfDirectory(
            atPath: "/Applications/SiYuan.app/Contents/Resources/guide")) ?? []
        return bundledGuideIDs.union(shipped)
    }

    // MARK: Listing

    /// The current eligible notes for the iterative system (SiYuanConnector), newest-updated first.
    /// The body is rendered at list time (like Apple Notes), so `load` just wraps it.
    func eligibleNotes() -> [Candidate] {
        let guides = Self.guideIDs
        var out: [Candidate] = []
        for workspace in Self.workspaces {
            let dataDir = workspace.appendingPathComponent("data")
            let databases = dataDir.appendingPathComponent("storage/av")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []
            for id in entries where !guides.contains(id) {
                let notebookDir = dataDir.appendingPathComponent(id)
                guard let conf = Self.notebookConf(notebookDir), conf["closed"] as? Bool != true else { continue }
                let name = conf["name"] as? String ?? "SiYuan"
                walk(notebookDir, trail: [name], depth: 0, databases: databases, into: &out)
            }
        }
        let kept = out.sorted { $0.itemDate > $1.itemDate }.prefix(Self.maxNotes)
        SourceHealth.checkListingCollapse(source: "siyuan", bucketKey: "siyuan", count: kept.count)
        return Array(kept)
    }

    private static func notebookConf(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(".siyuan/conf.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One folder of documents. `trail` is the notebook name plus the titles of the documents above.
    private func walk(_ dir: URL, trail: [String], depth: Int, databases: URL, into out: inout [Candidate]) {
        guard depth <= Self.maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in entries where file.hasSuffix(".sy") {
            let url = dir.appendingPathComponent(file)
            guard let note = SiYuanNote(contentsOf: url, databases: databases) else { continue }
            let docID = String(file.dropLast(3))
            let path = trail + [note.title]
            if !note.body.isEmpty, let candidate = Self.candidate(docID, note: note, path: path, file: url) {
                out.append(candidate)
            }
            // Sub-documents live in a sibling folder named after this document.
            walk(dir.appendingPathComponent(docID), trail: path, depth: depth + 1, databases: databases, into: &out)
        }
    }

    private static func candidate(_ docID: String, note: SiYuanNote, path: [String], file: URL) -> Candidate? {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let updated = note.updated ?? modified else { return nil }
        let created = SiYuanNote.parseStamp(docID)
        let location = path.joined(separator: " › ")
        let text = "# \(note.title)\nSiYuan: \(location)\n\n\(note.body)"
        var metadata = [
            "folder": path.first ?? "SiYuan",
            "name": note.title,
            "displayPath": "SiYuan · \(location)",
            "noteText": String(text.prefix(maxContentChars)),
        ]
        if let created { metadata["created"] = dateFormatter.string(from: created) }
        return Candidate(id: "siyuan:\(docID)", kind: .siyuan,
                         cursorKey: "siyuan", cursorValue: "",   // vestigial — the iterative core keys on ItemKey
                         itemDate: min(updated, Date()), metadata: metadata)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
