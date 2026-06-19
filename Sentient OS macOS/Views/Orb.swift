//
//  Orb.swift
//  Sentient OS macOS
//
//  The living orb — the brand's heartbeat and the literal center of the Constellation home
//  (Arch §9; design bar: UI_Inspiration/01 + README). The logo, made dimensional: a dark
//  glassy planet with the white dot glowing as a heart inside it, wrapped in a tilted ring of
//  orbiting light. The ring is truly 3D — depth-sorted across two Canvases sandwiching the
//  planet (it passes behind AND in front), Keplerian (inner particles orbit faster), with two
//  shimmer glints chasing around the band, the planet's shadow dimming the far side, and a
//  slow precession wobble. Modes: .idle (slow spin + 5.5s breathing) · .processing (fast,
//  bright) · .attention (quiet amber). `OrbMark` is the tiny static header glyph.
//
//  PERFORMANCE RULES (learned the 8-fps way — keep these true):
//   · No @State writes per frame — the ring phase is a pure function of wall time.
//   · No blur filters per frame: the halo is pre-rasterized (.drawingGroup) and only
//     ROTATED; nebula clouds + the heart are radial gradients, not blurred circles.
//   · One Canvas glow pass per side, not two.
//   · The planet's diameter is FIXED (vector-crisp); breathing lives in the heart's glow,
//     the halo, and the ring — never in a scaleEffect over the whole orb (bitmap fuzz).
//

import SwiftUI

enum OrbMode { case idle, processing, attention }

struct Orb: View {
    var mode: OrbMode = .idle
    var size: CGFloat = 132          // planet diameter; the frame is wider (the ring overflows it)

    var body: some View {
        ZStack {
            haloLayer
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let breath = (sin(t * 2 * .pi / 5.5) + 1) / 2     // 0…1, the 5.5s heartbeat
                ZStack {
                    ringCanvas(front: false, t: t, breath: breath)
                    planet(t: t, breath: breath)
                    ringCanvas(front: true, t: t, breath: breath)
                }
            }
        }
        .frame(width: size * 2.05, height: size * 1.5)
        .allowsHitTesting(false)
    }

    // MARK: Ambient halo — a cached texture, spun and breathed (never re-blurred)

    private var haloLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 2 * .pi / 5.5) + 1) / 2
            HaloTexture(size: size, mode: mode)
                .rotationEffect(.radians(t * 2 * .pi / 18))
                .scaleEffect(1 + 0.035 * breath)
                .opacity(mode == .processing ? 0.40 : 0.23 + 0.07 * breath)
        }
    }

    /// Stable inputs → SwiftUI never re-renders the (expensive) blur; the rasterized layer
    /// is then rotated/scaled by the compositor for free.
    private struct HaloTexture: View {
        let size: CGFloat
        let mode: OrbMode
        var body: some View {
            Circle()
                .fill(AngularGradient(colors: Orb.haloColors(for: mode), center: .center))
                .frame(width: size * 1.8, height: size * 1.8)
                .blur(radius: size * 0.30)
                // .drawingGroup() rasterizes at the view's RECTANGULAR bounds and clips the
                // blur's soft falloff — without this padding the glow is chopped into a hard
                // square that then visibly spins (haloLayer rotates the cached texture). Pad so
                // the whole blur tail fits inside the raster bounds; the margin is transparent,
                // so the halo stays a soft circle. (Disc reaches ~0.9·size, blur adds ~0.9·size.)
                .padding(size * 1.1)
                .drawingGroup()
        }
    }

    private static func haloColors(for mode: OrbMode) -> [Color] {
        if mode == .attention {
            return [Color(red: 0.55, green: 0.36, blue: 0.10), Color(red: 0.72, green: 0.48, blue: 0.16),
                    Color(red: 0.45, green: 0.26, blue: 0.08), Color(red: 0.55, green: 0.36, blue: 0.10)]
        }
        return ringStops.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
    }

    // MARK: The planet (fixed diameter — always vector-crisp)

    private func planet(t: Double, breath: Double) -> some View {
        ZStack {
            // The dark glassy sphere, lit from the upper left.
            Circle().fill(RadialGradient(
                colors: [Color(red: 0.20, green: 0.20, blue: 0.27), Color(red: 0.012, green: 0.012, blue: 0.025)],
                center: UnitPoint(x: 0.36, y: 0.30), startRadius: 0, endRadius: size * 0.85))

            nebula(t: t)
            grain

            // The white heart — the logo's dot, glowing through the glass (radial falloff
            // does the soft-edge work a blur used to do).
            Circle()
                .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: size * 0.31))
                .frame(width: size * 0.62, height: size * 0.62)
                .opacity(0.50 + 0.22 * breath)
            Circle()
                .fill(RadialGradient(
                    stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.72),
                            .init(color: .white.opacity(0), location: 1)],
                    center: .center, startRadius: 0, endRadius: size * 0.12))
                .frame(width: size * 0.24, height: size * 0.24)
                .opacity(0.90 + 0.10 * breath)

            // Limb darkening — the sphere falls away into shadow at its edges.
            Circle().fill(RadialGradient(
                stops: [.init(color: .clear, location: 0.55), .init(color: .black.opacity(0.62), location: 1.0)],
                center: UnitPoint(x: 0.40, y: 0.34), startRadius: 0, endRadius: size * 0.62))

            // Rim light along the lit edge.
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .frame(width: size, height: size)
    }

    /// Slow "weather" inside the sphere — four deep-color clouds drifting on different
    /// orbits. Radial-gradient blobs (soft by construction, no blur filter).
    private func nebula(t: Double) -> some View {
        let a = t * 2 * .pi / 60   // base drift: one lap per minute
        return ZStack {
            nebulaBlob(Color(red: 0.24, green: 0.22, blue: 0.50), w: 0.74, angle: a, orbit: 0.20)
            nebulaBlob(Color(red: 0.08, green: 0.34, blue: 0.37), w: 0.66, angle: a * 1.31 + 2.1, orbit: 0.24)
            nebulaBlob(Color(red: 0.40, green: 0.15, blue: 0.31), w: 0.60, angle: -a * 0.83 + 4.2, orbit: 0.22)
            nebulaBlob(Color(red: 0.10, green: 0.22, blue: 0.45), w: 0.54, angle: a * 1.72 + 1.0, orbit: 0.26)
        }
        .frame(width: size, height: size)
        .opacity(0.72)
        .mask(Circle())
    }

    private func nebulaBlob(_ c: Color, w: Double, angle: Double, orbit: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [c.opacity(0.85), c.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: size * w * 0.5))
            .frame(width: size * w, height: size * w)
            .offset(x: cos(angle) * size * orbit, y: sin(angle) * size * orbit * 0.7)
    }

    /// Fine mineral grain dusted over the glass — breaks gradient banding and gives the
    /// surface a texture to catch the eye.
    private var grain: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let R = size / 2 * 0.97
            for g in Self.grains {
                let s = g.s
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + g.x * R - s / 2, y: c.y + g.y * R - s / 2,
                                                width: s, height: s)),
                         with: .color(.white.opacity(g.a)))
            }
        }
        .frame(width: size, height: size)
        .blendMode(.plusLighter)
        .mask(Circle())
    }

    private static let grains: [(x: Double, y: Double, s: Double, a: Double)] = {
        var rng = SplitMix64(seed: 0xD175)
        return (0..<450).map { _ in
            let r = sqrt(Double.random(in: 0...1, using: &rng))   // sqrt → uniform over the disc
            let th = Double.random(in: 0..<(2 * .pi), using: &rng)
            return (r * cos(th), r * sin(th),
                    Double.random(in: 0.4...1.1, using: &rng),
                    Double.random(in: 0.02...0.09, using: &rng))
        }
    }()

    // MARK: The ring (the showpiece)

    /// The ring clock is a pure function of wall time — no per-frame state. (A mode change
    /// steps the pace; if a visible glide ever matters — e.g. the processing morph — bring
    /// back accumulation OUTSIDE the render loop.)
    private func ringPhase(_ t: Double) -> Double {
        t * (mode == .processing ? 3.4 : 1.0)
    }

    private func ringCanvas(front: Bool, t: Double, breath: Double) -> some View {
        Canvas { context, canvasSize in
            var ctx = context
            let frame = RingFrame(
                center: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                r: (size / 2) * (1 + 0.018 * breath),   // the ring carries the breath
                geo: Self.ringGeometry(t: t),
                phase: ringPhase(t),
                t: t,
                front: front,
                bright: mode == .processing ? 1.3 : 1.0,
                amber: mode == .attention ? 0.7 : 0.0)

            // ONE additive glow pass, then the crisp pass on top.
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.blendMode = .plusLighter
                Self.drawBand(&layer, frame, lineWidth: 3.4, gain: 0.8)
                Self.drawParticles(&layer, frame, minSize: 1.55, gain: 0.9)
            }
            Self.drawBand(&ctx, frame, lineWidth: 1.1, gain: 1.0)
            Self.drawParticles(&ctx, frame, minSize: 0, gain: 1.0)
        }
    }

    /// Everything one ring pass needs, bundled so the draw helpers stay tidy.
    private struct RingFrame {
        let center: CGPoint
        let r: CGFloat          // planet radius in points (ring radii are in planet-radius units)
        let geo: RingGeometry
        let phase: Double       // the ring clock
        let t: Double           // wall time (twinkles)
        let front: Bool         // which depth half this canvas draws
        let bright: Double
        let amber: Double
    }

    /// The ring plane's pose: a tilted circle, leaned slightly in-plane, both breathing on
    /// slow precession cycles so the ring never feels mechanical.
    private struct RingGeometry {
        let tilt: Double
        let leanSin: Double
        let leanCos: Double

        func project(radius: Double, angle: Double, r: CGFloat, center: CGPoint) -> (pos: CGPoint, depth: Double) {
            let x = cos(angle) * radius
            let depth = sin(angle)                 // +1 = nearest the viewer (front, lower half)
            let y = depth * tilt * radius
            let px = x * leanCos - y * leanSin
            let py = x * leanSin + y * leanCos
            return (CGPoint(x: center.x + CGFloat(px) * r, y: center.y + CGFloat(py) * r), depth)
        }
    }

    private static func ringGeometry(t: Double) -> RingGeometry {
        let tilt = 0.30 + 0.035 * sin(t * 2 * .pi / 23)
        let lean = (-9 + 2.5 * sin(t * 2 * .pi / 29)) * .pi / 180
        return RingGeometry(tilt: tilt, leanSin: sin(lean), leanCos: cos(lean))
    }

    /// The two gradient threads that define the band (inner band's heart + outer band's edge),
    /// drawn as short depth-shaded segments with shimmer glints chasing around them.
    private static func drawBand(_ ctx: inout GraphicsContext, _ f: RingFrame,
                                 lineWidth: CGFloat, gain: Double) {
        let seg = 84
        for (radius, radiusGain) in [(1.33, 1.0), (1.585, 0.62)] {
            for i in 0..<seg {
                let a0 = Double(i) / Double(seg) * 2 * .pi
                let a1 = Double(i + 1) / Double(seg) * 2 * .pi + 0.004   // hairline overlap, no seams
                let am = (a0 + a1) / 2
                let depth = sin(am)
                guard (depth >= 0) == f.front else { continue }

                let (p0, _) = f.geo.project(radius: radius, angle: a0, r: f.r, center: f.center)
                let (p1, _) = f.geo.project(radius: radius, angle: a1, r: f.r, center: f.center)

                let dn = (depth + 1) / 2
                var b = (0.30 + 0.55 * dn) * radiusGain * f.bright * gain
                if !f.front { b *= planetShadow(x: p0.x, center: f.center, r: f.r) }

                // Two glints orbiting in opposite directions — they meet, cross, and part.
                let boost = 1.7 * glint(am, at: f.phase * 0.50, width: 0.42)
                          + 1.0 * glint(am, at: -f.phase * 0.34 + .pi, width: 0.60)
                b *= 0.75 + boost

                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)
                ctx.stroke(path,
                           with: .color(ringColor(at: am / (2 * .pi), brightness: min(b, 1.55),
                                                  amber: f.amber, whiteMix: min(0.55, boost * 0.30))),
                           style: StrokeStyle(lineWidth: lineWidth * (0.8 + 0.4 * dn), lineCap: .round))
            }
        }
    }

    private static func drawParticles(_ ctx: inout GraphicsContext, _ f: RingFrame,
                                      minSize: Double, gain: Double) {
        for p in particles where p.size >= minSize {   // the glow pass only blooms the bigger motes
            let angle = p.angle0 + p.speed * f.phase
            let (pt, depth) = f.geo.project(radius: p.radius, angle: angle, r: f.r, center: f.center)
            guard (depth >= 0) == f.front else { continue }

            let dn = (depth + 1) / 2
            var b = (0.35 + 0.65 * dn) * gain * f.bright
            if !f.front { b *= planetShadow(x: pt.x, center: f.center, r: f.r) }
            b *= 0.62 + 0.38 * sin(f.t * p.twinkleSpeed + p.twinklePhase)

            let s = p.size * (0.85 + 0.35 * dn)
            let color = ringColor(at: angle / (2 * .pi), brightness: min(b * 1.15, 1.5),
                                  amber: f.amber, whiteMix: 0.12)
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)),
                     with: .color(color.opacity(min(b + 0.2, 1))))
        }
    }

    /// The planet's shadow falling on the far side of the ring — the cue that sells the 3D.
    private static func planetShadow(x: CGFloat, center: CGPoint, r: CGFloat) -> Double {
        Double(min(1, max(0.25, abs(x - center.x) / (r * 1.18))))
    }

    /// A soft bright packet centered at `packet`, by angular distance (wraps correctly).
    private static func glint(_ angle: Double, at packet: Double, width: Double) -> Double {
        let d = abs(atan2(sin(angle - packet), cos(angle - packet)))
        return exp(-d * d / (2 * width * width))
    }

    // MARK: Ring color — the sentient spectrum at deep-space brightness

    /// The color geography is anchored to ring angle, so the colors stay put while the matter
    /// flows through them — like light catching different bands of ice.
    private static let ringStops: [(loc: Double, r: Double, g: Double, b: Double)] = [
        (0.00, 0.76, 0.30, 0.36),   // ember
        (0.18, 0.80, 0.56, 0.27),   // burnished amber
        (0.40, 0.18, 0.58, 0.51),   // viridian
        (0.62, 0.30, 0.45, 0.85),   // cobalt
        (0.82, 0.56, 0.34, 0.67),   // orchid
        (1.00, 0.76, 0.30, 0.36),   // wrap → ember (smooth seam)
    ]

    private static func ringColor(at frac: Double, brightness: Double,
                                  amber: Double, whiteMix: Double) -> Color {
        let f = frac - floor(frac)
        var i = 0
        while i + 1 < ringStops.count - 1 && ringStops[i + 1].loc < f { i += 1 }
        let s0 = ringStops[i], s1 = ringStops[i + 1]
        let u = (f - s0.loc) / max(s1.loc - s0.loc, 1e-6)
        var r = s0.r + (s1.r - s0.r) * u
        var g = s0.g + (s1.g - s0.g) * u
        var b = s0.b + (s1.b - s0.b) * u
        if amber > 0 {   // attention: the spectrum settles into quiet amber
            r += (0.82 - r) * amber; g += (0.55 - g) * amber; b += (0.20 - b) * amber
        }
        r *= brightness; g *= brightness; b *= brightness
        if whiteMix > 0 {   // glints run hot — mix toward white
            r += (1 - min(r, 1)) * whiteMix; g += (1 - min(g, 1)) * whiteMix; b += (1 - min(b, 1)) * whiteMix
        }
        return Color(red: min(r, 1), green: min(g, 1), blue: min(b, 1))
    }

    // MARK: The ring's matter (seeded once, stable across renders)

    private struct Particle {
        let radius: Double        // in planet radii
        let angle0: Double
        let speed: Double         // rad per ring-clock second
        let size: Double
        let twinklePhase: Double
        let twinkleSpeed: Double
    }

    private static let particles: [Particle] = {
        var rng = SplitMix64(seed: 0x05EA_51E0)
        return (0..<230).map { i in
            // Two bands with a clean gap between them (the Cassini division).
            let inner = i % 9 < 5
            let radius = inner ? Double.random(in: 1.22...1.43, using: &rng)
                               : Double.random(in: 1.52...1.70, using: &rng)
            return Particle(
                radius: radius,
                angle0: .random(in: 0..<(2 * .pi), using: &rng),
                speed: 0.38 * pow(1.22 / radius, 1.5),   // Keplerian: inner orbits run faster
                size: .random(in: 0.7...2.1, using: &rng),
                twinklePhase: .random(in: 0..<(2 * .pi), using: &rng),
                twinkleSpeed: .random(in: 0.4...1.5, using: &rng))
        }
    }()
}

/// The tiny static orb glyph (header scale): the logo's ring + dot with a soft glow.
struct OrbMark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.92), lineWidth: max(1, size * 0.085))
            Circle().fill(.white).frame(width: size * 0.38, height: size * 0.38)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.69, green: 0.42, blue: 0.70).opacity(0.55), radius: size * 0.3)
    }
}

/// Tiny deterministic RNG so the ring's matter is identical every launch.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

#Preview("Orb — idle") {
    ZStack { Color.black.ignoresSafeArea(); Orb(size: 132) }
        .frame(width: 480, height: 320)
}

#Preview("Orb — processing") {
    ZStack { Color.black.ignoresSafeArea(); Orb(mode: .processing, size: 132) }
        .frame(width: 480, height: 320)
}

#Preview("Orb — attention") {
    ZStack { Color.black.ignoresSafeArea(); Orb(mode: .attention, size: 132) }
        .frame(width: 480, height: 320)
}
