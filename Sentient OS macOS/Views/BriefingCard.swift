//
//  BriefingCard.swift
//  Sentient OS macOS
//
//  One suggestion card in the For You window, through its four lives:
//  sealed (the welcome envelope, wax-sealed with the orb) → offer (kicker + serif headline +
//  the verb CTA, e.g. "Should I send it for you?") → working (the agentic theater: mono log
//  lines typing in with a blinking cursor) → done (mint check; the model flies it away).
//  `OfferButton` is shared with the expanded letter view in HomeView.
//

import SwiftUI

enum BriefingPhase: Equatable {
    case sealed            // welcome only: the unopened envelope
    case offer
    case working(Int)      // how many workLog lines are visible
    case done
}

struct BriefingCard: View {
    let briefing: Briefing
    let phase: BriefingPhase
    var onOffer: () -> Void
    var onDetail: () -> Void
    var onOpenEnvelope: () -> Void

    @State private var hovering = false

    static let width: CGFloat = 332

    var body: some View {
        Group {
            if phase == .sealed {
                EnvelopeFace(onOpened: onOpenEnvelope)
            } else {
                face
            }
        }
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
    }

    // MARK: The card faces

    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .sealed:
                EmptyView()
            case .offer:
                offerFace.transition(.blurReplace)
            case .working(let visible):
                workingFace(visible).transition(.blurReplace)
            case .done:
                doneFace.transition(.blurReplace)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.Ink.cardBG, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(border, lineWidth: 1))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: phase)
    }

    private var offerFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps(briefing.kicker, size: 9.5, tracking: 2.0, color: briefing.kind.accent.opacity(0.95))
            Text(briefing.title)
                .font(.system(size: 20, design: .serif)).foregroundStyle(.white)
                .padding(.top, 8)
            Text(briefing.body)
                .font(.system(size: 12)).foregroundStyle(Theme.Ink.body).lineSpacing(3.2)
                .padding(.top, 6)
            HStack(spacing: 12) {
                if let offer = briefing.offer {
                    OfferButton(label: offer, accent: briefing.kind.accent, action: onOffer)
                }
                if let detail = briefing.detailLabel {
                    Button(action: onDetail) {
                        HStack(spacing: 4) {
                            Text(detail).font(.system(size: 11.5))
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(Theme.Ink.bright)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 13)
        }
    }

    private func workingFace(_ visible: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PulsingDot(color: briefing.kind.accent)
                MonoCaps("Working", size: 9.5, tracking: 2.0, color: briefing.kind.accent)
            }
            Text(briefing.title)
                .font(.system(size: 20, design: .serif)).foregroundStyle(.white.opacity(0.85))
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<min(visible, briefing.workLog.count), id: \.self) { i in
                    let line = briefing.workLog[i]
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("✓") ? Theme.Ink.mint : .white.opacity(0.72))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if visible < briefing.workLog.count {
                    BlinkingCursor(color: briefing.kind.accent)
                }
            }
            .padding(.top, 10)
        }
    }

    private var doneFace: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24)).foregroundStyle(Theme.Ink.mint)
            VStack(alignment: .leading, spacing: 5) {
                Text(briefing.doneTitle)
                    .font(.system(size: 20, design: .serif)).foregroundStyle(.white)
                Text(briefing.doneBody)
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var border: LinearGradient {
        if briefing.kind == .welcome { return Self.welcomeGradient }
        return LinearGradient(
            colors: [briefing.kind.accent.opacity(hovering ? 0.55 : 0.40), .white.opacity(0.05)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The full-spectrum hairline only the welcome letter wears (jewelry rule).
    static let welcomeGradient = LinearGradient(
        colors: [Color(red: 1.00, green: 0.37, blue: 0.43).opacity(0.55),
                 Color(red: 1.00, green: 0.76, blue: 0.44).opacity(0.40),
                 Color(red: 0.28, green: 0.84, blue: 0.67).opacity(0.40),
                 Color(red: 0.36, green: 0.55, blue: 1.00).opacity(0.55)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - The verb CTA ("Should I send it for you?")

struct OfferButton: View {
    let label: String
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold))
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(Capsule(style: .continuous).fill(.white.opacity(hovering ? 0.12 : 0.07)))
            .overlay(Capsule(style: .continuous).strokeBorder(
                LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .shadow(color: accent.opacity(hovering ? 0.45 : 0.22), radius: hovering ? 12 : 7)
        .animation(.easeInOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - The welcome envelope

/// The unopened welcome letter: dark paper, a flap that swings open in 3D, and a gradient
/// wax seal carrying the orb mark. Tap anywhere → flap opens → `onOpened` (the parent then
/// expands the letter and the card lives on as a normal welcome card).
private struct EnvelopeFace: View {
    var onOpened: () -> Void
    @State private var open = false

    var body: some View {
        Button {
            guard !open else { return }
            withAnimation(.easeInOut(duration: 0.45)) { open = true }
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                onOpened()
            }
        } label: {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.055, green: 0.051, blue: 0.071))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(BriefingCard.welcomeGradient, lineWidth: 1))

                VStack(spacing: 7) {
                    MonoCaps("A letter from your Sentient", size: 9, tracking: 2.4, color: Theme.Ink.label)
                    Text("For Jesai")   // demo: the recipient comes from the vault portrait later
                        .font(.system(size: 22, design: .serif).italic())
                        .foregroundStyle(Theme.Ink.statusInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 128)

                EnvelopeFlap()
                    .fill(Color(red: 0.082, green: 0.076, blue: 0.106))
                    .overlay(EnvelopeFlap().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .frame(height: 94)
                    .rotation3DEffect(.degrees(open ? -150 : 0),
                                      axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.55)

                seal
                    .offset(y: 94 - 19)
                    .opacity(open ? 0 : 1)
            }
            .frame(width: BriefingCard.width, height: 200)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// The wax: an angular-gradient disc stamped with the logo's ring + dot.
    private var seal: some View {
        ZStack {
            Circle()
                .fill(AngularGradient(colors: [
                    Color(red: 0.76, green: 0.30, blue: 0.36), Color(red: 0.80, green: 0.56, blue: 0.27),
                    Color(red: 0.18, green: 0.58, blue: 0.51), Color(red: 0.30, green: 0.45, blue: 0.85),
                    Color(red: 0.56, green: 0.34, blue: 0.67), Color(red: 0.76, green: 0.30, blue: 0.36),
                ], center: .center))
                .overlay(Circle().fill(Color.black.opacity(0.22)))   // wax depth
                .frame(width: 38, height: 38)
            Circle().strokeBorder(.white.opacity(0.92), lineWidth: 1.5)
                .frame(width: 19, height: 19)
            Circle().fill(.white).frame(width: 6.5, height: 6.5)
        }
        .shadow(color: Color(red: 0.56, green: 0.34, blue: 0.67).opacity(0.5), radius: 8)
    }
}

private struct EnvelopeFlap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Tiny animated bits

private struct PulsingDot: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 5, height: 5)
            .opacity(on ? 1 : 0.25)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true } }
    }
}

private struct BlinkingCursor: View {
    let color: Color
    @State private var on = false
    var body: some View {
        Text("▍").font(.system(size: 11, design: .monospaced)).foregroundStyle(color)
            .opacity(on ? 0.9 : 0.15)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = true } }
    }
}

// MARK: - Previews

#Preview("Offer") {
    ZStack { Color.black
        BriefingCard(briefing: Briefing.demo[0], phase: .offer,
                     onOffer: {}, onDetail: {}, onOpenEnvelope: {})
    }.frame(width: 420, height: 300)
}

#Preview("Working") {
    ZStack { Color.black
        BriefingCard(briefing: Briefing.demo[3], phase: .working(3),
                     onOffer: {}, onDetail: {}, onOpenEnvelope: {})
    }.frame(width: 420, height: 320)
}

#Preview("Done") {
    ZStack { Color.black
        BriefingCard(briefing: Briefing.demo[0], phase: .done,
                     onOffer: {}, onDetail: {}, onOpenEnvelope: {})
    }.frame(width: 420, height: 240)
}

#Preview("Sealed envelope") {
    ZStack { Color.black
        BriefingCard(briefing: Briefing.demo[5], phase: .sealed,
                     onOffer: {}, onDetail: {}, onOpenEnvelope: {})
    }.frame(width: 420, height: 300)
}
