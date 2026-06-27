//
//  SpinningLogo.swift
//  Sentient OS macOS
//
//  The 2D Sentient mark for the notch (matches the app icon): a THICK, vibrant ring of the AI spectrum
//  (GlowHalo.stops — the real website-spinner stops) rendered SHARP so the colour reads boldly, over a
//  soft additive bloom, with a thin white ring for shape and a white planet-dot. The spectrum slowly
//  spins, FASTER when Sentient is acting (`fast`); the spin is anchored on every speed change so the
//  colours never jump. Tiny + cheap — the heavy 3D Orb is too much at this size.
//

import SwiftUI

struct SpinningLogo: View {
    var size: CGFloat = 20
    var fast: Bool = false            // running → quicker spin

    // Anchor (angle + wall-time) so a period change re-bases the spin instead of jumping it.
    @State private var anchorAngle: Double = 0
    @State private var anchorTime: Double = Date().timeIntervalSinceReferenceDate

    private static func period(fast: Bool) -> Double { fast ? 4 : 13 }   // seconds / revolution

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = anchorAngle + (t - anchorTime) / Self.period(fast: fast) * 360
            let spectrum = AngularGradient(colors: GlowHalo.stops, center: .center, angle: .degrees(angle))
            ZStack {
                // Big, bright colored neon glow — several ADDITIVE passes (wide → tight) so it really reads.
                // 1. Soft colored bloom (additive) — the neon bleed around the ring.
                Circle().stroke(spectrum, lineWidth: size * 0.22).blur(radius: size * 0.14).blendMode(.plusLighter)
                // 2. The THICK, vibrant color band — the spectrum rendered SHARP + saturated. This is the
                //    logo's real colour, bold and fully visible like the app icon (the old heavy blur was
                //    washing it out).
                Circle().stroke(spectrum, lineWidth: size * 0.17).blur(radius: size * 0.008)
                // 3. A thin white ring — just for the shape.
                Circle().stroke(.white, lineWidth: max(1.0, size * 0.028)).blur(radius: size * 0.005)
                // 4. The white planet — with a tiny additive glow so it reads as lit, not flat.
                Circle().fill(.white).frame(width: size * 0.50, height: size * 0.50)
                    .blur(radius: size * 0.07).blendMode(.plusLighter).opacity(0.6)
                Circle().fill(.white).frame(width: size * 0.36, height: size * 0.36)
            }
            .frame(width: size, height: size)
        }
        // The spin is wall-clock driven — never let a parent's animation (the notch morph) interpolate
        // the gradient angle, or a speed change reverse-spins it for the morph's duration.
        .transaction { $0.animation = nil }
        .onChange(of: fast) { oldFast, _ in
            let t = Date().timeIntervalSinceReferenceDate
            anchorAngle += (t - anchorTime) / Self.period(fast: oldFast) * 360
            anchorTime = t
        }
        .allowsHitTesting(false)
    }
}

#Preview("logo") {
    ZStack {
        Color.black
        HStack(spacing: 30) {
            SpinningLogo(size: 22, fast: false)
            SpinningLogo(size: 22, fast: true)
        }
    }
    .frame(width: 200, height: 120)
}
