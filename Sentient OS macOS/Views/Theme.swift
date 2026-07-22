//
//  Theme.swift
//  Sentient OS macOS
//
//  The Sentient OS visual language — one place so "fancy everywhere" stays consistent.
//  Pure OLED black, a bold tight-tracked display voice, glassy elevated surfaces, a soft violet
//  glow, and verdict color-coding. Serif survives only as the face of a note's name (Knowledge
//  reader headings, star labels) and inside the gift letter. The app is dark-only (no light mode).
//

import SwiftUI

enum Theme {
    static let bg = Color.black
    /// The Knowledge sidebar surface — moonlit slate: near-neutral graphite with a whisper of cool
    /// blue (b > g > r), so the folder panel reads as night-sky chrome and recedes behind the
    /// reading pane. (The old warm-orange panel read as a Claude-ism.)
    static let panel = Color(red: 0.053, green: 0.058, blue: 0.072)
    static let elevated = Color.white.opacity(0.05)
    static let stroke = Color.white.opacity(0.09)
    static let secondary = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let accent = Color(red: 0.62, green: 0.55, blue: 1.0)   // soft violet glow
    /// The Knowledge window's interactive accent — starlight periwinkle (#8ea6ff), the middle note
    /// of the wikilink gradient. Selected rows, tints, carets. Color means "alive/tappable" here;
    /// everything else stays neutral ink.
    static let knowledgeAccent = Color(red: 0.557, green: 0.651, blue: 1.0)

    /// The wikilink color — a plain, minimalist sky blue (#6fb6ff). Deliberately a solid, honest
    /// web-link blue: gradient text reads as AI-generated, single claimed hues read as other
    /// brands; sky blue on a night-sky surface reads as ours.
    static let knowledgeLink = Color(red: 0.435, green: 0.714, blue: 1.0)

    /// The sky's "changed last night" shimmer — dawn cyan.
    static let dawnCyan = Color(red: 0.333, green: 0.757, blue: 0.941)

    /// "Magic" cool palette for the Stage-2 vault CTA glow — teal · cyan · blue · indigo · purple.
    static let magicGlow: [Color] = [
        Color(red: 0.16, green: 0.83, blue: 0.74),  // teal
        Color(red: 0.13, green: 0.83, blue: 0.93),  // cyan
        Color(red: 0.23, green: 0.51, blue: 0.96),  // blue
        Color(red: 0.39, green: 0.40, blue: 0.95),  // indigo
        Color(red: 0.55, green: 0.36, blue: 0.96),  // violet
        Color(red: 0.66, green: 0.33, blue: 0.97),  // purple
        Color(red: 0.16, green: 0.83, blue: 0.74),  // wrap → teal (smooth seam)
    ]

    static func verdictColor(_ v: Verdict) -> Color {
        switch v {
        case .survivor:  return Ink.green                                    // the one app green
        case .junk:      return Color.white.opacity(0.45)                    // dim
        case .sensitive: return Color(red: 1.0, green: 0.45, blue: 0.45)    // red
        }
    }

    static func verdictLabel(_ v: Verdict) -> String {
        switch v {
        case .survivor:  return "kept"
        case .junk:      return "junk"
        case .sensitive: return "sensitive"
        }
    }

    /// The editorial ink palette (from the Constellation mockup) — shared by the Constellation
    /// home and the For You / briefings window.
    enum Ink {
        static let cardBG = Color(red: 0.047, green: 0.047, blue: 0.059)       // #0c0c0f
        static let statusInk = Color(red: 0.914, green: 0.906, blue: 0.933)    // #e9e7ee
        static let body = Color(red: 0.608, green: 0.604, blue: 0.627)         // #9b9aa0
        static let label = Color(red: 0.431, green: 0.427, blue: 0.459)        // #6e6d75
        static let deepMuted = Color(red: 0.337, green: 0.333, blue: 0.369)    // #56555e
        static let bright = Color(red: 0.812, green: 0.804, blue: 0.839)       // #cfcdd6
        static let green = Color(red: 0.290, green: 0.871, blue: 0.502)        // #4ade80 (was mint #47d7ac — too seafoam)
        static let amber = Color(red: 1.0, green: 0.765, blue: 0.443)          // #ffc371
        static let gold = Color(red: 0.851, green: 0.702, blue: 0.294)         // #d9b34b — the open-source pride mark (Settings footer); NOT the caution amber
        static let red = Color(red: 1.0, green: 0.36, blue: 0.36)              // status-LED red (StatusLine .bad · the home's live caution)
        static let chipInk = Color(red: 0.541, green: 0.537, blue: 0.565)      // #8a8990
        static let chipBorder = Color(red: 0.114, green: 0.114, blue: 0.133)   // #1d1d22
    }
}

/// Monospace ALL-CAPS with wide tracking — the design language's whisper voice.
struct MonoCaps: View {
    private let text: Text
    let size: CGFloat
    let tracking: CGFloat
    let color: Color
    let weight: Font.Weight

    init(_ key: LocalizedStringKey, size: CGFloat, tracking: CGFloat, color: Color, weight: Font.Weight = .medium) {
        self.text = Text(key)
        self.size = size
        self.tracking = tracking
        self.color = color
        self.weight = weight
    }

    /// Runtime / already-composed labels that must not go through the String Catalog.
    init(verbatim text: String, size: CGFloat, tracking: CGFloat, color: Color, weight: Font.Weight = .medium) {
        self.text = Text(verbatim: text)
        self.size = size
        self.tracking = tracking
        self.color = color
        self.weight = weight
    }

    var body: some View {
        text
            .font(.system(size: size, weight: weight, design: .monospaced))
            .tracking(tracking)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

extension Date {
    /// The whisper voice's glanceable time stamp — today → "3:18 AM" · yesterday →
    /// "yesterday 3:18 AM" · older → "Jul 12". Rides the home's "Last run:" line and the
    /// Connect-AIs pill's synced time (MonoCaps uppercases it in place).
    var glanceStamp: String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(self) { f.dateFormat = "h:mm a"; return f.string(from: self) }
        if Calendar.current.isDateInYesterday(self) { f.dateFormat = "h:mm a"; return "yesterday \(f.string(from: self))" }
        f.dateFormat = "MMM d"
        return f.string(from: self)
    }
}

/// Subtle scale-on-press for custom (non-bordered) buttons across the app.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    /// The display voice — SF Pro at medium weight. Hierarchy comes from weight + ink + size, not
    /// a genre switch. Medium, not bold: light-on-black reads about a weight heavier than the same
    /// face on white. NO manual tracking — SF's optical sizing already tightens display sizes, and
    /// extra negative tracking makes big lines render blotchy (crowded pairs look bolder).
    func display(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight))
    }
}

/// Glassy elevated surface used by cards across the app.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = 14) -> some View { modifier(GlassCard(radius: radius)) }
}

/// Small color-coded verdict badge (kept / junk / sensitive).
struct VerdictBadge: View {
    let verdict: Verdict
    var body: some View {
        Text(Theme.verdictLabel(verdict).uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.verdictColor(verdict))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.verdictColor(verdict).opacity(0.14), in: Capsule())
    }
}

/// "Sensitive" — red pill for items that must never leave the device.
struct SensitivePill: View {
    private static let red = Color(red: 1.0, green: 0.45, blue: 0.45)
    var body: some View {
        Label("Sensitive", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.red)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Self.red.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Self.red.opacity(0.45), lineWidth: 1))
    }
}

/// "Junk" — a clear (but neutral) flag for low-value files that won't be kept.
struct JunkPill: View {
    var body: some View {
        Label("Junk", systemImage: "trash")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
    }
}
