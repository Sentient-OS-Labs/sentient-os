//
//  VaultTree.swift
//  Sentient OS macOS
//
//  Data layer for the Knowledge reader. Scans the on-disk markdown vault
//  (~/Sentient OS - Knowledge Base/) into a browsable tree, indexes every note title so
//  [[wikilinks]] can be resolved to files, and reads a note for display (strips the leading
//  YAML frontmatter block and promotes the first `# H1` to the title). Pure value types + one
//  synchronous loader — the view (KnowledgeView) owns all UI state.
//
//  Key types: VaultNode (a folder or a note) · KnowledgeVault (.load() / .resolve() /
//  .ancestors(of:) / .read()). Doc: Documentation/Knowledge Viewer.md
//

import Foundation

/// One node in the vault tree — a folder (with `children`) or a markdown note (a leaf).
struct VaultNode: Identifiable, Hashable {
    let url: URL
    let name: String        // folder name, or the note's filename without ".md"
    let isFolder: Bool
    var children: [VaultNode]

    var id: URL { url }

    // Equality is the synthesized full-value one — `children` included. SwiftUI decides whether to
    // re-render by comparing old vs new values with ==, so a URL-only equality here made the sidebar
    // ignore a reloaded tree whose top-level URLs hadn't changed (a note deleted inside a folder
    // stayed visible until relaunch). The tree is tiny; recursive comparison is nothing.
}

/// A loaded snapshot of the vault: the tree (README pulled out and offered as the pinned
/// "Overview"), a flat note list (search + counts), and a title→URL index for wikilinks.
/// Rebuilt each time the Knowledge window opens — the vault is small and read on demand.
struct KnowledgeVault {
    let root: URL
    let nodes: [VaultNode]           // top-level entries (folders first, then notes), README removed
    let allNotes: [VaultNode]        // every note, flattened, alphabetical (includes README)
    let titleIndex: [String: URL]    // lowercased filename stem → note URL
    let readme: URL?                 // the root README, shown pinned as "Overview"

    /// Scan `VaultGenerator.vaultRoot` into a tree. Returns nil if the vault folder doesn't exist
    /// yet (no knowledge base has been built). Cheap — only enumerates directory entries; note
    /// bodies are read lazily on selection via `read(_:)`.
    static func load() -> KnowledgeVault? {
        let root = VaultGenerator.vaultRoot
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        var index: [String: URL] = [:]
        var flat: [VaultNode] = []

        func scan(_ dir: URL) -> [VaultNode] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            var folders: [VaultNode] = []
            var notes: [VaultNode] = []
            for url in items {
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }   // .obsidian, .DS_Store, dotfiles (belt + suspenders)
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isFolder {
                    // Show ALL subfolders, including empty ones — so a folder the user just created
                    // in the viewer (empty until they add notes) appears in the tree.
                    folders.append(VaultNode(url: url, name: name, isFolder: true, children: scan(url)))
                } else if url.pathExtension.lowercased() == "md" {
                    let stem = url.deletingPathExtension().lastPathComponent
                    index[stem.lowercased()] = url
                    let node = VaultNode(url: url, name: stem, isFolder: false, children: [])
                    notes.append(node)
                    flat.append(node)
                }
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            notes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folders + notes   // folders first, then notes — like Finder / Obsidian
        }

        var top = scan(root)
        let readme = top.first { !$0.isFolder && $0.name.caseInsensitiveCompare("README") == .orderedSame }?.url
        top.removeAll { !$0.isFolder && $0.name.caseInsensitiveCompare("README") == .orderedSame }
        flat.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return KnowledgeVault(root: root, nodes: top, allNotes: flat, titleIndex: index, readme: readme)
    }

    /// Resolve a `[[wikilink]]` target (a note title / filename stem) to a note URL, if one exists.
    func resolve(_ wikilink: String) -> URL? {
        titleIndex[wikilink.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The folder URLs from the vault root down to (but excluding) `note` — so the sidebar tree
    /// can expand to reveal a note we jumped to via a wikilink.
    func ancestors(of note: URL) -> [URL] {
        var result: [URL] = []
        var dir = note.deletingLastPathComponent()
        while dir.path.hasPrefix(root.path) && dir.path != root.path {
            result.append(dir)
            dir = dir.deletingLastPathComponent()
        }
        return result
    }

    /// Read a note for display: strip a leading `---…---` YAML frontmatter block, and promote the
    /// first `# H1` to the returned title (so the body doesn't repeat it). Falls back to the
    /// filename for the title and an empty body on a read failure.
    static func read(_ url: URL) -> (title: String, markdown: String) {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var text = raw

        // Strip a leading frontmatter fence: the file opens with "---" and we drop through the
        // matching closing "---".
        if text.hasPrefix("---") {
            let lines = text.components(separatedBy: "\n")
            if let close = lines.dropFirst().firstIndex(of: "---") {
                text = lines[(close + 1)...].joined(separator: "\n")
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var title = url.deletingPathExtension().lastPathComponent
        var bodyLines = text.components(separatedBy: "\n")
        if let first = bodyLines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            bodyLines.removeFirst()
        }
        return (title, bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
