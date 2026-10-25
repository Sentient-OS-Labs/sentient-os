//
//  NightSkyModel.swift
//  Sentient OS macOS
//
//  The Night Sky's brain: owns the graph + simulation + camera, advances everything once per
//  frame (tick — called from the Canvas closure, so there are NO per-frame @State/@Published
//  writes; see Orb.swift's performance rules), and answers all interaction math (hit-testing,
//  pan/zoom-at-cursor, star dragging, hover focus, the photon pulses, the back-from-reader
//  highlight). Published state is only what SwiftUI overlays need at human speed: the loaded
//  graph and the hover card.
//
//  Key methods: load(vault:) · tick(now:size:) · toScreen/toWorld · hitTest ·
//  updateHover/clearHover · panBy/zoom(by:at:) · beginDrag/dragStar/endDrag · highlight(url:).
//

import SwiftUI
import Combine

/// The viewport: `pan` is the screen-space offset of the world origin from the viewport center.
struct SkyCamera {
    var pan: CGPoint = .zero
    var zoom: CGFloat = 1
    var initialized = false
}

/// One photon traveling along one thread — the rare "synapse fires" moment.
struct SkyPulse {
    let edge: Int
    let start: TimeInterval
    let duration: TimeInterval
}

/// What the hover card shows (published only when the hovered star changes).
struct SkyHoverInfo: Equatable {
    let url: URL
    let title: String
    let domainName: String
    let preview: String
    let recentlyChanged: Bool
    let anchor: CGPoint          // the star's screen position when hover began
}

final class NightSkyModel: ObservableObject {
    @Published private(set) var graph: SkyGraph?
    @Published private(set) var hoverInfo: SkyHoverInfo?

    private(set) var sim: SkySimulation?
    var camera = SkyCamera()
    var minimumZoom: CGFloat = 0.35
    var animates = true {
        didSet {
            guard oldValue != animates else { return }
            lastTick = nil
            if !animates { pulses = [] }
            objectWillChange.send()
        }
    }

    // Per-star ignite blend (0…1), eased every tick — hover, neighbors, and the highlight ride it.
    private(set) var glow: [Double] = []
    private(set) var hoverIndex: Int?
    private(set) var focusIndex: Int?          // outlives hover until the blend fades out
    private(set) var focusNeighbors: Set<Int> = []
    private(set) var focusBlend: Double = 0    // global dim-the-rest amount

    // The "you were just reading this" glow when returning from the reader.
    private var pendingHighlightURL: URL?
    private(set) var highlightIndex: Int?
    private var highlightBlend: Double = 0

    private(set) var pulses: [SkyPulse] = []
    private var nextPulseAt: TimeInterval = .infinity
    let dust = SkyRenderer.makeDust()

    private var lastTick: TimeInterval?
    private var dragging = false
    private var preservesPreviewGraph = false
    private var loadRevision: UInt64 = 0

    // MARK: Loading

    /// Build (or refresh) the graph from the vault. First load runs the assembly entrance;
    /// re-entries keep every star exactly where the user left it.
    @MainActor
    func load(vault: KnowledgeVault?) async {
        guard !Task.isCancelled else { return }
        loadRevision &+= 1
        let revision = loadRevision
        // A missing vault is an authoritative new snapshot, not permission to leave deleted
        // notes clickable. Only the explicit preview factory keeps its synthetic nil-vault sky.
        guard let vault else {
            if !preservesPreviewGraph { clearVault() }
            return
        }
        let g = await Task.detached(priority: .userInitiated) { SkyGraph.build(from: vault) }.value
        guard !Task.isCancelled, revision == loadRevision else { return }
        preservesPreviewGraph = false
        if let old = graph, let oldSim = sim {
            let positions = Dictionary(uniqueKeysWithValues: zip(old.nodes.map(\.url), oldSim.pos))
            let s = SkySimulation(graph: g, entrance: true)
            s.restore(positions: positions)
            sim = s
        } else {
            sim = SkySimulation(graph: g, entrance: true)      // the assembly moment
            Log("Night Sky: \(g.nodes.count) stars · \(g.edges.count) threads · \(g.domains.count) constellations")
        }
        graph = g
        glow = [Double](repeating: 0, count: g.nodes.count)
        clearFocus()
        resolvePendingHighlight()
    }

    private func clearVault() {
        sim?.endDrag()
        dragging = false
        sim = nil
        glow = []
        clearFocus()
        pendingHighlightURL = nil
        highlightIndex = nil
        highlightBlend = 0
        pulses = []
        nextPulseAt = .infinity
        lastTick = nil
        graph = nil
    }

    // MARK: The frame tick (called from the Canvas closure — main thread, no published writes)

    func tick(now: TimeInterval, size: CGSize) {
        guard let sim, let graph else { return }
        if !camera.initialized {
            camera.zoom = min(max(min(size.width, size.height) / (SkyTuning.ringRadius * 2 * 1.55), minimumZoom), 1.1)
            camera.initialized = true
        }
        if !animates {
            // Static presentation still responds to deliberate pan/zoom/drag and hover.
            // It has no ambient motion, pulse scheduling or catch-up after hidden time.
            if dragging { sim.step(elapsed: 1.0 / 60) }
            else if sim.isAwake { sim.settle() }
            for i in glow.indices {
                let hover: Double = i == hoverIndex ? 1 : (hoverIndex != nil && focusNeighbors.contains(i) ? 0.75 : 0)
                glow[i] = max(hover, i == highlightIndex ? highlightBlend : 0)
            }
            focusBlend = hoverIndex == nil ? 0 : 1
            if hoverIndex == nil { focusIndex = nil; focusNeighbors = [] }
            pulses = []; lastTick = nil
            return
        }
        let dt = lastTick.map { min(max(now - $0, 0), 1.0 / 20) } ?? 1.0 / 60
        lastTick = now

        sim.step(elapsed: dt)

        // Ease the ignite blends toward their targets (breathe in ~fast, out soft).
        let rate = 1 - exp(-dt * 9)
        for i in glow.indices {
            var target: Double = 0
            if i == hoverIndex { target = 1 }
            else if hoverIndex != nil && focusNeighbors.contains(i) { target = 0.75 }
            if i == highlightIndex { target = max(target, highlightBlend) }
            glow[i] += (target - glow[i]) * rate
        }
        let globalTarget: Double = hoverIndex != nil ? 1 : 0
        focusBlend += (globalTarget - focusBlend) * rate
        if hoverIndex == nil && focusBlend < 0.02 { focusIndex = nil; focusNeighbors = [] }

        // The return-from-reader highlight decays over ~2.6s.
        if highlightIndex != nil {
            highlightBlend -= dt / 2.6
            if highlightBlend <= 0 { highlightBlend = 0; highlightIndex = nil }
        }

        // Photon pulses: rare, deliberate, and only once the sky is calm.
        if sim.alpha < 0.25, !graph.edges.isEmpty {
            if nextPulseAt == .infinity { nextPulseAt = now + Double.random(in: 2.0...4.0) }
            if now >= nextPulseAt {
                pulses.append(SkyPulse(edge: Int.random(in: 0..<graph.edges.count), start: now, duration: 1.35))
                nextPulseAt = now + Double.random(in: 4.5...8.5)
            }
        }
        pulses.removeAll { now - $0.start > $0.duration }
    }

    // MARK: Camera math

    /// Fit an embedded example using the actual settled graph, without changing the normal
    /// Knowledge page's camera. Call on viewport-size changes, not on every render or reopen.
    func fitToContent(in size: CGSize, padding: CGFloat = 24) {
        guard let positions = sim?.pos, let first = positions.first,
              size.width > 2 * padding, size.height > 2 * padding else { return }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in positions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let scale = min((size.width - 2 * padding) / max(1, maxX - minX + 96),
                        (size.height - 2 * padding) / max(1, maxY - minY + 96))
        camera.zoom = min(1.1, max(minimumZoom, scale))
        camera.pan = CGPoint(x: -(minX + maxX) / 2 * camera.zoom, y: -(minY + maxY) / 2 * camera.zoom)
        camera.initialized = true
        if hoverInfo != nil { clearHover() }
        objectWillChange.send()
    }

    private func redrawIfStatic() { if !animates { objectWillChange.send() } }

    func toScreen(_ w: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + camera.pan.x + w.x * camera.zoom,
                y: size.height / 2 + camera.pan.y + w.y * camera.zoom)
    }

    func toWorld(_ s: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (s.x - size.width / 2 - camera.pan.x) / camera.zoom,
                y: (s.y - size.height / 2 - camera.pan.y) / camera.zoom)
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        camera.pan.x += dx
        camera.pan.y += dy
        clampPan()
        dismissHover()
        redrawIfStatic()
    }

    /// Zoom keeping the world point under the cursor fixed (Figma-style).
    func zoom(by factor: CGFloat, at s: CGPoint, size: CGSize) {
        let newZoom = min(max(camera.zoom * factor, minimumZoom), 4.0)
        let w = toWorld(s, size: size)
        camera.zoom = newZoom
        camera.pan = CGPoint(x: s.x - size.width / 2 - w.x * newZoom,
                             y: s.y - size.height / 2 - w.y * newZoom)
        clampPan()
        dismissHover()
        redrawIfStatic()
    }

    private func clampPan() {
        let limit = SkyTuning.ringRadius * 2.3 * camera.zoom + 200
        camera.pan.x = min(max(camera.pan.x, -limit), limit)
        camera.pan.y = min(max(camera.pan.y, -limit), limit)
    }

    // MARK: Hit testing + hover

    /// Nearest star within a forgiving reach of the cursor (screen point), or nil.
    func hitTest(_ s: CGPoint, size: CGSize) -> Int? {
        guard let sim, let graph else { return nil }
        let w = toWorld(s, size: size)
        let reach = max(16 / camera.zoom, 10)
        var best: (i: Int, d: CGFloat)?
        for i in graph.nodes.indices {
            let d = (sim.pos[i] - w).length
            if d < reach && d < (best?.d ?? .infinity) { best = (i, d) }
        }
        return best?.i
    }

    func updateHover(_ s: CGPoint, size: CGSize) {
        guard !dragging else { return }
        let hit = hitTest(s, size: size)
        guard hit != hoverIndex else { return }
        hoverIndex = hit
        if let h = hit, let graph, let sim {
            focusIndex = h
            focusNeighbors = Set(graph.adjacency[h])
            let n = graph.nodes[h]
            hoverInfo = SkyHoverInfo(url: n.url,
                                     title: n.title,
                                     domainName: n.isRoot ? "You" : (n.domain >= 0 ? graph.domains[n.domain] : "Root"),
                                     preview: n.preview,
                                     recentlyChanged: n.recentlyChanged,
                                     anchor: toScreen(sim.pos[h], size: size))
        } else {
            hoverInfo = nil
        }
    }

    func clearHover() { dismissHover() }

    private func dismissHover() {
        guard hoverIndex != nil || hoverInfo != nil else { return }
        hoverIndex = nil
        hoverInfo = nil
    }

    // MARK: Star dragging

    func beginDrag(_ i: Int) {
        dragging = true
        dismissHover()
        sim?.beginDrag(i)
        redrawIfStatic()
    }

    func dragStar(to s: CGPoint, size: CGSize) {
        sim?.drag(to: toWorld(s, size: size))
        redrawIfStatic()
    }

    func endDrag() {
        let wasDragging = dragging
        dragging = false
        sim?.endDrag()
        if wasDragging { redrawIfStatic() }
    }

    func nodeURL(_ i: Int) -> URL? {
        guard let graph, graph.nodes.indices.contains(i) else { return nil }
        return graph.nodes[i].url
    }

    /// The hover card's frame — ONE source of truth shared by the SwiftUI overlay (position) and
    /// the renderer (so star labels never slide underneath the card). Prefers below-right of the
    /// star, flipping near the window's edges.
    func hoverCardRect(in size: CGSize) -> CGRect? {
        guard let info = hoverInfo else { return nil }
        let w = min(250, max(1, size.width - 32)), h: CGFloat = 112
        var x = info.anchor.x + 24
        if x + w > size.width - 16 { x = info.anchor.x - 24 - w }
        var y = info.anchor.y + 26
        if y + h > size.height - 16 { y = info.anchor.y - 26 - h }
        x = min(max(16, x), max(16, size.width - w - 16))
        y = min(max(16, y), max(16, size.height - h - 16))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Where the sun's SpinningLogo overlay belongs this frame (screen center, diameter, opacity).
    /// The canvas draws only the sun's light bed; the actual brand mark floats above it.
    func sunOverlay(size: CGSize) -> (center: CGPoint, diameter: CGFloat, opacity: Double)? {
        guard let graph, let sim, let root = graph.rootIndex, camera.initialized else { return nil }
        let zf = CGFloat(pow(Double(camera.zoom), 0.62))
        let reveal = min(1, (1 - sim.alpha) * 3 + 0.15)
        return (toScreen(sim.pos[root], size: size), 30 * zf, reveal)
    }

    // MARK: The back-from-reader highlight

    /// Make this note's star glow for a beat when the sky next appears ("you were just here").
    func highlight(_ url: URL) {
        pendingHighlightURL = url
        resolvePendingHighlight()
        redrawIfStatic()
    }

    private func resolvePendingHighlight() {
        guard let url = pendingHighlightURL, let graph else { return }
        pendingHighlightURL = nil
        guard let i = graph.nodes.firstIndex(where: { $0.url == url }) else { return }
        highlightIndex = i
        highlightBlend = 1.0
    }

    // MARK: Preview factory (deterministic — renders the mock galaxy already settled)

    static func preview(graph: SkyGraph = .mock(), hovering: Int? = nil, minimumZoom: CGFloat = 0.35) -> NightSkyModel {
        let m = NightSkyModel()
        m.preservesPreviewGraph = true
        m.minimumZoom = minimumZoom
        let g = graph
        m.graph = g
        m.sim = SkySimulation(graph: g, entrance: false)
        m.glow = [Double](repeating: 0, count: g.nodes.count)
        if let h = hovering, g.nodes.indices.contains(h) {
            m.hoverIndex = h
            m.focusIndex = h
            m.focusNeighbors = Set(g.adjacency[h])
            m.focusBlend = 1
            m.glow[h] = 1
            for n in g.adjacency[h] { m.glow[n] = 0.75 }
        }
        return m
    }

    private func clearFocus() {
        hoverIndex = nil
        hoverInfo = nil
        focusIndex = nil
        focusNeighbors = []
        focusBlend = 0
    }
}
