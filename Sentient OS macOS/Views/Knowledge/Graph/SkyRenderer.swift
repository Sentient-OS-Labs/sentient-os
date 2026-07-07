//
//  SkyRenderer.swift
//  Sentient OS macOS
//
//  All Canvas drawing for the Night Sky, painter's order: parallax stardust → constellation
//  watermark labels → the center breath → threads (resting, then ignited) → photon pulses →
//  stars (halo/core/ring; the root sun wears the one rotating magic-gradient ring on screen) →
//  note titles (semantic zoom). Stateless: reads NightSkyModel each frame.
//
//  Performance rules inherited from Orb.swift: no per-frame blur filters — every glow here is a
//  layered radial gradient; resting threads batch into two stroked Paths.
//

import SwiftUI

struct SkyRenderer {

    /// Ten desaturated constellation hues (assigned biggest-domain-first, wrapping if needed).
    /// Kept as components so cores can be mixed toward white without Color introspection.
    private static let palette: [(r: Double, g: Double, b: Double)] = [
        (1.00, 0.80, 0.55),  // gold
        (0.45, 0.85, 0.78),  // teal
        (0.72, 0.62, 1.00),  // violet
        (1.00, 0.62, 0.70),  // rose
        (0.55, 0.75, 1.00),  // sky
        (0.68, 0.88, 0.62),  // sage
        (1.00, 0.72, 0.55),  // peach
        (0.60, 0.62, 0.98),  // indigo
        (0.55, 0.92, 0.80),  // mint
        (0.82, 0.70, 0.98),  // lavender
    ]
    private static let dawn = (r: 0.333, g: 0.757, b: 0.941)   // Theme.dawnCyan's components

    static func domainColor(_ d: Int, alpha: Double = 1) -> Color {
        guard d >= 0 else { return Color(red: 1, green: 0.93, blue: 0.85, opacity: alpha) }   // the sun: warm white
        let c = palette[d % palette.count]
        return Color(red: c.r, green: c.g, blue: c.b, opacity: alpha)
    }

    /// A star's core: mostly white, kissed by its constellation hue.
    private static func coreColor(_ d: Int, alpha: Double) -> Color {
        guard d >= 0 else { return Color(red: 1, green: 0.96, blue: 0.9, opacity: alpha) }
        let c = palette[d % palette.count]
        return Color(red: 0.78 + 0.22 * c.r, green: 0.78 + 0.22 * c.g, blue: 0.78 + 0.22 * c.b, opacity: alpha)
    }

    // MARK: The frame

    static func draw(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel, t: TimeInterval) {
        guard let graph = model.graph, let sim = model.sim else { return }
        let cam = model.camera
        let zf = CGFloat(pow(Double(cam.zoom), 0.62))          // star sizes scale sub-linearly

        // Assembly reveal: stars ignite as they fly in; threads fade in last, once things settle.
        let heat = sim.alpha
        let starReveal = min(1, (1 - heat) * 3 + 0.15)
        let threadReveal = max(0, min(1, (0.55 - heat) / 0.45))

        let focusSet: Set<Int> = {
            guard let f = model.focusIndex else { return [] }
            return model.focusNeighbors.union([f])
        }()

        drawDust(ctx, size: size, model: model, t: t)
        drawConstellationLabels(ctx, size: size, model: model, graph: graph, sim: sim,
                                reveal: threadReveal, dim: 1 - 0.5 * model.focusBlend)
        drawBreath(ctx, size: size, model: model, t: t, reveal: threadReveal)
        drawThreads(ctx, size: size, model: model, graph: graph, sim: sim,
                    reveal: threadReveal, focusSet: focusSet, zf: zf)
        drawPulses(ctx, size: size, model: model, graph: graph, sim: sim, t: t, reveal: threadReveal)
        drawSunOcclusion(ctx, size: size, model: model, graph: graph, sim: sim, zf: zf)
        drawStars(ctx, size: size, model: model, graph: graph, sim: sim, t: t, zf: zf,
                  starReveal: starReveal, focusSet: focusSet)
        drawTitles(ctx, size: size, model: model, graph: graph, sim: sim, zf: zf,
                   reveal: starReveal, focusSet: focusSet)
    }

    /// How far (screen px) threads must keep clear of the sun's center — just past the
    /// SpinningLogo's ring + bloom, so nothing ever crosses the mark's face.
    private static func sunClearance(_ zf: CGFloat) -> CGFloat { 22 * zf }

    /// Move `p` toward `q` by `d` screen px (stops root-incident threads at the sun's rim).
    private static func pulledIn(_ p: CGPoint, toward q: CGPoint, by d: CGFloat) -> CGPoint {
        let dx = q.x - p.x, dy = q.y - p.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > d else { return q }
        return CGPoint(x: p.x + dx / len * d, y: p.y + dy / len * d)
    }

    /// A soft black disc under the SpinningLogo: threads merely PASSING the center (they belong
    /// to other stars, so they can't be trimmed) fade out under the logo instead of showing
    /// through its transparent gaps.
    private static func drawSunOcclusion(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                         graph: SkyGraph, sim: SkySimulation, zf: CGFloat) {
        guard let root = graph.rootIndex else { return }
        let p = model.toScreen(sim.pos[root], size: size)
        let r = sunClearance(zf)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(stops: [.init(color: .black, location: 0),
                                                        .init(color: .black, location: 0.72),
                                                        .init(color: .black.opacity(0), location: 1)]),
                                       center: p, startRadius: 0, endRadius: r))
    }

    // MARK: Stardust (two parallax depth layers, drifting, faintly twinkling)

    struct Speck {
        let base: CGPoint          // in a unit tile
        let size: CGFloat
        let alpha: Double
        let parallax: CGFloat
        let drift: CGPoint         // px per second
        let phase: Double
    }

    static func makeDust() -> [Speck] {
        var rng = SplitMix64(seed: 0xD057)
        func layer(count: Int, parallax: CGFloat, sizes: ClosedRange<CGFloat>, alpha: ClosedRange<Double>) -> [Speck] {
            (0..<count).map { _ in
                Speck(base: CGPoint(x: CGFloat.random(in: 0...1, using: &rng),
                                    y: CGFloat.random(in: 0...1, using: &rng)),
                      size: CGFloat.random(in: sizes, using: &rng),
                      alpha: Double.random(in: alpha, using: &rng),
                      parallax: parallax,
                      drift: CGPoint(x: CGFloat.random(in: -2.2...2.2, using: &rng),
                                     y: CGFloat.random(in: -1.6...1.6, using: &rng)),
                      phase: Double.random(in: 0...6.28, using: &rng))
            }
        }
        return layer(count: 150, parallax: 0.22, sizes: 0.7...1.4, alpha: 0.03...0.07)
             + layer(count: 90, parallax: 0.45, sizes: 1.1...2.1, alpha: 0.05...0.10)
    }

    private static func drawDust(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel, t: TimeInterval) {
        let margin: CGFloat = 80
        let tileW = size.width + margin * 2
        let tileH = size.height + margin * 2
        guard tileW > 0, tileH > 0 else { return }
        for s in model.dust {
            var x = (s.base.x * tileW + s.drift.x * t + model.camera.pan.x * s.parallax)
                .truncatingRemainder(dividingBy: tileW)
            var y = (s.base.y * tileH + s.drift.y * t + model.camera.pan.y * s.parallax)
                .truncatingRemainder(dividingBy: tileH)
            if x < 0 { x += tileW }
            if y < 0 { y += tileH }
            let a = s.alpha * (0.75 + 0.25 * sin(t * 0.7 + s.phase))
            ctx.fill(Path(ellipseIn: CGRect(x: x - margin, y: y - margin, width: s.size, height: s.size)),
                     with: .color(.white.opacity(a)))
        }
    }

    // MARK: The center breath (a barely-there luminance wave every ~11s — the heartbeat)

    private static func drawBreath(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                   t: TimeInterval, reveal: Double) {
        guard reveal > 0.3 else { return }
        let period = 11.0
        let phase = t.truncatingRemainder(dividingBy: period) / period
        guard phase < 0.5 else { return }
        let p = phase / 0.5
        let ease = 1 - pow(1 - p, 2)
        let center = model.toScreen(.zero, size: size)
        let r = (40 + 560 * ease) * model.camera.zoom
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(0.030 * (1 - p) * reveal), .clear]),
                                       center: center, startRadius: 0, endRadius: r))
    }

    // MARK: Threads

    private static func drawThreads(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                    graph: SkyGraph, sim: SkySimulation,
                                    reveal: Double, focusSet: Set<Int>, zf: CGFloat) {
        guard reveal > 0.01 else { return }
        let dim = 1 - 0.55 * model.focusBlend
        let root = graph.rootIndex
        let clear = sunClearance(zf)

        /// Endpoints with the root's end pulled back to the sun's rim (never through the logo).
        func endpoints(_ e: SkyEdge) -> (CGPoint, CGPoint)? {
            var a = model.toScreen(sim.pos[e.a], size: size)
            var b = model.toScreen(sim.pos[e.b], size: size)
            if e.a == root { a = pulledIn(a, toward: b, by: clear) }
            if e.b == root { b = pulledIn(b, toward: a, by: clear) }
            return (b - a).length > 2 ? (a, b) : nil
        }

        // Resting threads batch into two paths (one stroke call each).
        var same = Path()
        var cross = Path()
        for e in graph.edges {
            guard let (a, b) = endpoints(e) else { continue }
            if e.sameDomain { same.move(to: a); same.addLine(to: b) }
            else { cross.move(to: a); cross.addLine(to: b) }
        }
        ctx.stroke(same, with: .color(.white.opacity(0.075 * reveal * dim)), lineWidth: 0.8)
        ctx.stroke(cross, with: .color(.white.opacity(0.05 * reveal * dim)), lineWidth: 0.8)

        // Ignited threads: the focused star's edges light up as domain→domain gradients.
        func ignite(_ center: Int, intensity: Double) {
            guard intensity > 0.02 else { return }
            for e in graph.edges where e.a == center || e.b == center {
                guard let (pa, pb) = endpoints(e) else { continue }
                var p = Path()
                p.move(to: pa)
                p.addLine(to: pb)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [domainColor(graph.nodes[e.a].domain, alpha: 0.9 * intensity),
                                      domainColor(graph.nodes[e.b].domain, alpha: 0.9 * intensity)]),
                    startPoint: pa, endPoint: pb)
                var wide = ctx
                wide.opacity = 0.28 * intensity
                wide.stroke(p, with: shading, lineWidth: 4.5)
                ctx.stroke(p, with: shading, lineWidth: 1.3)
            }
        }
        if let f = model.focusIndex { ignite(f, intensity: model.focusBlend * reveal) }
        if let h = model.highlightIndex, h != model.focusIndex,
           model.glow.indices.contains(h) {
            ignite(h, intensity: model.glow[h] * 0.7 * reveal)
        }
    }

    // MARK: Photon pulses (one synapse firing at a time)

    private static func drawPulses(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                   graph: SkyGraph, sim: SkySimulation, t: TimeInterval, reveal: Double) {
        for pulse in model.pulses {
            guard graph.edges.indices.contains(pulse.edge) else { continue }
            let e = graph.edges[pulse.edge]
            let progress = max(0, min(1, (t - pulse.start) / pulse.duration))
            let envelope = sin(.pi * progress) * reveal
            guard envelope > 0.01 else { continue }
            let a = model.toScreen(sim.pos[e.a], size: size)
            let b = model.toScreen(sim.pos[e.b], size: size)
            let head = CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
            let tailP = max(0, progress - 0.13)
            let tail = CGPoint(x: a.x + (b.x - a.x) * tailP, y: a.y + (b.y - a.y) * tailP)
            var trail = Path()
            trail.move(to: tail)
            trail.addLine(to: head)
            ctx.stroke(trail,
                       with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.55 * envelope)]),
                                             startPoint: tail, endPoint: head),
                       lineWidth: 1.2)
            let r = 4.5 * max(model.camera.zoom, 0.6)
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [.white.opacity(0.9 * envelope), .clear]),
                                           center: head, startRadius: 0, endRadius: r))
        }
    }

    // MARK: Stars

    static func starRadius(_ n: SkyNode, maxDegree: Int, zf: CGFloat) -> CGFloat {
        let degN = sqrt(Double(n.degree) / Double(max(maxDegree, 1)))
        let world: CGFloat = n.isRoot ? 9 : (2.3 + 3.3 * CGFloat(degN))
        return world * zf
    }

    private static func drawStars(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                  graph: SkyGraph, sim: SkySimulation, t: TimeInterval, zf: CGFloat,
                                  starReveal: Double, focusSet: Set<Int>) {
        let margin: CGFloat = 80
        for (i, n) in graph.nodes.enumerated() {
            let p = model.toScreen(sim.pos[i], size: size)
            guard p.x > -margin, p.x < size.width + margin, p.y > -margin, p.y < size.height + margin
            else { continue }

            let g = model.glow.indices.contains(i) ? model.glow[i] : 0
            let dim = (focusSet.isEmpty || focusSet.contains(i)) ? 1.0 : 1.0 - 0.62 * model.focusBlend
            let twinkle = 0.86 + 0.14 * sin(t * n.twinkleSpeed + n.twinklePhase)
            let bright = twinkle * dim * starReveal
            let r = starRadius(n, maxDegree: graph.maxDegree, zf: zf)

            if n.isRoot {
                drawSunBed(ctx, at: p, r: r, bright: bright * (1 + 0.6 * g))
                continue
            }

            let degN = sqrt(Double(n.degree) / Double(max(graph.maxDegree, 1)))

            // Halo (constellation hue), blooming when ignited.
            let haloR = r * 3.6 * (1 + 0.8 * g)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - haloR, y: p.y - haloR, width: haloR * 2, height: haloR * 2)),
                     with: .radialGradient(
                        Gradient(colors: [domainColor(n.domain, alpha: (0.16 + 0.10 * degN) * bright * (1 + 1.7 * g)),
                                          .clear]),
                        center: p, startRadius: 0, endRadius: haloR))

            // "Changed last night" — a slow dawn-cyan breath around the star.
            if n.recentlyChanged {
                let aR = r * 5
                let aA = (0.10 + 0.07 * sin(t * 1.5 + n.twinklePhase)) * dim * starReveal
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - aR, y: p.y - aR, width: aR * 2, height: aR * 2)),
                         with: .radialGradient(
                            Gradient(colors: [Color(red: dawn.r, green: dawn.g, blue: dawn.b, opacity: aA), .clear]),
                            center: p, startRadius: 0, endRadius: aR))
            }

            // Core.
            let coreR = r * (1 + 0.30 * g)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - coreR, y: p.y - coreR, width: coreR * 2, height: coreR * 2)),
                     with: .color(coreColor(n.domain, alpha: min(1, 0.10 + 0.9 * bright + 0.25 * g))))

            // Ignite ring.
            if g > 0.02 {
                let ringR = r * 2.15 + 1.5
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - ringR, y: p.y - ringR, width: ringR * 2, height: ringR * 2)),
                           with: .color(domainColor(n.domain, alpha: 0.55 * g)),
                           lineWidth: 1)
            }
        }
    }

    /// The root README's light bed — a soft warm halo under the sun. The sun itself is the REAL
    /// brand mark: NightSkyView floats a slow SpinningLogo (the notch spinner) over the canvas at
    /// this exact spot, so the center of your life wears the actual logo.
    private static func drawSunBed(_ ctx: GraphicsContext, at p: CGPoint, r: CGFloat, bright: Double) {
        let halo = r * 7
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(0.10 * bright), .clear]),
                                       center: p, startRadius: 0, endRadius: halo))
    }

    // MARK: Labels

    /// Constellation names as star-atlas watermarks under the graph (fade out as you zoom in).
    private static func drawConstellationLabels(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                                graph: SkyGraph, sim: SkySimulation,
                                                reveal: Double, dim: Double) {
        let zoom = model.camera.zoom
        let labelA = max(0, min(1, (1.9 - Double(zoom)) / 0.9)) * reveal * dim
        guard labelA > 0.02, !graph.domains.isEmpty else { return }

        var sums = [CGPoint](repeating: .zero, count: graph.domains.count)
        var counts = [Int](repeating: 0, count: graph.domains.count)
        for (i, n) in graph.nodes.enumerated() where n.domain >= 0 {
            sums[n.domain] += sim.pos[i]
            counts[n.domain] += 1
        }
        for (d, name) in graph.domains.enumerated() where counts[d] > 0 {
            let centroid = model.toScreen(sums[d] * (1 / CGFloat(counts[d])), size: size)
            var txt = ctx.resolve(Text(name.uppercased())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(3.5))
            txt.shading = .color(.white.opacity(0.20 * labelA))
            ctx.draw(txt, at: centroid, anchor: .center)
        }
    }

    /// Note titles under their stars — zoom-gated at rest (conservative: the resting sky stays
    /// clean), but on hover the whole ignited neighborhood becomes candidates. Placement is
    /// COLLISION-AWARE (map-app style): labels are placed greedily by priority (hovered star →
    /// highlight → busiest neighbors) and any label whose measured rect would overlap an already
    /// placed one — or the hover card — simply isn't drawn. As many names as fit, zero clutter.
    private static func drawTitles(_ ctx: GraphicsContext, size: CGSize, model: NightSkyModel,
                                   graph: SkyGraph, sim: SkySimulation, zf: CGFloat,
                                   reveal: Double, focusSet: Set<Int>) {
        let zoom = Double(model.camera.zoom)
        guard zoom > 1.0 || model.focusIndex != nil || model.highlightIndex != nil else { return }
        let margin: CGFloat = 40

        struct Candidate {
            let i: Int
            let anchor: CGPoint
            let alpha: Double
            let priority: Double     // static per hover session, so placement never flickers
        }
        var candidates: [Candidate] = []
        for (i, n) in graph.nodes.enumerated() {
            let degN = sqrt(Double(n.degree) / Double(max(graph.maxDegree, 1)))
            let threshold = n.isRoot ? 1.2 : 2.0 - 0.55 * degN
            let g = model.glow.indices.contains(i) ? model.glow[i] : 0
            var a = max(0, min(1, (zoom - threshold) / 0.4))
            if i == model.focusIndex || i == model.highlightIndex || focusSet.contains(i) {
                a = max(a, g * 0.92)                       // the ignited neighborhood gets named too
            }
            if !focusSet.isEmpty && !focusSet.contains(i) { a *= 1 - 0.62 * model.focusBlend }
            guard a > 0.03 else { continue }
            let p = model.toScreen(sim.pos[i], size: size)
            guard p.x > -margin, p.x < size.width + margin, p.y > -margin, p.y < size.height + margin
            else { continue }
            // The root's label clears the SpinningLogo's ring, not just its (smaller) hit radius.
            let r = n.isRoot ? sunClearance(zf) : starRadius(n, maxDegree: graph.maxDegree, zf: zf)
            let priority: Double = i == model.focusIndex ? 3 : (i == model.highlightIndex ? 2 : degN)
            candidates.append(Candidate(i: i, anchor: CGPoint(x: p.x, y: p.y + r + 12),
                                        alpha: a, priority: priority))
        }

        candidates.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.i < $1.i }
        var placed: [CGRect] = []
        if let card = model.hoverCardRect(in: size) { placed.append(card) }
        for c in candidates {
            var txt = ctx.resolve(Text(graph.nodes[c.i].title).font(.system(size: 10.5, design: .serif)))
            txt.shading = .color(.white.opacity(0.62 * c.alpha * reveal))
            let sz = txt.measure(in: CGSize(width: 360, height: 60))
            let rect = CGRect(x: c.anchor.x - sz.width / 2, y: c.anchor.y - sz.height / 2,
                              width: sz.width, height: sz.height).insetBy(dx: -6, dy: -3)
            guard !placed.contains(where: { $0.intersects(rect) }) else { continue }
            placed.append(rect)
            ctx.draw(txt, at: c.anchor, anchor: .center)
        }
    }
}
