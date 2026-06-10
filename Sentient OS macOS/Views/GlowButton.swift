//
//  GlowButton.swift
//  Sentient OS macOS
//
//  The rotating conic-gradient glow CTA — ported from the iOS onboarding's "Start Analysis"
//  button (itself a port of the website's GlowButton). A white capsule sits on a slowly
//  rotating angular-gradient halo (warm-yellow → orange → red → pink → purple → indigo → blue,
//  3.5s loop, blurred). Inactive = dim, no halo.
//

import SwiftUI

struct GlowButton: View {
    let title: String
    var systemImage: String = "sparkles"
    var active: Bool = true
    var reversed: Bool = false       // spin the halo the other direction
    var colors: [Color]? = nil       // custom halo palette (nil = default warm stops)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(active ? .black : .white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Capsule(style: .continuous).fill(active ? Color.white : Color.white.opacity(0.08)))
            .overlay(Capsule(style: .continuous).stroke(active ? .clear : Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(GlowPressStyle())
        .background(GlowHalo(active: active, reversed: reversed, colors: colors))
        .disabled(!active)
        .animation(.easeInOut(duration: 0.4), value: active)
    }
}

/// Subtle scale-on-press, mirroring the website's hover/active scale.
private struct GlowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// Rotating conic-gradient halo — exact color stops & 3.5s timing from the website's GlowButton.
struct GlowHalo: View {
    let active: Bool
    var reversed: Bool = false
    var colors: [Color]? = nil

    private static let stops: [Color] = [
        Color(red: 0.992, green: 0.886, blue: 0.639),  // #fde2a3 warm yellow
        Color(red: 1.000, green: 0.557, blue: 0.235),  // #ff8e3c orange
        Color(red: 1.000, green: 0.275, blue: 0.275),  // #ff4646 red
        Color(red: 0.910, green: 0.220, blue: 0.561),  // #e8388f pink
        Color(red: 0.608, green: 0.282, blue: 0.831),  // #9b48d4 purple
        Color(red: 0.424, green: 0.361, blue: 0.898),  // #6c5ce5 indigo
        Color(red: 0.290, green: 0.565, blue: 0.886),  // #4a90e2 blue
        Color(red: 0.992, green: 0.886, blue: 0.639)   // wrap → smooth seam
    ]
    private static let period: Double = 3.5

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let base = (t.truncatingRemainder(dividingBy: GlowHalo.period) / GlowHalo.period) * 360.0
                let angle = reversed ? -base : base
                Capsule(style: .continuous)
                    .fill(AngularGradient(colors: colors ?? GlowHalo.stops, center: .center, angle: .degrees(angle)))
                    .frame(width: geo.size.width + 32, height: geo.size.height + 32)
                    .blur(radius: 24)
                    .offset(x: -16, y: -16)
            }
            .opacity(active ? 0.85 : 0)
            .animation(.easeInOut(duration: 0.6), value: active)
        }
        .allowsHitTesting(false)
    }
}
