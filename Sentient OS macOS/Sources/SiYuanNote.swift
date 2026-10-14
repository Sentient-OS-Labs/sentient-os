//
//  SiYuanNote.swift
//  Sentient OS macOS
//
//  One SiYuan note → Markdown. SiYuan keeps each note as a `.sy` file: a JSON block tree whose
//  filename is a block ID, so a plain-text read would hand the model IDs and node types instead of
//  the note. This renders the tree (headings, lists, tasks, quotes, callouts, code, math, tables,
//  tabs) and inlines database blocks, whose rows live apart in `data/storage/av/<id>.json`.
//  Pure: no walking, no ordering — SiYuanSource finds the notes and builds the breadcrumb.
//

import Foundation

struct SiYuanNote {
    let title: String
    /// When the note's content last changed: the document's own "updated" stamp (which, unlike the
    /// file's mtime, does not move when sync or a re-index merely rewrites the file), or the save time
    /// of a database it shows, if later. Editing a database row never touches the note's stamp — the
    /// row lives in `storage/av/<id>.json`, and SiYuan doesn't stamp every value edit there either.
    let updated: Date?
    /// The note body as Markdown, without the title. Empty for a title-only note.
    let body: String

    /// `databases` is the workspace's `data/storage/av` folder (nil = render database blocks as nothing).
    init?(contentsOf url: URL, databases: URL?) {
        guard let data = try? Data(contentsOf: url),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? Node else { return nil }
        let props = doc["Properties"] as? [String: Any] ?? [:]
        title = props["title"] as? String ?? ""
        body = Self.blocks(Self.children(doc), indent: "", avDir: databases)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = (props["updated"] as? String).flatMap { Self.parseStamp($0) }
        let databaseSaves = Self.databaseIDs(in: doc).compactMap { id in
            databases.flatMap { try? $0.appendingPathComponent(id + ".json")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        }
        updated = ([stamp].compactMap { $0 } + databaseSaves).max()
    }

    /// Use the same reference for rendering and freshness. SiYuan persists AttributeViewID;
    /// older notes may carry data-av-id in the block's Data markup instead.
    private static func databaseID(_ n: Node) -> String? {
        guard type(n) == "NodeAttributeView" else { return nil }
        let legacyID = data(n).range(of: #"data-av-id="([^"]+)""#, options: .regularExpression)
            .map { String(data(n)[$0].dropFirst(12).dropLast()) }
        guard let id = n["AttributeViewID"] as? String ?? legacyID,
              id.range(of: #"^[0-9]{14}-[0-9a-z]{7}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    private static func databaseIDs(in n: Node) -> Set<String> {
        var ids = Set(databaseID(n).map { [$0] } ?? [])
        for child in children(n) { ids.formUnion(databaseIDs(in: child)) }
        return ids
    }

    /// SiYuan stamps (and block IDs' first 14 characters) are local-time `yyyyMMddHHmmss`.
    static func parseStamp(_ stamp: String) -> Date? {
        stampFormatter.date(from: String(stamp.prefix(14)))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func document(_ url: URL) -> Node? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Node
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
            let code = children(n).first { type($0) == "NodeCodeBlockCode" }.map { data($0) } ?? ""
            return line("```\n" + code.trimmingCharacters(in: .newlines) + "\n```")
        case "NodeMathBlock":
            let math = children(n).first { type($0) == "NodeMathBlockContent" }.map { data($0) } ?? ""
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
        if (list["Typ"] as? Int) == 3 { marker += "[\(taskMarker(n))] " }
        let body = blocks(children(n), indent: indent + "  ", avDir: avDir)
        guard !body.isEmpty else { return "" }
        // Swap the first line's continuation indent for the marker.
        return indent + marker + body.dropFirst(indent.count + 2)
    }

    private static func taskMarker(_ n: Node) -> String {
        let task = children(n).first { type($0) == "NodeTaskListItemMarker" }
        // Current SiYuan also supports markers such as [/]. Preserve those states, including
        // an explicit space, before falling back to the older checked boolean.
        if let raw = task?["TaskListItemMarker"] as? Int, (32...126).contains(raw),
           let scalar = UnicodeScalar(raw) {
            return raw == 88 ? "x" : String(scalar)
        }
        // The marker's missing boolean means false (SiYuan omits false JSON fields). Only
        // consult ListData when the marker node itself is absent in an older representation.
        let checked = task.map { ($0["TaskListItemChecked"] as? Bool) == true }
            ?? (((n["ListData"] as? Node)?["Checked"] as? Bool) == true)
        return checked ? "x" : " "
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
              let id = databaseID(n),
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
                return value.map { cell($0) }?.replacingOccurrences(of: "|", with: "\\|")
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
        nodes.map { inline($0) }.joined().trimmingCharacters(in: .whitespaces)
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
            let alt = children(n).filter { type($0) == "NodeLinkText" }.map { data($0) }.joined()
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
