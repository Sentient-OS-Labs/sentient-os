// OnboardingDoubleTapKeyboard.swift
// A face-on crop of the lower keyboard and trackpad locates the right Command key.
// The invitation's slow Sentient color field pauses outside the waiting beat and with
// Reduce Motion. Each tap gently pulses the glow around the key, with no particles or expanding ring.
// Doc: Documentation - Onboarding.md (this folder).

import SwiftUI

struct OnboardingDoubleTapKeyboard: View {
    let pressed: Bool
    let inviting: Bool
    let reduceMotion: Bool
    var tapFeedback: OnboardingDoubleTapDemo.TapFeedback? = nil
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            surroundings
                .frame(width: 760, height: 200)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .white.opacity(0.12), location: 0.12),
                                           .init(color: .white.opacity(0.6), location: 0.25),
                                           .init(color: .white, location: 0.4),
                                           .init(color: .white, location: 0.65),
                                           .init(color: .white.opacity(0.65), location: 0.8),
                                           .init(color: .white.opacity(0.12), location: 0.92),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .white.opacity(0.2), location: 0.08),
                                                   .init(color: .white.opacity(0.75), location: 0.18),
                                                   .init(color: .white, location: 0.30),
                                                   .init(color: .white, location: 0.48),
                                                   .init(color: .white.opacity(0.75), location: 0.62),
                                                   .init(color: .white.opacity(0.25), location: 0.8),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)

            // Keep the focal key and its soft glow outside the surrounding deck's fade.
            commandKey.position(x: 374, y: 85)
        }
        .frame(width: 760, height: 200)
    }

    private var surroundings: some View {
        ZStack(alignment: .topLeading) {
            // This is a crop of a larger palm rest, not the outer edge of the computer.
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.085), Color(white: 0.035)],
                                     startPoint: .top, endPoint: .bottom))

            HStack(spacing: 8) {
                ForEach(["B", "N", "M", ",", ".", "/"], id: \.self) { letter in
                    KeyboardKeycap(label: letter, width: 53, height: 46)
                }
                KeyboardKeycap(label: "shift", width: 127, height: 46, alignment: .trailing)
            }
            .offset(x: 157, y: 4)

            HStack(alignment: .top, spacing: 8) {
                KeyboardKeycap(label: "", width: 294, height: 54)
                Color.clear.frame(width: 68, height: 54) // right Command, drawn above the fade
                KeyboardKeycap(label: "option", symbol: "option", width: 53, height: 54)
                arrowKeys
            }
            .offset(x: 38, y: 58)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.068), Color(white: 0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.black.opacity(0.75), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .inset(by: 1.5)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.03)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                }
                .frame(width: 346, height: 160)
                .offset(x: 65, y: 128)
        }
    }

    private var arrowKeys: some View {
        HStack(alignment: .bottom, spacing: 7) {
            KeyboardKeycap(label: "", symbol: "arrowtriangle.left.fill", width: 53, height: 25.5)
            VStack(spacing: 3) {
                KeyboardKeycap(label: "", symbol: "arrowtriangle.up.fill", width: 53, height: 25.5)
                KeyboardKeycap(label: "", symbol: "arrowtriangle.down.fill", width: 53, height: 25.5)
            }
            KeyboardKeycap(label: "", symbol: "arrowtriangle.right.fill", width: 53, height: 25.5)
        }
        .allowsHitTesting(false)
    }

    private var commandKey: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: (!inviting && tapFeedback == nil) || reduceMotion)) { context in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate * .pi * 2 / 10
                let pulse = tapFeedback.map { feedback in
                    let progress = min(1, max(0, context.date.timeIntervalSince(feedback.began) / feedback.duration))
                    return reduceMotion ? 0.4 : pow(1 - progress, 2)
                } ?? 0
                let breath = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(time * 2)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.black.opacity(0.8))
                        .offset(y: 2)
                        .shadow(color: GlowHalo.stops[6].opacity((inviting ? 0.24 + breath * 0.08 : 0) + pulse * 0.28),
                                radius: 12 + pulse * 4, x: -4, y: 2)
                        .shadow(color: GlowHalo.stops[3].opacity((inviting ? 0.20 + breath * 0.08 : 0) + pulse * 0.22),
                                radius: 12 + pulse * 4, x: 4, y: 2)

                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(white: 0.085))
                        .overlay {
                            keyColors(time: time)
                                .opacity(inviting || pressed || tapFeedback != nil ? 0.92 : 0.18)
                        }
                        .overlay {
                            LinearGradient(colors: [.white.opacity((pressed ? 0.28 : 0.12) + pulse * 0.08), .clear, .black.opacity(0.2)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [.white.opacity(inviting ? 0.65 : 0.24),
                                                                      .white.opacity(0.08), .white.opacity(inviting ? 0.4 : 0.12)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                        }
                        .overlay(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 5) {
                                Image(systemName: "command").font(.system(size: 22, weight: .medium))
                                Text("command").font(.system(size: 8.5, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(inviting || pressed || tapFeedback != nil ? 1 : 0.65))
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .padding(.leading, 10)
                        }
                        .shadow(color: .black.opacity(0.45), radius: pressed ? 0.5 : 2, y: pressed ? 0 : 2)
                        .offset(y: pressed && !reduceMotion ? 1.5 : 0)
                        .scaleEffect(pressed && !reduceMotion ? 0.965 : 1)
                }
                .frame(width: 68, height: 54)
                .animation(.easeOut(duration: 0.4), value: inviting)
                .animation(reduceMotion ? nil : .spring(duration: pressed ? 0.1 : 0.25, bounce: 0.12), value: pressed)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(KeyboardTapPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("Right Command key")
        .accessibilityHint("Double-click this key, or double tap your right Command key, to fill the sample reply.")
        .accessibilityValue(tapFeedback?.confirmed == false ? "One tap. Tap again." : "")
    }

    /// Wide, softly overlapping color pools orbit inside the stationary key face. Painting
    /// into fixed bounds keeps the rounded edges clean at every point in the animation.
    private func keyColors(time: Double) -> some View {
        let angle = time
        return ZStack {
            GlowHalo.stops[5]
            RadialGradient(colors: [GlowHalo.stops[6], GlowHalo.stops[6].opacity(0)],
                           center: UnitPoint(x: 0.25 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle)),
                           startRadius: 0, endRadius: 72)
            RadialGradient(colors: [GlowHalo.stops[3], GlowHalo.stops[4].opacity(0)],
                           center: UnitPoint(x: 0.5 + 0.55 * cos(angle + 2.1), y: 0.5 + 0.5 * sin(angle + 2.1)),
                           startRadius: 0, endRadius: 68)
            RadialGradient(stops: [.init(color: GlowHalo.stops[0], location: 0),
                                   .init(color: GlowHalo.stops[1].opacity(0.9), location: 0.32),
                                   .init(color: GlowHalo.stops[2].opacity(0), location: 1)],
                           center: UnitPoint(x: 0.5 + 0.65 * cos(angle + 4.2), y: 0.5 + 0.6 * sin(angle + 4.2)),
                           startRadius: 0, endRadius: 72)
        }
    }

}

private struct KeyboardTapPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .offset(y: configuration.isPressed && !reduceMotion ? 1.5 : 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.1), value: configuration.isPressed)
    }
}

/// Unlit neighboring keys establish position without competing with the invitation.
private struct KeyboardKeycap: View {
    let label: String
    var symbol: String? = nil
    let width: CGFloat
    let height: CGFloat
    var alignment: Alignment = .center

    var body: some View {
        VStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: label.isEmpty ? 7 : 17, weight: .regular))
            }
            if !label.isEmpty {
                Text(label).font(.system(size: label.count == 1 ? 12 : 8.5, weight: .medium))
            }
        }
        .foregroundStyle(.white.opacity(0.38))
        .padding(.horizontal, 12)
        .frame(width: width, height: height, alignment: alignment)
        .background {
            RoundedRectangle(cornerRadius: height < 30 ? 5 : 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.082), Color(white: 0.048)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: height < 30 ? 5 : 8, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.045)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.85), radius: 1.5, y: 2)
    }
}

#if DEBUG
#Preview("Double Tap keyboard · invitation") {
    OnboardingDoubleTapKeyboard(pressed: false, inviting: true, reduceMotion: false, action: {})
        .padding(32).background(.black)
}

#Preview("Double Tap keyboard · reduced motion") {
    OnboardingDoubleTapKeyboard(pressed: false, inviting: true, reduceMotion: true, action: {})
        .padding(32).background(.black)
}
#endif
