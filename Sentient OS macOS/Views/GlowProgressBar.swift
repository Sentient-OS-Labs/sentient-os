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

    @State private var phase: Double = 0
    @State private var lastTick: Date?

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
        let n = stops.count
        for rep in 0..<tiles {
            for (i, color) in stops.enumerated() {
                result.append(.init(color: color, location: (Double(rep) + Double(i) / Double(n)) / Double(tiles)))
            }
        }
        result.append(.init(color: stops[0], location: 1.0))
        return result
    }

    /// The fill-width capsule of the scrolling color gradient — rendered crisp on top and blurred
    /// behind (= the glow). Same gradient/offset, so the glow flows with the colors.
    @ViewBuilder
    private func coloredCapsule(p: CGFloat, fill: CGFloat, tiles: Int, gradient: [Gradient.Stop]) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(stops: gradient, startPoint: .leading, endPoint: .trailing))
                .frame(width: band * CGFloat(tiles), height: 9)
                .offset(x: -band + p)
        }
        .frame(width: fill, height: 9, alignment: .leading)
        .clipShape(Capsule())
    }

    /// A tip-concentrated glow: the colored capsule masked to a fixed-width region at the leading
    /// tip (fading out toward the start) BEFORE blurring, so it blooms freely but only at the
    /// leading edge — a long bar never glows end-to-end.
    @ViewBuilder
    private func tipGlow(p: CGFloat, fill: CGFloat, tiles: Int, gradient: [Gradient.Stop], blur: CGFloat) -> some View {
        let t = min(1.0, value * 3.0)   // how strongly the back is dimmed (tune the 3.0)
        coloredCapsule(p: p, fill: fill, tiles: tiles, gradient: gradient)
            .mask {
                LinearGradient(stops: [
                    .init(color: .white.opacity(1 - t), location: 0.0),   // trailing (start)
                    .init(color: .white, location: 1.0),                  // leading tip — always full
                ], startPoint: .leading, endPoint: .trailing)
            }
            .blur(radius: blur)
            .blendMode(.plusLighter)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = value > 0 ? max(min(value, 1) * w, 14) : 0
            let p = CGFloat(phase.truncatingRemainder(dividingBy: Double(band)))
            // Enough tiles that the gradient covers the widest fill even right after a phase
            // wrap: coverage's right edge is p + band × (tiles − 1), worst case p = 0.
            let tiles = Int(ceil(w / band)) + 1
            let gradient = Self.gradientStops(tiles: tiles)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if fill > 0 {
                    ZStack(alignment: .leading) {
                        tipGlow(p: p, fill: fill, tiles: tiles, gradient: gradient, blur: 38)
                        tipGlow(p: p, fill: fill, tiles: tiles, gradient: gradient, blur: 22)
                        tipGlow(p: p, fill: fill, tiles: tiles, gradient: gradient, blur: 11)
                        tipGlow(p: p, fill: fill, tiles: tiles, gradient: gradient, blur: 5)
                        coloredCapsule(p: p, fill: fill, tiles: tiles, gradient: gradient)
                    }
                }
            }
            .overlay {
                // Drive the scroll: phase ACCUMULATES (speed × dt) so changing speed never jumps the
                // colors. Speed ∝ fill width → tiny pill = slow, gentle color fade.
                TimelineView(.animation) { ctx in
                    Color.clear.onChange(of: ctx.date) { _, newDate in
                        let dt = lastTick.map { newDate.timeIntervalSince($0) } ?? 0
                        lastTick = newDate
                        let speed = 16 + min(value, 1) * 44   // points / second
                        phase += speed * min(dt, 0.05)        // clamp dt so a pause can't jump it
                    }
                }
            }
        }
        .frame(height: 9)
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
