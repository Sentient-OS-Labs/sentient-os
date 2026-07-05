//
//  SkySimulation.swift
//  Sentient OS macOS
//
//  The Night Sky's physics: a small force-directed simulation — spring threads, pairwise star
//  repulsion, per-constellation ring anchors, a root sun pinned at the origin — with a cooling
//  "alpha" that starts hot (the assembly entrance: stars fly in from beyond the rim and settle)
//  and goes to sleep once still. Dragging a star reheats its neighborhood. Positions are world
//  space; NightSkyModel owns the camera. ~130 stars → the O(n²) pass is microseconds per frame.
//
//  Key methods: init(graph:) · step(elapsed:) · settle() · restore(positions:) ·
//  beginDrag/drag/endDrag. All knobs live in SkyTuning.
//

import Foundation
import CoreGraphics

/// Every physics/feel knob in one place, so taste-tuning never means spelunking.
/// ⚠️ The force constants are a BALANCED SET: they were scaled down uniformly (~×0.65 from the
/// first draft) to calm the motion WITHOUT moving the equilibrium — the settled layout only
/// depends on their ratios. Scale them together or the composition changes.
enum SkyTuning {
    static let ringRadius: CGFloat = 300       // where the constellation anchors sit (world units)
    static let repulsion: CGFloat = 1700       // pairwise star push (÷ distance²)
    static let repulsionCutoff: CGFloat = 300  // beyond this, stars ignore each other
    static let springSameRest: CGFloat = 62    // thread rest lengths + stiffness
    static let springSameK: CGFloat = 0.036
    static let springCrossRest: CGFloat = 185  // cross-constellation threads are long and loose,
    static let springCrossK: CGFloat = 0.0065  //  so bridges don't yank clusters together
    static let anchorPull: CGFloat = 0.020     // gravity toward the constellation's ring anchor
    static let centerPull: CGFloat = 0.0010    // faint pull keeping strays in the frame
    static let damping: CGFloat = 0.80         // heavy friction — overshoot dies, no boing
    static let maxSpeed: CGFloat = 14          // terminal velocity: stars GLIDE in, never slingshot
    static let alphaDecay: Double = 0.986      // per substep — the entrance settles in ~3–4s
    static let sleepAlpha: Double = 0.012
    static let dragAlpha: Double = 0.35        // heat held while a star is being dragged
}

final class SkySimulation {
    private(set) var pos: [CGPoint]
    private var vel: [CGPoint]                 // CGPoint doubling as a vector
    private(set) var alpha: Double = 1         // 1 = assembly heat → 0 = asleep
    let anchors: [CGPoint]                     // per domain index
    private let graph: SkyGraph
    private var dragIndex: Int?
    private var dragTarget: CGPoint = .zero

    var isAwake: Bool { alpha > 0 || dragIndex != nil }

    /// `entrance: true` starts hot with stars scattered beyond the rim (the assembly moment);
    /// `false` runs the same physics to rest immediately (previews, refreshes).
    init(graph: SkyGraph, entrance: Bool) {
        self.graph = graph
        let d = max(graph.domains.count, 1)
        let anchors = (0..<graph.domains.count).map { i -> CGPoint in
            let ang = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(d)
            return CGPoint(x: cos(ang) * SkyTuning.ringRadius, y: sin(ang) * SkyTuning.ringRadius)
        }
        self.anchors = anchors

        var rng = SplitMix64(seed: 0xC0FFEE ^ UInt64(graph.nodes.count))
        pos = graph.nodes.map { n in
            if n.isRoot { return .zero }
            let anchor = (n.domain >= 0 && n.domain < anchors.count) ? anchors[n.domain] : .zero
            let toward = anchor == .zero ? CGFloat.random(in: -.pi ... .pi, using: &rng)
                                         : atan2(anchor.y, anchor.x)
            let ang = toward + CGFloat.random(in: -0.55...0.55, using: &rng)
            let r = SkyTuning.ringRadius * CGFloat.random(in: 1.95...2.8, using: &rng)
            return CGPoint(x: cos(ang) * r, y: sin(ang) * r)
        }
        vel = [CGPoint](repeating: .zero, count: graph.nodes.count)
        if !entrance { settle() }
    }

    private func anchorPoint(_ domain: Int) -> CGPoint {
        domain >= 0 && domain < anchors.count ? anchors[domain] : .zero
    }

    // MARK: Stepping

    /// Advance by wall-clock `elapsed` (1–3 unit substeps — frame-rate independent enough).
    func step(elapsed: TimeInterval) {
        guard isAwake else { return }
        let n = max(1, min(3, Int((elapsed * 60).rounded())))
        for _ in 0..<n { substep() }
    }

    /// Run the physics to rest without animating (caps at ~1500 steps just in case).
    func settle() {
        for _ in 0..<1500 {
            substep()
            if alpha == 0 { break }
        }
    }

    /// Reuse positions from a previous session of the sky (matched by note URL) so a refresh
    /// never replays the entrance: matched stars stay put, new ones fade in near their anchor,
    /// and a little heat absorbs the difference.
    func restore(positions: [URL: CGPoint]) {
        var rng = SplitMix64(seed: 42)
        for (i, n) in graph.nodes.enumerated() {
            if n.isRoot { pos[i] = .zero }
            else if let p = positions[n.url] { pos[i] = p }
            else {
                let a = anchorPoint(n.domain)
                pos[i] = CGPoint(x: a.x + CGFloat.random(in: -34...34, using: &rng),
                                 y: a.y + CGFloat.random(in: -34...34, using: &rng))
            }
            vel[i] = .zero
        }
        alpha = 0.2
    }

    private func substep() {
        let count = graph.nodes.count
        guard count > 0 else { return }
        var force = [CGPoint](repeating: .zero, count: count)
        let cutoff2 = SkyTuning.repulsionCutoff * SkyTuning.repulsionCutoff

        // Pairwise repulsion — O(n²), measured trivial at this scale.
        for i in 0..<count {
            for j in (i + 1)..<count {
                var d = pos[i] - pos[j]
                var dist2 = d.x * d.x + d.y * d.y
                if dist2 > cutoff2 { continue }
                if dist2 < 0.01 {                                   // coincident guard (no NaNs)
                    d = CGPoint(x: 0.017 * CGFloat(i - j), y: 0.013)
                    dist2 = d.x * d.x + d.y * d.y
                }
                let dist = sqrt(max(dist2, 25))
                let f = SkyTuning.repulsion / max(dist2, 25)
                let dir = d * (1 / dist)
                force[i] += dir * f
                force[j] -= dir * f
            }
        }
        // Threads as springs.
        for e in graph.edges {
            let rest = e.sameDomain ? SkyTuning.springSameRest : SkyTuning.springCrossRest
            let k = e.sameDomain ? SkyTuning.springSameK : SkyTuning.springCrossK
            let d = pos[e.b] - pos[e.a]
            let dist = max(d.length, 0.01)
            let f = (dist - rest) * k
            let dir = d * (1 / dist)
            force[e.a] += dir * f
            force[e.b] -= dir * f
        }
        // Constellation anchors + the faint center keep.
        for i in 0..<count {
            let n = graph.nodes[i]
            let pull = SkyTuning.anchorPull * (n.domain >= 0 ? 1 : 0.5)
            force[i] += (anchorPoint(n.domain) - pos[i]) * pull
            force[i] += pos[i] * -SkyTuning.centerPull
        }
        // Integrate. The root sun is pinned; a dragged star obeys the cursor.
        let heat = CGFloat(0.2 + 0.8 * alpha)
        for i in 0..<count {
            if graph.nodes[i].isRoot { pos[i] = .zero; vel[i] = .zero; continue }
            if i == dragIndex { pos[i] = dragTarget; vel[i] = .zero; continue }
            vel[i] = (vel[i] + force[i] * heat) * SkyTuning.damping
            let speed = vel[i].length
            if speed > SkyTuning.maxSpeed { vel[i] = vel[i] * (SkyTuning.maxSpeed / speed) }
            pos[i] = pos[i] + vel[i]
        }
        if dragIndex == nil {
            alpha *= SkyTuning.alphaDecay
            if alpha < SkyTuning.sleepAlpha { alpha = 0 }
        } else {
            alpha = max(alpha, SkyTuning.dragAlpha)
        }
    }

    // MARK: Dragging (the fidget toy)

    func beginDrag(_ i: Int) {
        guard graph.nodes.indices.contains(i), !graph.nodes[i].isRoot else { return }
        dragIndex = i
        dragTarget = pos[i]
        alpha = max(alpha, SkyTuning.dragAlpha)
    }

    func drag(to world: CGPoint) {
        guard dragIndex != nil else { return }
        dragTarget = world
    }

    func endDrag() { dragIndex = nil }
}

// MARK: - Vector helpers (world positions are CGPoints; the whole sky shares these)

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    static func * (l: CGPoint, r: CGFloat) -> CGPoint { CGPoint(x: l.x * r, y: l.y * r) }
    static func += (l: inout CGPoint, r: CGPoint) { l = l + r }
    static func -= (l: inout CGPoint, r: CGPoint) { l = l - r }
    var length: CGFloat { sqrt(x * x + y * y) }
}
