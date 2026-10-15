// Run: bash Scripts/test_siyuan.sh
// Synthetic on-disk fixtures, using SiYuan's persisted AST fields. Parser shape references:
// https://github.com/88250/lute/blob/8bf47cd864f7/ast/node.go
// https://github.com/siyuan-note/siyuan/tree/7a7430d8a3cf362e23de004a454ddabe651dc778/app/guide
// All parsing, workspace traversal, candidate identities and bucketing use production code.
import Foundation

@main enum SiYuanChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sentient-siyuan-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var passed = 0, failed = 0
        func check(_ value: Bool, _ message: String) {
            if value { passed += 1; print("PASS: \(message)") }
            else { failed += 1; print("FAIL: \(message)") }
        }
        func write(_ value: Any, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        func paragraph(_ text: String) -> [String: Any] {
            ["Type": "NodeParagraph", "Children": [["Type": "NodeText", "Data": text]]]
        }
        let originalStamp = "20260110120000"
        let originalDate = SiYuanNote.parseStamp(originalStamp)!
        func note(_ children: [[String: Any]], to url: URL, stamp: String = "20260110120000", title: String = "Fixture") throws {
            try write(["Type": "NodeDocument", "Properties": ["title": title, "updated": stamp], "Children": children], to: url)
        }
        let documentURL = root.appendingPathComponent("parser.sy")
        func render(_ children: [[String: Any]], databases: URL? = nil) throws -> SiYuanNote {
            try note(children, to: documentURL)
            return SiYuanNote(contentsOf: documentURL, databases: databases)!
        }
        func task(_ marker: [String: Any]?, legacyChecked: Bool = false) -> [String: Any] {
            let contents: [[String: Any]] = marker.map { [$0, paragraph("Task")] } ?? [paragraph("Task")]
            return ["Type": "NodeList", "ListData": ["Typ": 3], "Children": [[
                "Type": "NodeListItem", "ListData": ["Typ": 3, "Checked": legacyChecked], "Children": contents
            ]]]
        }
        let checked = try render([task(["Type": "NodeTaskListItemMarker", "TaskListItemChecked": true])])
        check(checked.body == "- [x] Task", "completed task marker remains completed")
        let unchecked = try render([task(["Type": "NodeTaskListItemMarker"], legacyChecked: true)])
        check(unchecked.body == "- [ ] Task", "omitted false field on marker overrides stale ListData")
        let legacyTask = try render([task(nil, legacyChecked: true)])
        check(legacyTask.body == "- [x] Task", "legacy ListData-only completion remains supported")
        for (raw, expected) in [(32, " "), (120, "x"), (88, "x"), (47, "/")] {
            let rendered = try render([task(["Type": "NodeTaskListItemMarker", "TaskListItemMarker": raw, "TaskListItemChecked": true])])
            check(rendered.body == "- [\(expected)] Task", "explicit task marker \(raw) takes precedence")
        }
        let ordinary = try render([paragraph("Ordinary text")])
        check(ordinary.body == "Ordinary text" && ordinary.updated == originalDate, "ordinary note text and date remain intact")

        let avID = "20260110120000-db00001"
        let avDir = root.appendingPathComponent("av")
        let avFile = avDir.appendingPathComponent(avID + ".json")
        try write(["name": "Tasks", "keyValues": [[
            "key": ["name": "Task", "type": "block"],
            "values": [["blockID": "20260110120000-row0001", "type": "block", "block": ["content": "Database sentinel"]]]
        ]]], to: avFile)
        let firstSave = originalDate.addingTimeInterval(3600)
        try fm.setAttributes([.modificationDate: firstSave], ofItemAtPath: avFile.path)
        let modernBlock: [String: Any] = ["Type": "NodeAttributeView", "AttributeViewID": avID]
        let modern = try render([["Type": "NodeSuperBlock", "Children": [modernBlock]]], databases: avDir)
        check(modern.body.contains("Database sentinel"), "nested structured database block renders rows")
        check(modern.updated == firstSave, "structured database save participates in freshness")
        let secondSave = firstSave.addingTimeInterval(3600)
        try fm.setAttributes([.modificationDate: secondSave], ofItemAtPath: avFile.path)
        let edited = SiYuanNote(contentsOf: documentURL, databases: avDir)!
        check(edited.updated == secondSave, "database-only edit advances unchanged note timestamp")
        let markup = "<div data-av-id=\"\(avID)\"></div>"
        let legacy = try render([["Type": "NodeAttributeView", "Data": markup]], databases: avDir)
        check(legacy.body.contains("Database sentinel") && legacy.updated == secondSave, "legacy database markup renders and tracks edits")
        let example = try render([["Type": "NodeCodeBlock", "Children": [["Type": "NodeCodeBlockCode", "Data": markup]]]], databases: avDir)
        check(example.updated == originalDate, "database-looking code example does not change freshness")
        let missing = try render([["Type": "NodeAttributeView", "AttributeViewID": "20260110120000-missing"]], databases: avDir)
        check(missing.body.isEmpty && missing.updated == originalDate, "missing database is skipped without inventing an edit")
        let invalid = try render([["Type": "NodeAttributeView", "AttributeViewID": "../outside"]], databases: avDir)
        check(invalid.body.isEmpty && invalid.updated == originalDate, "invalid database identifiers are not followed")

        // Independent checkpoints must retain unseen older notes, including imports into an
        // already-open notebook. Dates come from the note rather than fixture write times.
        let workspace = root.appendingPathComponent("workspace")
        let currentNotebook = workspace.appendingPathComponent("data/current")
        let closedNotebook = workspace.appendingPathComponent("data/closed")
        func notebook(_ dir: URL, closed: Bool) throws {
            try write(["name": dir.lastPathComponent, "closed": closed], to: dir.appendingPathComponent(".siyuan/conf.json"))
        }
        try notebook(currentNotebook, closed: false)
        try notebook(closedNotebook, closed: true)
        let currentURL = currentNotebook.appendingPathComponent("20260110120000-current.sy")
        let olderURL = closedNotebook.appendingPathComponent("20250110120000-oldnote.sy")
        try note([paragraph("Recent note")], to: currentURL)
        try note([paragraph("Old notebook note")], to: olderURL, stamp: "20250110120000")
        let connector = SiYuanConnector(source: SiYuanSource(workspaces: [workspace]))
        let initial = try connector.buckets(since: [:])
        check(initial.count == 1 && initial[0].items.count == 1, "closed notebook is not listed")
        var marks = Dictionary(uniqueKeysWithValues: initial.map { ($0.key, $0.items[0].key) })
        try notebook(closedNotebook, closed: false)
        let reopened = try connector.buckets(since: marks)
        let unseen = reopened.filter { marks[$0.key] == nil }
        check(unseen.count == 1 && unseen[0].items[0].item.metadata["noteText"]!.contains("Old notebook note"),
              "previously closed older notebook gets a fresh checkpoint")
        for bucket in reopened { marks[bucket.key] = bucket.items[0].key }
        let unchanged = try connector.buckets(since: marks)
        check(unchanged.allSatisfy { marks[$0.key] == $0.items[0].key }, "unchanged notes keep their checkpoint across runs")
        try note([paragraph("Imported old note")], to: currentNotebook.appendingPathComponent("20240110120000-import1.sy"), stamp: "20240110120000")
        let imported = try connector.buckets(since: marks).filter { marks[$0.key] == nil }
        check(imported.count == 1 && imported[0].items[0].item.metadata["noteText"]!.contains("Imported old note"),
              "old import into an existing notebook gets a fresh checkpoint")
        try note([paragraph("Edited note")], to: currentURL, stamp: "20260112120000")
        let changed = try connector.buckets(since: marks).filter { bucket in
            marks[bucket.key].map { bucket.items[0].key > $0 } ?? false
        }
        check(changed.count == 1 && changed[0].key == initial[0].key, "text edit advances the same document checkpoint")

        let copiedWorkspace = root.appendingPathComponent("copy")
        try fm.copyItem(at: workspace, to: copiedWorkspace)
        let combined = try SiYuanConnector(source: SiYuanSource(workspaces: [workspace, copiedWorkspace])).buckets(since: [:])
        check(combined.count == 6 && Set(combined.map(\.key)).count == 6, "workspace copies do not share document checkpoints")
        check(Set(combined.flatMap { $0.items.map { $0.item.id } }).count == 6, "workspace copies also have distinct survivor identities")
        let alias = root.appendingPathComponent("workspace-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: workspace)
        let aliases = try SiYuanConnector(source: SiYuanSource(workspaces: [workspace, alias, workspace])).buckets(since: [:])
        check(aliases.count == 3, "duplicate and symlink workspace entries are read once")
        let titleOnly = currentNotebook.appendingPathComponent("20240110120000-empty01.sy")
        try note([], to: titleOnly)
        check(SiYuanSource(workspaces: [workspace]).eligibleNotes().count == 3, "title-only notes remain excluded")

        print("SiYuan: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}

// Only unrelated telemetry and the optional calendar payload are stubbed. No user preferences,
// models, workspace registry or account services are touched by these offline checks.
enum SourceHealth {
    static func checkListingCollapse(source: String, bucketKey: String, count: Int) {}
}
enum AppleCalendarSource { struct Snapshot: Sendable {} }
