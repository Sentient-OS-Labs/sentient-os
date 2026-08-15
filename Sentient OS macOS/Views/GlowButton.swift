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
    var glowIntensity: Double = 0.85 // halo opacity when active (lower = subtler glow)
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
        .background(GlowHalo(active: active, reversed: reversed, colors: colors, intensity: glowIntensity))
        .disabled(!active)
        .animation(.easeInOut(duration: 0.4), value: active)
    }
}

/// The glow CTA's quiet sibling — a grey outlined capsule for the visible-but-subordinate
/// choice beside it (the crossroads' "continue with just the knowledge base", the free home's
/// "Reset Sentient…"). Present enough to read as a real button, never competing with the glow.
/// `large` matches the glow button's height and fills its container — for the one case where the
/// two sit SIDE BY SIDE as a row (the crossroads' "I've upgraded to ChatGPT Plus") rather than
/// stacked; still no halo, so the glow stays the only jewelry on the screen.
struct QuietPillButton: View {
    let title: String
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: large ? 14.5 : 13.5, weight: .medium))
                .foregroundStyle(Theme.Ink.bright)
                .lineLimit(1)
                .frame(maxWidth: large ? .infinity : nil)
                .padding(.horizontal, 22).padding(.vertical, large ? 17 : 12)
                .background(Capsule().fill(.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
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
    var intensity: Double = 0.85     // halo opacity when active

    /// The canonical warm→cool AI-gradient stops (shared: the Analyze Now CTA + the For You
    /// command bar's glow both use these).
    static let stops: [Color] = [
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
            .opacity(active ? intensity : 0)
            .animation(.easeInOut(duration: 0.6), value: active)
        }
        .allowsHitTesting(false)
    }
}
