//
//  CaretSwirl.swift
//  Sentient OS macOS
//
//  Double Tap's light. The instant the second tap lands, three rainbow comets appear in a wide
//  ring around the user's text cursor and spiral inward, spinning faster as the ring tightens,
//  then orbit close and breathe while the reply is drafted (the gather). When the reply arrives
//  the ring dives into the caret and blooms outward exactly as the text lands (the landing); when
//  there is nothing to paste it loosens and fades (the dissolve). Sparks trail the comets and
//  burst with the bloom.
//
//  It lives in its own click-through, non-activating panel above everything, and it never takes
//  key (the ⌘V must land in the user's own box). It stays visible to screen capture on purpose,
//  so recordings and demos carry the light; the tap's own screenshot carries the ring too, since
//  the ring is up before the shot fires. Everything drawn is a pure function of time in
//  ONE Canvas: no per-frame state, no blur filters (the glow is stacked strokes), so it holds a
//  full frame rate on the smallest Mac. The phase changes are continuous: a landing or a dissolve
//  starts from the exact radius, angle, and speed the ring had at that moment.
//
//  Key methods: begin(at:) · land() · dissolve() · landingDelay.
//  Doc: Documentation - Double Tap.md (this folder).
//

import SwiftUI
import AppKit

@MainActor
final class CaretSwirl {
    /// How long after `land()` the paste should fire, so the text appears on the bloom.
    static let landingDelay: Duration = .milliseconds(170)

    private let model = SwirlModel()
    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?

    /// Re-asserted on every reveal: macOS drops `.canJoinAllSpaces` when a window is re-ordered.
    private static let collectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    /// Show the ring, wide, centred on the caret, and start the gather.
    func begin(at target: CaretLocator.Target) {
        closeTask?.cancel(); closeTask = nil
        model.begin(orbit: max(15, Double(target.height) * 0.95))
        let side = SwirlMath.canvasSide
        let frame = NSRect(x: target.point.x - side / 2, y: target.point.y - side / 2, width: side, height: side)
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: false)
        panel.collectionBehavior = Self.collectionBehavior
        panel.orderFrontRegardless()
    }

    /// The reply is here: dive into the caret and bloom. Ignored unless the ring is gathering.
    func land() {
        guard case .gathering = model.phase else { return }
        model.transition(landing: true)
        scheduleClose(after: SwirlMath.landDuration)
    }

    /// Nothing to paste: loosen and fade. Ignored unless the ring is gathering.
    func dissolve() {
        guard case .gathering = model.phase else { return }
        model.transition(landing: false)
        scheduleClose(after: SwirlMath.dissolveDuration)
    }

    private func scheduleClose(after seconds: Double) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
            self.model.phase = .idle
        }
    }

    private func makePanel() -> NSPanel {
        let side = SwirlMath.canvasSide
        let panel = SwirlPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = .screenSaver
        panel.collectionBehavior = Self.collectionBehavior
        let host = NSHostingView(rootView: CaretSwirlView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

/// Never key, never main: the user's own field keeps keyboard focus for the paste.
private final class SwirlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The model (what phase the ring is in; the view derives every frame from time)

@MainActor @Observable
final class SwirlModel {
    enum Phase {
        case idle
        case gathering
        case landing(since: Date, from: SwirlMath.State)
        case dissolving(since: Date, from: SwirlMath.State)
    }

    var phase: Phase = .idle
    private(set) var began = Date()
    private(set) var orbit = 18.0

    func begin(orbit: Double) {
        self.orbit = orbit
        began = Date()
        phase = .gathering
    }

    /// Leave the gather from exactly where the ring is now, so the motion never jumps.
    func transition(landing: Bool) {
        let now = Date()
        let from = SwirlMath.gather(t: now.timeIntervalSince(began), orbit: orbit)
        phase = landing ? .landing(since: now, from: from) : .dissolving(since: now, from: from)
    }
}

// MARK: - The view

struct CaretSwirlView: View {
    let model: SwirlModel

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { graphics, size in
                guard let frame = SwirlMath.frame(phase: model.phase, began: model.began,
                                                  orbit: model.orbit, at: context.date) else { return }
                SwirlPainter.draw(frame, in: &graphics, size: size)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The math (pure functions of time)

enum SwirlMath {
    /// The panel is a square of this side, centred on the caret; wide enough for the widest ring
    /// plus its sparks and the landing ripple.
    static let canvasSide: CGFloat = 560
    static let startRadius = 168.0
    static let landDuration = 0.68
    static let dissolveDuration = 0.62

    /// The base ring at an instant: every comet and spark is derived from these three numbers.
    struct State {
        var radius: Double      // points from the caret
        var angle: Double       // radians, clockwise on screen
        var omega: Double       // revolutions per second
        var tighten: Double     // 0 (just appeared, wide) → 1 (orbiting close)
    }

    struct Frame {
        struct Comet { var radius, head, tail, width, opacity: Double }
        struct Spark { var x, y, size, opacity, angle: Double }
        var comets: [Comet]
        var sparks: [Spark]
        var core: Double                                   // the caret's own glow, 0…1
        var hueShift: Double                               // radians; the colour wheel drifts with the motion
        var bloom: (radius: Double, opacity: Double)?      // the landing flash
        var ripple: (radius: Double, width: Double, opacity: Double)?
    }

    // The gather: radius eases from wide to the orbit (exponential, so it hovers rather than
    // stops), angular speed eases up the other way; the angle is the closed-form integral so a
    // transition can read the exact state at any instant.
    private static let omega0 = 0.85, omegaMax = 3.4, kRadius = 2.3, kSpeed = 1.6
    private static let cometRadius = [1.0, 0.84, 1.14]
    private static let cometSpeed = [1.0, 1.11, 0.93]
    private static let sparkCount = 14

    static func gather(t: Double, orbit: Double) -> State {
        let e = exp(-kRadius * t)
        let tighten = 1 - e
        let radius = orbit + (startRadius - orbit) * e + 2.2 * tighten * sin(2 * .pi * 1.7 * t)
        let es = exp(-kSpeed * t)
        let omega = omegaMax - (omegaMax - omega0) * es
        let angle = 2 * .pi * (omegaMax * t - (omegaMax - omega0) / kSpeed * (1 - es))
        return State(radius: radius, angle: angle, omega: omega, tighten: tighten)
    }

    static func frame(phase: SwirlModel.Phase, began: Date, orbit: Double, at now: Date) -> Frame? {
        let t = now.timeIntervalSince(began)
        switch phase {
        case .idle:
            return nil

        case .gathering:
            let base = gather(t: t, orbit: orbit)
            let intro = min(t / 0.12, 1)
            return Frame(comets: comets(base, opacity: intro),
                         sparks: sparks(base, t: t, radiusScale: 1, opacity: min(t / 0.25, 1)),
                         core: base.tighten * base.tighten * (0.85 + 0.15 * sin(2 * .pi * 1.7 * t)),
                         hueShift: base.angle * 0.3, bloom: nil, ripple: nil)

        case .landing(let since, let from):
            let u = now.timeIntervalSince(since)
            let p = min(u / 0.24, 1)                                   // the dive
            let dive = pow(p, 2.2)
            let base = State(radius: from.radius * (1 - dive),
                             angle: from.angle + 2 * .pi * from.omega * (u + 1.5 * u * u / 0.24),
                             omega: from.omega * (1 + 3 * p), tighten: 1)
            let bloomAt = 0.16
            let q = max(0, min((u - bloomAt) / 0.42, 1))               // the bloom
            let out = 1 - pow(1 - q, 3)
            let cometOpacity = p < 0.7 ? 1 : max(0, 1 - (p - 0.7) / 0.3)
            let core = u < bloomAt ? from.tighten + (1 - from.tighten) * p : max(0, 1 - q * 1.2)
            let sparkOpacity = u < bloomAt ? 1 : 1 - q
            let sparkScale = u < bloomAt ? 1 - pow(p, 1.8) : 0
            var frame = Frame(comets: comets(base, opacity: cometOpacity),
                              sparks: sparks(base, t: t, radiusScale: sparkScale, opacity: sparkOpacity),
                              core: core, hueShift: base.angle * 0.3, bloom: nil, ripple: nil)
            if u >= bloomAt {
                frame.bloom = (radius: 6 + 84 * out, opacity: 0.9 * pow(1 - q, 1.6))
                frame.ripple = (radius: 4 + 110 * out, width: 0.5 + 2.4 * (1 - q), opacity: 0.75 * (1 - q))
                // Stardust: the sparks burst outward from the caret along their own angles.
                frame.sparks = burst(from: from, t: t, out: out, opacity: 1 - q)
            }
            return frame

        case .dissolving(let since, let from):
            let v = now.timeIntervalSince(since)
            let p = min(v / dissolveDuration, 1)
            let out = 1 - pow(1 - p, 3)
            let base = State(radius: from.radius * (1 + 0.35 * out),
                             angle: from.angle + 2 * .pi * from.omega * (v - v * v / (2 * dissolveDuration)),
                             omega: from.omega * (1 - p), tighten: from.tighten)
            let fade = pow(1 - p, 1.3)
            return Frame(comets: comets(base, opacity: fade),
                         sparks: sparks(base, t: t, radiusScale: 1 + 0.5 * out, opacity: fade),
                         core: from.tighten * (1 - p), hueShift: base.angle * 0.3, bloom: nil, ripple: nil)
        }
    }

    private static func comets(_ base: State, opacity: Double) -> [Frame.Comet] {
        (0..<3).map { i in
            let radius = base.radius * cometRadius[i]
            let speed = min(base.omega / omegaMax, 1.6)
            return Frame.Comet(radius: radius,
                               head: base.angle * cometSpeed[i] + Double(i) * 2 * .pi / 3,
                               tail: min(0.9 + 1.7 * speed, 2.9),
                               width: 2.4 + 3.0 * min(radius / startRadius, 1),
                               opacity: opacity)
        }
    }

    // Deterministic per-spark character (golden-angle spacing, so they never bunch).
    private static func sparkSeed(_ j: Int) -> (angle: Double, orbit: Double, speed: Double, size: Double, twinkle: Double) {
        func frac(_ x: Double) -> Double { x - floor(x) }
        let d = Double(j)
        return (angle: d * 2 * .pi * 0.618, orbit: 1.06 + 0.42 * frac(d * 0.37),
                speed: 0.7 + 0.6 * frac(d * 0.53), size: 1.3 + 1.6 * frac(d * 0.71), twinkle: d * 1.3)
    }

    private static func sparks(_ base: State, t: Double, radiusScale: Double, opacity: Double) -> [Frame.Spark] {
        (0..<sparkCount).map { j in
            let s = sparkSeed(j)
            let angle = base.angle * s.speed + s.angle
            let r = base.radius * s.orbit * radiusScale
            let twinkle = 0.5 + 0.5 * sin(2 * .pi * 2.1 * t + s.twinkle)
            return Frame.Spark(x: r * cos(angle), y: r * sin(angle), size: s.size,
                               opacity: opacity * (0.35 + 0.55 * twinkle), angle: angle)
        }
    }

    private static func burst(from: State, t: Double, out: Double, opacity: Double) -> [Frame.Spark] {
        (0..<sparkCount).map { j in
            let s = sparkSeed(j)
            let angle = from.angle * s.speed + s.angle + 0.6 * out
            let r = 4 + (34 + 60 * (s.orbit - 1)) * out * 2.2
            return Frame.Spark(x: r * cos(angle), y: r * sin(angle), size: s.size * (1 - 0.5 * out),
                               opacity: opacity * 0.9, angle: angle)
        }
    }
}

// MARK: - The painter (one Canvas pass, no filters)

enum SwirlPainter {
    /// The wheel IS the logo: twelve samples of the app icon's glow, read clockwise from
    /// 12 o'clock just outside its white ring (sampled from the icon file, 2026-09-21), wrapped so
    /// the ring has no seam. Drawn with normal blending, never additive, so the same colours show
    /// on a white compose box and on black.
    private static let wheel: [(r: Double, g: Double, b: Double)] = [
        (0.99, 0.59, 0.27),   // orange (top)
        (0.99, 0.38, 0.41),   // coral
        (0.95, 0.34, 0.63),   // pink
        (0.86, 0.39, 0.84),   // magenta (right)
        (0.71, 0.40, 0.91),   // violet
        (0.55, 0.42, 0.93),   // indigo
        (0.34, 0.49, 0.97),   // blue (bottom)
        (0.35, 0.63, 0.93),   // sky
        (0.49, 0.77, 0.89),   // cyan
        (0.71, 0.82, 0.74),   // sage (left)
        (0.89, 0.80, 0.48),   // gold
        (0.97, 0.72, 0.30),   // amber
        (0.99, 0.59, 0.27),   // wrap → orange (smooth seam)
    ]

    /// Colour at an angle on the wheel, optionally lifted toward white (comet heads, sparks).
    private static func hue(_ angle: Double, white: Double = 0) -> Color {
        let f = angle / (2 * .pi)
        let pos = (f - floor(f)) * Double(wheel.count - 1)
        let i = min(Int(pos), wheel.count - 2)
        let k = pos - Double(i)
        let a = wheel[i], b = wheel[i + 1]
        let r = a.r + (b.r - a.r) * k, g = a.g + (b.g - a.g) * k, bl = a.b + (b.b - a.b) * k
        return Color(red: r + (1 - r) * white, green: g + (1 - g) * white, blue: bl + (1 - bl) * white)
    }

    static func draw(_ frame: SwirlMath.Frame, in g: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)

        // The caret's own glow: a soft tinted halo that rises as the ring settles.
        if frame.core > 0.01 {
            let radius = 30.0
            let tint = frame.hueShift + .pi
            let gradient = Gradient(colors: [hue(tint, white: 0.3).opacity(0.55 * frame.core),
                                             hue(tint).opacity(0.28 * frame.core), .clear])
            g.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                   with: .radialGradient(gradient, center: c, startRadius: 0, endRadius: radius))
        }

        for comet in frame.comets where comet.opacity > 0.01 {
            drawComet(comet, hueShift: frame.hueShift, center: c, in: &g)
        }

        for spark in frame.sparks where spark.opacity > 0.01 {
            let p = CGPoint(x: c.x + spark.x, y: c.y + spark.y)
            let color = hue(spark.angle - frame.hueShift, white: 0.3)
            g.fill(Path(ellipseIn: CGRect(x: p.x - spark.size * 2.2, y: p.y - spark.size * 2.2,
                                          width: spark.size * 4.4, height: spark.size * 4.4)),
                   with: .color(color.opacity(spark.opacity * 0.3)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - spark.size / 2, y: p.y - spark.size / 2,
                                          width: spark.size, height: spark.size)),
                   with: .color(color.opacity(spark.opacity)))
        }

        if let bloom = frame.bloom, bloom.opacity > 0.01 {
            let gradient = Gradient(colors: [hue(frame.hueShift + 1.0, white: 0.45).opacity(bloom.opacity * 0.85),
                                             hue(frame.hueShift + 1.0).opacity(bloom.opacity * 0.5),
                                             hue(frame.hueShift + 3.5).opacity(bloom.opacity * 0.2), .clear])
            g.fill(Path(ellipseIn: CGRect(x: c.x - bloom.radius, y: c.y - bloom.radius,
                                          width: bloom.radius * 2, height: bloom.radius * 2)),
                   with: .radialGradient(gradient, center: c, startRadius: 0, endRadius: bloom.radius))
        }

        if let ripple = frame.ripple, ripple.opacity > 0.01 {
            let ring = Path(ellipseIn: CGRect(x: c.x - ripple.radius, y: c.y - ripple.radius,
                                              width: ripple.radius * 2, height: ripple.radius * 2))
            let stops = (0...6).map { i in
                Gradient.Stop(color: hue(Double(i) / 6 * 2 * .pi).opacity(ripple.opacity), location: Double(i) / 6)
            }
            g.stroke(ring, with: .conicGradient(Gradient(stops: stops), center: c, angle: .radians(frame.hueShift)),
                     lineWidth: ripple.width)
        }
    }

    /// A comet is an arc from tail to head, stroked three times (wide and faint, then narrower and
    /// brighter) with a conic gradient that fades in along the tail and carries the wheel's hue
    /// by angle; the head is a small dot lifted a little toward white, like the logo's glow near
    /// its ring (never white-hot: that reads as a game, and vanishes on white). Angles are
    /// clockwise on screen, and so is the conic gradient, so the two agree without any flipping.
    private static func drawComet(_ comet: SwirlMath.Frame.Comet, hueShift: Double, center c: CGPoint,
                                  in g: inout GraphicsContext) {
        let start = comet.head - comet.tail
        var path = Path()
        let steps = 40
        for s in 0...steps {
            let a = start + comet.tail * Double(s) / Double(steps)
            let p = CGPoint(x: c.x + comet.radius * cos(a), y: c.y + comet.radius * sin(a))
            if s == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        let tailFraction = comet.tail / (2 * .pi)
        var stops: [Gradient.Stop] = (0...8).map { j in
            let k = Double(j) / 8
            return Gradient.Stop(color: hue(start + comet.tail * k - hueShift).opacity(pow(k, 1.5) * comet.opacity),
                                 location: k * tailFraction)
        }
        stops.append(Gradient.Stop(color: .clear, location: min(tailFraction + 0.002, 1)))
        stops.append(Gradient.Stop(color: .clear, location: 1))
        let shading = GraphicsContext.Shading.conicGradient(Gradient(stops: stops), center: c, angle: .radians(start))
        let style = StrokeStyle(lineWidth: comet.width, lineCap: .round, lineJoin: .round)

        for (scale, alpha) in [(5.0, 0.10), (2.6, 0.28), (1.0, 1.0)] {
            g.opacity = alpha
            g.stroke(path, with: shading, style: StrokeStyle(lineWidth: style.lineWidth * scale,
                                                             lineCap: .round, lineJoin: .round))
        }
        g.opacity = 1

        let head = CGPoint(x: c.x + comet.radius * cos(comet.head), y: c.y + comet.radius * sin(comet.head))
        let headColor = hue(comet.head - hueShift, white: 0.3)
        let glow = comet.width * 1.9
        g.fill(Path(ellipseIn: CGRect(x: head.x - glow, y: head.y - glow, width: glow * 2, height: glow * 2)),
               with: .color(headColor.opacity(0.35 * comet.opacity)))
        let dot = comet.width * 0.75
        g.fill(Path(ellipseIn: CGRect(x: head.x - dot, y: head.y - dot, width: dot * 2, height: dot * 2)),
               with: .color(headColor.opacity(comet.opacity)))
    }
}
