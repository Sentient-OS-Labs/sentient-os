//
//  SiYuanNote.swift
//  Sentient OS macOS
//
//  SiYuan (b3log.org/siyuan) notebook support for the Files source. SiYuan keeps each note as a
//  `.sy` file: a JSON block tree whose filename is a block ID, never a title, so a plain-text read
//  hands the model a wall of IDs and node types. This file:
//   • recognises a SiYuan WORKSPACE (`conf/conf.json` + `data/`) and NOTEBOOK (`.siyuan/conf.json`)
//     so FilesSource can walk the notes and skip SiYuan's internals (history snapshots, sync repo,
//     plugins…) — `history/` alone holds a second copy of recently edited notes;
//   • flattens a note to Markdown with a readable "Notebook › Parent › Title" header (the on-disk
//     path is all IDs, so this header is the only folder-structure signal the model gets).
//
//  Layout: <workspace>/data/<notebook-id>/<doc-id>.sy; a sub-document lives in a folder named after
//  its parent's ID: <notebook-id>/<parent-id>/<child-id>.sy.
//
//  Scope rule (see FilesSource.pruneReason): a workspace found INSIDE a walked folder is pruned, so
//  notes are only read when the user adds the workspace (or its data/ or a notebook) as its own
//  folder. A fresh folder gets its own pointer and a full first-run backfill; switching `.sy` on
//  inside an existing Documents bucket would silently skip every note older than its high-water mark.
//

import Foundation

enum SiYuanNote {
    /// Sub-document folders nest one level per parent document, so notebooks run deeper than the
    /// generic 3-level walk. Bounded relative to the notebook folder.
    static let maxNotebookDepth = 8

    /// Folders under `data/` that hold SiYuan's own state, not notes. (`assets/` is kept: those are
    /// the user's attachments — PDFs, images — and go through the normal extractors.)
    private static let internalDataDirs: Set<String> = [
        "storage", "plugins", "templates", "widgets", "emojis", "snippets", "public", "themes",
    ]

    // MARK: Layout

    static func isWorkspace(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: dir.appendingPathComponent("conf/conf.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("data").path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isNotebook(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".siyuan/conf.json").path)
    }

    /// Why a directory in or around a SiYuan workspace is skipped — nil means "not SiYuan's call".
    /// `names` is the directory's listing (already read by FilesSource.pruneReason).
    static func pruneReason(_ dir: URL, names: Set<String>) -> String? {
        if names.contains("conf"), names.contains("data"), isWorkspace(dir) {
            return "siyuan workspace (add it as its own folder)"
        }
        let name = dir.lastPathComponent
        let parent = dir.deletingLastPathComponent()
        // Workspace top level: only data/ holds notes (history/, repo/, temp/, conf/ are internals).
        if name != "data", isWorkspace(parent) { return "siyuan internal" }
        if internalDataDirs.contains(name), parent.lastPathComponent == "data",
           isWorkspace(parent.deletingLastPathComponent()) {
            return "siyuan internal"
        }
        return nil
    }

    // MARK: Text

    /// The note as Markdown under a "Notebook › Parent › Title" header. Empty string if unreadable.
    static func text(url: URL) -> String {
        guard let doc = document(url) else { return "" }
        let title = (doc["Properties"] as? [String: Any])?["title"] as? String ?? ""
        let trail = (breadcrumb(url) + [title]).filter { !$0.isEmpty }
        var out = "# \(title)\n"
        if trail.count > 1 { out += "SiYuan notebook: \(trail.joined(separator: " › "))\n" }
        let avDir = workspaceData(of: url)?.appendingPathComponent("storage/av")
        out += "\n" + blocks(children(doc), indent: "", avDir: avDir)
        return out
    }

    /// The note's title alone (cheap enough for a breadcrumb: one small JSON parse).
    static func title(_ url: URL) -> String? {
        (document(url)?["Properties"] as? [String: Any])?["title"] as? String
    }

    private static func document(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The workspace's `data/` folder (the notebook's parent), where `storage/av` keeps databases.
    private static func workspaceData(of url: URL) -> URL? {
        var dir = url.deletingLastPathComponent()
        for _ in 0...maxNotebookDepth {
            if isNotebook(dir) { return dir.deletingLastPathComponent() }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Notebook name + ancestor document titles, walking up the ID-named folders to the notebook.
    private static func breadcrumb(_ url: URL) -> [String] {
        var titles: [String] = []
        var dir = url.deletingLastPathComponent()
        for _ in 0..<maxNotebookDepth {
            if isNotebook(dir) {
                let conf = document(dir.appendingPathComponent(".siyuan/conf.json"))
                if let name = conf?["name"] as? String { titles.insert(name, at: 0) }
                return titles
            }
            // The parent document is the sibling `.sy` named after this folder.
            let parentDoc = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".sy")
            if let t = title(parentDoc) { titles.insert(t, at: 0) }
            dir = dir.deletingLastPathComponent()
        }
        return titles
    }

    // MARK: Block tree → Markdown

    private typealias Node = [String: Any]

    private static func children(_ n: Node) -> [Node] { n["Children"] as? [Node] ?? [] }
    private static func type(_ n: Node) -> String { n["Type"] as? String ?? "" }
    private static func data(_ n: Node) -> String { n["Data"] as? String ?? "" }

    private static func blocks(_ nodes: [Node], indent: String, avDir: URL?) -> String {
        nodes.map { block($0, indent: indent, avDir: avDir) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One block, its lines prefixed with `indent`. Unknown container blocks fall through to their
    /// children, so a new SiYuan block type degrades to its text instead of vanishing.
    private static func block(_ n: Node, indent: String, avDir: URL?) -> String {
        func line(_ s: String) -> String {
            s.isEmpty ? "" : s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { indent + $0 }.joined(separator: "\n") + "\n"
        }
        switch type(n) {
        case "NodeHeading":
            let level = n["HeadingLevel"] as? Int ?? 1
            return line(String(repeating: "#", count: max(level, 1)) + " " + inline(children(n)))
        case "NodeParagraph":
            return line(inline(children(n)))
        case "NodeList", "NodeMindmap":
            return children(n).map { listItem($0, indent: indent, avDir: avDir) }.joined()
        case "NodeBlockquote":
            return quoted(blocks(children(n), indent: "", avDir: avDir), indent: indent)
        case "NodeCallout":
            let head = "[!\(n["CalloutType"] as? String ?? "NOTE")] \(n["CalloutTitle"] as? String ?? "")"
            return quoted(head + "\n" + blocks(children(n), indent: "", avDir: avDir), indent: indent)
        case "NodeCodeBlock":
            let code = children(n).first { type($0) == "NodeCodeBlockCode" }.map(data) ?? ""
            return line("```\n" + code.trimmingCharacters(in: .newlines) + "\n```")
        case "NodeMathBlock":
            let math = children(n).first { type($0) == "NodeMathBlockContent" }.map(data) ?? ""
            return line("$$\n" + math + "\n$$")
        case "NodeTable":
            return table(n, indent: indent)
        case "NodeTabItem":
            return line("**\(n["TabItemTitle"] as? String ?? "Tab")**") + blocks(children(n), indent: indent, avDir: avDir)
        case "NodeHTMLBlock":
            return line(stripTags(data(n)))
        case "NodeThematicBreak":
            return line("---")
        case "NodeAttributeView":
            return database(n, indent: indent, avDir: avDir)
        case "NodeBlockQueryEmbed", "NodeIFrame", "NodeVideo", "NodeAudio", "NodeWidget",
             "NodeKramdownBlockIAL":
            return ""   // embedded queries, media: no readable text in the note itself
        default:
            return blocks(children(n), indent: indent, avDir: avDir)   // Document, SuperBlock, Tabs, …
        }
    }

    private static func listItem(_ n: Node, indent: String, avDir: URL?) -> String {
        let list = n["ListData"] as? [String: Any] ?? [:]
        var marker = (list["Typ"] as? Int) == 1 ? "\(list["Num"] as? Int ?? 1). " : "- "
        if (list["Typ"] as? Int) == 3 { marker += (list["Checked"] as? Bool) == true ? "[x] " : "[ ] " }
        let body = blocks(children(n), indent: indent + "  ", avDir: avDir)
        guard !body.isEmpty else { return "" }
        // Swap the first line's continuation indent for the marker.
        return indent + marker + body.dropFirst(indent.count + 2)
    }

    private static func quoted(_ body: String, indent: String) -> String {
        body.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
            .map { indent + "> " + $0 }.joined(separator: "\n") + "\n"
    }

    private static func table(_ n: Node, indent: String) -> String {
        var rows: [String] = []
        for part in children(n) {   // NodeTableHead (wrapping a row) + NodeTableRow…
            let partRows = type(part) == "NodeTableHead" ? children(part) : [part]
            for row in partRows where type(row) == "NodeTableRow" {
                let cells = children(row).map { inline(children($0)).replacingOccurrences(of: "|", with: "\\|") }
                rows.append(indent + "| " + cells.joined(separator: " | ") + " |")
                if type(part) == "NodeTableHead" {
                    rows.append(indent + "|" + String(repeating: " --- |", count: cells.count))
                }
            }
        }
        return rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
    }

    // MARK: Databases (attribute views)

    /// A database block only carries its ID; the rows live in `data/storage/av/<id>.json`, one
    /// column per key, values matched by row `blockID`. Rendered as a Markdown table.
    private static let maxDatabaseRows = 50

    private static func database(_ n: Node, indent: String, avDir: URL?) -> String {
        guard let avDir,
              let id = data(n).range(of: #"data-av-id="([^"]+)""#, options: .regularExpression)
                .map({ String(data(n)[$0].dropFirst(12).dropLast()) }),
              let av = document(avDir.appendingPathComponent(id + ".json")),
              let keyValues = av["keyValues"] as? [Node], !keyValues.isEmpty else { return "" }
        let columns = keyValues.filter { !($0["values"] as? [Node] ?? []).isEmpty }
        // Row order = the primary (first) column's order; other columns are looked up by blockID.
        let rowIDs = (keyValues[0]["values"] as? [Node] ?? []).compactMap { $0["blockID"] as? String }
        guard !columns.isEmpty, !rowIDs.isEmpty else { return "" }
        let names = columns.map { (($0["key"] as? Node)?["name"] as? String) ?? "" }
        var lines = ["**Database: \(av["name"] as? String ?? "")**",
                     "| " + names.joined(separator: " | ") + " |",
                     "|" + String(repeating: " --- |", count: names.count)]
        for rowID in rowIDs.prefix(maxDatabaseRows) {
            let cells = columns.map { column -> String in
                let value = (column["values"] as? [Node] ?? []).first { $0["blockID"] as? String == rowID }
                return value.map(cell)?.replacingOccurrences(of: "|", with: "\\|")
                    .replacingOccurrences(of: "\n", with: " ") ?? ""
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.map { indent + $0 }.joined(separator: "\n") + "\n"
    }

    private static func cell(_ v: Node) -> String {
        let kind = v["type"] as? String ?? ""
        let payload = v[kind]
        switch kind {
        case "number":
            let num = payload as? Node ?? [:]
            guard num["isNotEmpty"] as? Bool == true else { return "" }
            if let shown = num["formattedContent"] as? String, !shown.isEmpty { return shown }
            return (num["content"] as? NSNumber)?.stringValue ?? ""
        case "select", "mSelect", "mAsset":
            return (payload as? [Node] ?? []).compactMap { ($0["name"] as? String) ?? ($0["content"] as? String) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
        case "checkbox":
            return ((payload as? Node)?["checked"] as? Bool) == true ? "✓" : ""
        case "date", "created", "updated":
            let date = payload as? Node ?? [:]
            guard date["isNotEmpty"] as? Bool ?? (kind != "date"),
                  let ms = (date["content"] as? NSNumber)?.doubleValue, ms > 0 else { return "" }
            return dayFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        default:   // block, text, url, email, phone, template, …: `{ "content": … }`
            return ((payload as? Node)?["content"] as? String) ?? ""
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: Inline

    private static func inline(_ nodes: [Node]) -> String {
        nodes.map(inline).joined().trimmingCharacters(in: .whitespaces)
    }

    private static func inline(_ n: Node) -> String {
        switch type(n) {
        case "NodeText", "NodeLinkText", "NodeCodeSpanContent", "NodeInlineMathContent":
            return data(n)
        case "NodeTextMark":
            let content = n["TextMarkTextContent"] as? String ?? ""
            let kinds = (n["TextMarkType"] as? String ?? "").split(separator: " ")
            if kinds.contains("inline-math") { return "$\(n["TextMarkInlineMathContent"] as? String ?? content)$" }
            if kinds.contains("tag") { return "#\(content)#" }
            if kinds.contains("inline-memo"), let memo = n["TextMarkInlineMemoContent"] as? String, !memo.isEmpty {
                return "\(content) (note: \(memo))"
            }
            return content
        case "NodeImage":
            let alt = children(n).filter { type($0) == "NodeLinkText" }.map(data).joined()
            return alt.isEmpty ? "" : "[image: \(alt)]"
        case "NodeBr":
            return "\n"
        case "NodeKramdownSpanIAL", "NodeLinkDest", "NodeLinkTitle", "NodeLinkSpace", "NodeBang",
             "NodeOpenBracket", "NodeCloseBracket", "NodeOpenParen", "NodeCloseParen", "NodeBackslash",
             "NodeTaskListItemMarker":
            return ""
        default:
            return inline(children(n))
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
