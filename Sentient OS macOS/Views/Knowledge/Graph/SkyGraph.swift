//
//  SkyGraph.swift
//  Sentient OS macOS
//
//  Data for the Knowledge window's Night Sky (the graph view): every vault note becomes a star,
//  every resolved [[wikilink]] a thread. One pass over the on-disk vault reads each body once,
//  extracting links (resolved through KnowledgeVault.titleIndex), a clean hover-card preview
//  line, and a "changed last night" flag. Top-level folders become constellations (domains),
//  ordered biggest-first for palette assignment; the root README is the sun.
//
//  Key types: SkyNode · SkyEdge · SkyGraph (.build(from:) / .mock() for previews).
//  Physics: SkySimulation.swift · drawing: SkyRenderer.swift · view: NightSkyView.swift.
//  Doc: Documentation/Knowledge Viewer.md
//

import Foundation

/// One star: a vault note plus everything the sky needs to draw it.
struct SkyNode: Identifiable {
    let url: URL
    let title: String            // filename stem — the same name the sidebar shows
    let domain: Int              // index into SkyGraph.domains · -1 = the root README (the sun)
    var degree: Int              // resolved wikilink connections (deduped, undirected)
    let isRoot: Bool
    let recentlyChanged: Bool    // modified in the last 36h → the dawn shimmer
    let preview: String          // first readable body line (cleaned) — the hover card's one-liner
    let twinklePhase: Double     // stable per-note personality (hashed from the path, so a star
    let twinkleSpeed: Double     //  twinkles the same way every night)

    var id: URL { url }
}

/// One thread: an undirected, deduplicated wikilink between two stars (node indices).
struct SkyEdge {
    let a: Int
    let b: Int
    let sameDomain: Bool
}

struct SkyGraph {
    let nodes: [SkyNode]
    let edges: [SkyEdge]
    let adjacency: [[Int]]       // node index → neighbor node indices
    let domains: [String]        // constellation names, biggest first
    let rootIndex: Int?          // the README's node index, if the vault has one
    let maxDegree: Int           // for star-brightness normalization (≥ 1)

    // MARK: Build from the real vault

    static func build(from vault: KnowledgeVault) -> SkyGraph {
        let notes = vault.allNotes                       // includes the README
        let rootPath = vault.root.standardizedFileURL.path

        // Constellations = top-level folders, biggest first (ties alphabetical, so palette
        // assignment is stable run to run).
        var noteDomainNames: [String?] = []
        var domainCounts: [String: Int] = [:]
        for n in notes {
            let d = (n.url == vault.readme) ? nil : topFolder(of: n.url, rootPath: rootPath)
            noteDomainNames.append(d)
            if let d { domainCounts[d, default: 0] += 1 }
        }
        let domains = domainCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
        let domainIndex = Dictionary(uniqueKeysWithValues: domains.enumerated().map { ($1, $0) })
        let urlIndex = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($1.url, $0) })

        // One pass over the bodies: wikilink edges + the hover preview + recency.
        var pairs = Set<EdgePair>()
        var previews = [String](repeating: "", count: notes.count)
        var recent = [Bool](repeating: false, count: notes.count)
        let recencyFloor = Date().addingTimeInterval(-36 * 3600)
        for (i, n) in notes.enumerated() {
            let body = KnowledgeVault.read(n.url).markdown
            previews[i] = previewLine(from: body)
            for m in body.matches(of: #/\[\[([^\]]+)\]\]/#) {
                var target = String(m.output.1)
                if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }    // [[X|alias]]
                if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }  // [[X#heading]]
                guard let dest = vault.resolve(target), let j = urlIndex[dest], j != i else { continue }
                pairs.insert(EdgePair(a: min(i, j), b: max(i, j)))
            }
            if let mtime = try? n.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                recent[i] = mtime > recencyFloor
            }
        }
        // Bulk-change guard: a first build (or a stage-then-swap that touched every mtime) would
        // make the WHOLE sky shimmer amber — which says nothing. Shimmer only when "recent" is
        // actually selective.
        if recent.filter({ $0 }).count > max(4, notes.count * 35 / 100) {
            recent = [Bool](repeating: false, count: notes.count)
        }

        let nodes: [SkyNode] = notes.enumerated().map { i, n in
            let isRoot = n.url == vault.readme
            let h = stableHash(n.url.path)
            return SkyNode(url: n.url,
                           title: isRoot ? "Overview" : n.name,
                           domain: noteDomainNames[i].flatMap { domainIndex[$0] } ?? -1,
                           degree: 0,
                           isRoot: isRoot,
                           recentlyChanged: recent[i],
                           preview: previews[i],
                           twinklePhase: Double(h % 6283) / 1000.0,
                           twinkleSpeed: 1.1 + Double((h >> 16) % 1000) / 1000.0 * 2.1)
        }
        return finish(nodes: nodes, pairs: pairs, domains: domains)
    }

    /// The first path component under the vault root, if the note lives inside a folder.
    private static func topFolder(of url: URL, rootPath: String) -> String? {
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(rootPath) else { return nil }
        let rel = p.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let comps = rel.components(separatedBy: "/")
        return comps.count >= 2 ? comps.first : nil
    }

    /// First readable line of a body, cleaned into plain prose for the hover card.
    private static func previewLine(from body: String) -> String {
        for raw in body.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix("---") || line.hasPrefix("|") || line.hasPrefix(">") { continue }
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            line = line.replacing(#/\[\[([^\]|]+)\|([^\]]+)\]\]/#) { String($0.output.2) }   // alias wins
            line = line.replacing(#/\[\[([^\]]+)\]\]/#) { String($0.output.1) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if line.count > 150 { line = String(line.prefix(150)) + "…" }
            return line
        }
        return ""
    }

    /// FNV-1a — stable across launches (String.hashValue is not), so twinkle personality sticks.
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    // MARK: Shared assembly (degrees, adjacency, sameDomain)

    fileprivate struct EdgePair: Hashable { let a: Int; let b: Int }

    private static func finish(nodes: [SkyNode], pairs: Set<EdgePair>, domains: [String]) -> SkyGraph {
        var nodes = nodes
        var adjacency = [[Int]](repeating: [], count: nodes.count)
        let edges = pairs.sorted { ($0.a, $0.b) < ($1.a, $1.b) }.map { p in
            nodes[p.a].degree += 1
            nodes[p.b].degree += 1
            adjacency[p.a].append(p.b)
            adjacency[p.b].append(p.a)
            return SkyEdge(a: p.a, b: p.b,
                           sameDomain: nodes[p.a].domain == nodes[p.b].domain && nodes[p.a].domain >= 0)
        }
        return SkyGraph(nodes: nodes,
                        edges: edges,
                        adjacency: adjacency,
                        domains: domains,
                        rootIndex: nodes.firstIndex(where: \.isRoot),
                        maxDegree: max(nodes.map(\.degree).max() ?? 1, 1))
    }

    // MARK: Mock (previews only — seeded, deterministic)

    static func mock() -> SkyGraph {
        var rng = SplitMix64(seed: 7)
        let spec: [(name: String, size: Int)] = [
            ("Sentient OS", 20), ("Career & Network", 17), ("AI Research", 15), ("Health", 13),
            ("University", 12), ("Life Admin", 10), ("Relationships", 9), ("Identity", 7),
        ]
        let bank = ["Launch Timeline", "Investor Outreach", "Pitch Notes", "Quantization Runs",
                    "Housing Search", "Visa Admin", "Gym Protocol", "Reading List", "Meeting Prep",
                    "Weekly Review", "Flight Options", "Course Plan", "Demo Script", "Press Kit",
                    "Sleep Log", "Budget", "Networking Events", "Research Ideas", "Beta Waitlist",
                    "Product Thesis", "Roadmap", "Old Friends", "Side Quests", "Archive"]

        var nodes: [SkyNode] = []
        var pairs = Set<EdgePair>()
        func addNode(_ title: String, domain: Int, isRoot: Bool = false, recent: Bool = false) -> Int {
            let h = stableHash("\(domain)/\(title)/\(nodes.count)")
            nodes.append(SkyNode(url: URL(fileURLWithPath: "/mock/\(domain)/\(nodes.count) \(title).md"),
                                 title: title, domain: domain, degree: 0, isRoot: isRoot,
                                 recentlyChanged: recent,
                                 preview: "A short line of what this note remembers about your life.",
                                 twinklePhase: Double(h % 6283) / 1000.0,
                                 twinkleSpeed: 1.1 + Double((h >> 16) % 1000) / 1000.0 * 2.1))
            return nodes.count - 1
        }

        let root = addNode("Overview", domain: -1, isRoot: true)
        var titleCursor = 0
        var hubs: [Int] = []
        var recentBudget = 4
        for (d, s) in spec.enumerated() {
            let hub = addNode("\(s.name) Map", domain: d)
            hubs.append(hub)
            pairs.insert(EdgePair(a: root, b: hub))
            var members: [Int] = []
            for _ in 0..<s.size {
                let title = bank[titleCursor % bank.count] + (titleCursor >= bank.count ? " \(titleCursor / bank.count + 1)" : "")
                titleCursor += 1
                let recent = recentBudget > 0 && UInt64.random(in: 0..<10, using: &rng) == 0
                if recent { recentBudget -= 1 }
                members.append(addNode(title, domain: d, recent: recent))
            }
            for m in members {
                if UInt64.random(in: 0..<4, using: &rng) != 0 {                       // hub → ~75%
                    pairs.insert(EdgePair(a: min(hub, m), b: max(hub, m)))
                }
                if UInt64.random(in: 0..<3, using: &rng) == 0, let other = members.randomElement(using: &rng), other != m {
                    pairs.insert(EdgePair(a: min(m, other), b: max(m, other)))        // intra sprinkle
                }
            }
        }
        for _ in 0..<20 {                                                             // cross-domain bridges
            let a = Int.random(in: 1..<nodes.count, using: &rng)
            let b = Int.random(in: 1..<nodes.count, using: &rng)
            if a != b, nodes[a].domain != nodes[b].domain {
                pairs.insert(EdgePair(a: min(a, b), b: max(a, b)))
            }
        }
        return finish(nodes: nodes, pairs: pairs, domains: spec.map(\.name))
    }
}
