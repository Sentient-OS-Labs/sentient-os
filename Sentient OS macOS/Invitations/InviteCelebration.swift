// The verified invitation's gift-opening sequence, paper envelope, and finite confetti burst.
// Presentation only: claiming or dismissing never changes the server-confirmed entitlement.
// Doc: ../Views/Onboarding/Documentation - Onboarding.md

import SwiftUI

struct InviteCelebration: View {
    let ticketNamespace: Namespace.ID
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var tucked = false
    @State private var opened = false
    @State private var letterVisible = false
    @State private var ready = false
    @State private var claimed = false
    @State private var burst: Date?
    @FocusState private var claimFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Color.black.opacity(0.96).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture {}

                // One pool of light, confined to the gift. No repeating animation at rest.
                Ellipse()
                    .fill(AngularGradient(colors: InvitePaper.spectrum.map { $0.opacity(0.14) }, center: .center))
                    .frame(width: 490, height: 280).blur(radius: 85)
                    .opacity(arrived ? 1 : 0)
                    .position(x: center.x, y: center.y + 65)
                    .allowsHitTesting(false)

                if !claimed {
                    Text(ready ? "SOME THINGS ARE YOURS FOREVER" : "A LITTLE SOMETHING, JUST FOR YOU")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(2.5).foregroundStyle(.white.opacity(0.5))
                        .position(x: center.x, y: center.y - 260)
                        .opacity(arrived ? 1 : 0)

                    InviteEnvelope(opened: opened, letterVisible: letterVisible)
                        .frame(width: 430, height: 270)
                        .rotationEffect(.degrees(arrived ? 0 : -9))
                        .offset(y: reduceMotion || arrived ? 0 : 170)
                        .opacity(arrived ? 1 : 0)
                        .position(x: center.x, y: center.y + 50)
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .scale(scale: 1.12).combined(with: .opacity)))

                    if !reduceMotion {
                        InviteTicketFace()
                            .frame(width: 332)
                            .matchedGeometryEffect(id: "invite-ticket", in: ticketNamespace)
                            .rotationEffect(.degrees(tucked ? 0 : -8))
                            .scaleEffect(tucked ? 0.72 : 1)
                            .opacity(tucked ? 0 : 1)
                            .position(x: center.x, y: center.y + (tucked ? 95 : -70))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                } else {
                    VStack(spacing: 14) {
                        Text("All yours. For life.")
                            .font(.system(size: 43, weight: .medium))
                            .foregroundStyle(InvitePaper.light)
                        Text("Thanks for being here early.")
                            .font(.system(size: 16)).foregroundStyle(.white.opacity(0.58))
                    }
                    .position(x: center.x, y: center.y - 155)
                    .transition(.opacity)

                    InviteTicketFace(claimed: true)
                        .frame(width: 372)
                        .rotationEffect(.degrees(-3))
                        .position(x: center.x, y: center.y + 10)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.75).combined(with: .opacity))
                }

                VStack(spacing: 12) {
                    Button(action: claimed ? onClose : claim) {
                        HStack(spacing: 12) {
                            Text(claimed ? "Continue setup" : "Claim lifetime access")
                            Image(systemName: claimed ? "arrow.right" : "sparkle")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(InvitePaper.ink)
                        .padding(.horizontal, 26).frame(height: 48)
                        .background(InvitePaper.light, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .focused($claimFocused)
                    .disabled(!ready)

                    Text(claimed ? "Your lifetime pass is saved. Make yourself at home."
                                 : "Sentient OS, free for life. A gift from us to you.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.48))
                }
                .opacity(ready ? 1 : 0)
                .offset(y: ready || reduceMotion ? 0 : 12)
                .position(x: center.x, y: center.y + 245)
                .accessibilityHidden(!ready)

                if let burst {
                    InviteConfetti(start: burst).allowsHitTesting(false).accessibilityHidden(true)
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.07), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close invitation. Lifetime access is saved.")
                    }
                    Spacer()
                }
                .padding(28)
            }
            .onExitCommand(perform: onClose)
            .task { await reveal() }
            .task(id: burst) {
                guard burst != nil else { return }
                do { try await Task.sleep(for: .seconds(3.4)) } catch { return }
                burst = nil
            }
        }
    }

    private func reveal() async {
        if reduceMotion {
            arrived = true; tucked = true; opened = true; letterVisible = true; ready = true
            claimFocused = true
            return
        }
        withAnimation(.spring(duration: 0.85, bounce: 0.17)) { arrived = true }
        do {
            try await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeInOut(duration: 0.42)) { tucked = true }
            try await Task.sleep(for: .milliseconds(420))
            withAnimation(.easeInOut(duration: 0.55)) { opened = true }
            try await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(duration: 0.85, bounce: 0.12)) { letterVisible = true }
            try await Task.sleep(for: .milliseconds(480))
            withAnimation(.easeOut(duration: 0.3)) { ready = true }
            claimFocused = true
        } catch { return }
    }

    private func claim() {
        guard ready, !claimed else { return }
        if !reduceMotion { burst = Date() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.65, bounce: 0.18)) {
            claimed = true
        }
    }
}

private struct InviteEnvelope: View {
    let opened: Bool
    let letterVisible: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.24, green: 0.25, blue: 0.28))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.2)) }

            // The flap moves behind the letter as it opens; the pocket remains in front.
            InviteEnvelopeFlap()
                .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.16)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay { InviteEnvelopeFlap().stroke(.white.opacity(0.17), lineWidth: 1) }
                .frame(height: 152)
                .rotation3DEffect(.degrees(opened ? 178 : 0), axis: (x: 1, y: 0, z: 0),
                                  anchor: .top, perspective: 0.4)
                .zIndex(opened ? 0 : 4)

            letter
                .frame(width: 368, height: 300)
                .offset(y: letterVisible ? -172 : 5)
                .opacity(opened ? 1 : 0)
                .zIndex(1)

            InviteEnvelopePocket()
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.105)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { InviteEnvelopePocket().stroke(.white.opacity(0.13), lineWidth: 1) }
                .zIndex(2)

            VStack(spacing: 9) {
                Image(systemName: "infinity").font(.system(size: 23, weight: .ultraLight))
                Text("WITH LOVE, SENTIENT")
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.6)
            }
            .foregroundStyle(InvitePaper.light.opacity(0.7))
            .padding(.top, 198).zIndex(3)

            ZStack {
                Circle().fill(AngularGradient(colors: InvitePaper.spectrum, center: .center))
                Circle().fill(.black.opacity(0.24)).padding(3)
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5).padding(15)
                Circle().fill(.white).padding(23)
            }
            .frame(width: 58, height: 58)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            .offset(y: 116)
            .scaleEffect(opened ? 1.3 : 1).opacity(opened ? 0 : 1).zIndex(5)
        }
        .shadow(color: .black.opacity(0.6), radius: 35, y: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(letterVisible ? "Welcome. Sentient OS, yours for life. Lifetime access verified." : "Opening your invitation")
    }

    private var letter: some View {
        VStack(spacing: 14) {
            Text("WELCOME TO YOUR FOREVER PLAN")
                .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5)
                .opacity(0.6).padding(.top, 27)
            Text("Sentient OS.\nYours for life.")
                .font(.system(size: 37, weight: .medium))
                .multilineTextAlignment(.center).lineSpacing(0)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                Text("Lifetime access, reserved for you.")
            }
            .font(.system(size: 11)).opacity(0.65)
            Spacer(minLength: 0)
        }
        .foregroundStyle(InvitePaper.ink)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [InvitePaper.light, InvitePaper.shade], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.5)) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: -3)
    }
}

private struct InviteEnvelopeFlap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.midX + 12, y: rect.maxY - 5))
        p.addQuadCurve(to: CGPoint(x: rect.midX - 12, y: rect.maxY - 5),
                       control: CGPoint(x: rect.midX, y: rect.maxY + 5))
        p.closeSubpath()
        return p
    }
}

private struct InviteEnvelopePocket: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 14))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - 14, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: 14, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - 14), control: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Deterministic paper fragments with drag, gravity, and a tumbling face. Removed after 3.4 s.
private struct InviteConfetti: View {
    let start: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let palette = InvitePaper.spectrum + [InvitePaper.light, .white]
                for index in 0..<112 {
                    let seed = random(index, salt: 17)
                    let t = elapsed - seed * 0.12
                    guard t > 0, t < 3.2 else { continue }
                    let angle = random(index, salt: 41) * .pi * 2
                    let speed = 210 + random(index, salt: 83) * 460
                    let drag = (1 - exp(-1.4 * t)) / 1.4
                    let x = size.width / 2 + cos(angle) * speed * drag
                    let y = size.height / 2 + 45 + (sin(angle) * speed - 260) * drag + 170 * t * t
                    var particle = context
                    particle.opacity = min(1, (3.2 - t) * 1.5)
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(angle + t * (seed * 9 - 4)))
                    particle.scaleBy(x: max(0.14, abs(cos(t * 7 + angle))), y: 1)
                    let piece = CGRect(x: -3, y: -5, width: 4 + seed * 5, height: 7 + seed * 8)
                    let path = index.isMultiple(of: 7) ? Path(ellipseIn: piece) : Path(roundedRect: piece, cornerRadius: 1)
                    particle.fill(path, with: .color(palette[index % palette.count]))
                }
            }
        }
    }

    private func random(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 127 + salt) * 78.233) * 43_758.5453
        return value - floor(value)
    }
}

#if DEBUG
private struct InviteCelebrationPreview: View {
    @Namespace private var ticket
    var body: some View {
        InviteCelebration(ticketNamespace: ticket, onClose: {})
            .frame(width: 1040, height: 800).preferredColorScheme(.dark)
    }
}
#Preview("Open a lifetime invitation") { InviteCelebrationPreview() }
#endif
