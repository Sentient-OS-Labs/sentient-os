//
//  Theme.swift
//  Sentient OS macOS
//
//  The Sentient OS visual language — one place so "fancy everywhere" stays consistent.
//  Pure OLED black, serif-italic display voice, glassy elevated surfaces, a soft violet glow,
//  and verdict color-coding. The app is dark-only (no light mode).
//

import SwiftUI

enum Theme {
    static let bg = Color.black
    static let elevated = Color.white.opacity(0.05)
    static let stroke = Color.white.opacity(0.09)
    static let secondary = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
    static let accent = Color(red: 0.62, green: 0.55, blue: 1.0)   // soft violet glow

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
        case .survivor:  return Color(red: 0.40, green: 0.92, blue: 0.70)   // mint
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

    static let reminderGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.78, blue: 0.28), Color(red: 0.98, green: 0.42, blue: 0.52)],
        startPoint: .leading, endPoint: .trailing
    )
}

extension Font {
    /// The serif-italic display voice (used with `.italic()`), e.g. the "sentient" wordmark.
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
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

/// "Potential Intelligent Reminder" — the brand's golden→coral gradient pill (from iOS).
/// The bell stays a solid golden yellow; only the text rides the gradient.
struct ReminderPill: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bell.fill")
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.28))   // solid golden yellow
            Text("Potential Intelligent Reminder")
                .foregroundStyle(Theme.reminderGradient)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Theme.reminderGradient.opacity(0.5), lineWidth: 1))
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
