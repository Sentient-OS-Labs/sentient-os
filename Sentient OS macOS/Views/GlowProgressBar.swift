//
//  GlowProgressBar.swift
//  Sentient OS macOS
//
//  The signature rainbow-glow progress bar: a scrolling multicolor gradient fill with a
//  tip-concentrated bloom — the "act of analyzing" jewelry from the shipped ProcessingView
//  design. Born there; now shared with onboarding's downloading-model screen. One bar, one place.
//
//  ⚠️ The gradient rect tiles from the bar's measured width (`ceil(w / band) + 1` tiles) — a
//  fixed tile count can't cover fills wider than `band` right after a phase wrap, so the tip
//  visibly snapped back every ~5s once progress passed band/width (field-found 2026-07-11).
//

import SwiftUI

/// A multicolor signature-gradient fill with a flowing sheen sweeping rightward + a soft glow.
struct GlowProgressBar: View {
    var value: Double   // 0...1

    /// Anchors phase at the last `value` change so `phase(at:value:)` is a pure function of wall
    /// time (zero `@State` writes per frame) while changing speed never jumps the colors.
    private struct PhaseAnchor {
        var phase: Double = 0
        var time: TimeInterval = Date().timeIntervalSinceReferenceDate

        static func speed(for value: Double) -> Double {
            16 + min(max(value, 0), 1) * 44   // points / second
        }

        func phase(at t: TimeInterval, value: Double) -> Double {
            phase + max(0, t - time) * Self.speed(for: value)
        }

        mutating func advance(from oldValue: Double, at now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
            phase = phase(at: now, value: oldValue)
            time = now
        }
    }

    @State private var anchor = PhaseAnchor()

    private let band: CGFloat = 280   // points spanned by one full color sequence

    private static let stops: [Color] = [
        Color(red: 1.00, green: 0.78, blue: 0.28),  // amber
        Color(red: 1.00, green: 0.45, blue: 0.45),  // coral
        Color(red: 0.91, green: 0.30, blue: 0.62),  // pink
        Color(red: 0.62, green: 0.40, blue: 0.95),  // violet
        Color(red: 0.36, green: 0.55, blue: 0.98),  // blue
        Color(red: 0.29, green: 0.87, blue: 0.50),  // green (Ink.green)
    ]

    /// Stops tiled `tiles` times with explicit locations → the gradient is periodic over `band`
    /// points, so scrolling it by `band` is seamless.
    private static func gradientStops(tiles: Int) -> [Gradient.Stop] {
        var result: [Gradient.Stop] = []
        result.reserveCapacity(tiles * stops.count + 1)
        let n = stops.count
        for rep in 0..<tiles {
            for (i, color) in stops.enumerated() {
                result.append(.init(color: color, location: (Double(rep) + Double(i) / Double(n)) / Double(tiles)))
            }
        }
        result.append(.init(color: stops[0], location: 1.0))
        return result
    }

    /// Tip-concentrated glow stops: fades the trailing end toward `1 - t` directly in stop opacity
    /// so bloom passes never allocate an offscreen `.mask` texture per frame.
    private func glowStops(from gradient: [Gradient.Stop], tiles: Int, p: CGFloat, fill: CGFloat) -> [Gradient.Stop] {
        let t = min(1.0, max(0.0, value) * 3.0)   // how strongly the back is dimmed (tune the 3.0)
        let totalWidth = band * CGFloat(tiles)
        let offset = -band + p
        let span = max(fill, 1)
        return gradient.map { stop in
            let progress = min(max(Double((stop.location * totalWidth + offset) / span), 0), 1)
            return .init(color: stop.color.opacity((1 - t) + t * progress), location: stop.location)
        }
    }

    /// The fill-width capsule of the scrolling color gradient — rendered crisp on top and blurred
    /// behind (= the glow). Shifts `UnitPoint` directly on the capsule instead of clipping an
    /// oversized `Rectangle` on every frame.
    private func coloredCapsule(p: CGFloat, fill: CGFloat, tiles: Int, gradient: [Gradient.Stop], height: CGFloat = 9) -> some View {
        let startX = (-band + p) / fill
        let endX = (-band + p + band * CGFloat(tiles)) / fill
        return Capsule()
            .fill(LinearGradient(stops: gradient,
                                 startPoint: UnitPoint(x: startX, y: 0.5),
                                 endPoint: UnitPoint(x: endX, y: 0.5)))
            .frame(width: fill, height: height)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = value > 0 ? max(min(value, 1) * w, 14) : 0
            // Enough tiles that the gradient covers the widest fill even right after a phase
            // wrap: coverage's right edge is p + band × (tiles − 1), worst case p = 0.
            let tiles = Int(ceil(w / band)) + 1
            let gradient = Self.gradientStops(tiles: tiles)
            FocusThrottledTimeline(minimumInterval: 1.0 / 30.0, unfocusedInterval: 1.0 / 12.0, paused: fill <= 0) { t in
                let phase = anchor.phase(at: t, value: value)
                let p = CGFloat(phase.truncatingRemainder(dividingBy: Double(band)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                        .frame(height: 9)
                    if fill > 0 {
                        let glow = glowStops(from: gradient, tiles: tiles, p: p, fill: fill)
                        ZStack(alignment: .leading) {
                            coloredCapsule(p: p, fill: fill, tiles: tiles, gradient: glow, height: 11)
                                .blur(radius: 24)
                                .blendMode(.plusLighter)
                            coloredCapsule(p: p, fill: fill, tiles: tiles, gradient: glow, height: 10)
                                .blur(radius: 7)
                                .blendMode(.plusLighter)
                            coloredCapsule(p: p, fill: fill, tiles: tiles, gradient: gradient)
                        }
                        .frame(height: 9)
                    }
                }
            }
        }
        .frame(height: 9)
        .onChange(of: value) { oldValue, _ in
            anchor.advance(from: oldValue)
        }
        .animation(.easeInOut(duration: 0.35), value: value)
    }
}

#Preview("Glow progress bar") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 30) {
            GlowProgressBar(value: 0.08)
            GlowProgressBar(value: 0.55)
            GlowProgressBar(value: 0.92)
        }
        .frame(width: 380)
        .padding(60)
    }
    .frame(width: 560, height: 300)
    .preferredColorScheme(.dark)
}
