import SwiftUI

/// Lumen: the primary action is lit from within; the other actions belong to the notch.
/// Hover/press motion plus a one-shot onboarding cue. No clocks or idle rendering.
struct NotchQuickActionRow: View {
    var inputReady = true
    var actionsEnabled = true
    var animate = true
    var actionCue: OnboardingActionCue = .idle
    var demoAction: OnboardingNotchAction = .takeOver
    var summarizeHelp = "Summarize what you’re looking at"
    var proofreadHelp = "Polish your selected text"
    var onTakeOver: () -> Void = {}
    var onMagicReply: () -> Void = {}
    var onSummarize: () -> Void = {}
    var onProofread: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            LumenActionButton(title: "Take Over", kind: .takeOver, animate: animate,
                demoCue: demoAction == .takeOver ? actionCue : .idle, help: "Let Sidekick take it from here", action: onTakeOver)
                .accessibilityIdentifier("notch.takeOver")
                .disabled(!inputReady)
            LumenActionButton(title: "Magic Reply", kind: .magicReply, animate: animate,
                demoCue: demoAction == .magicReply ? actionCue : .idle, help: "Your context. Your voice. A reply ready to review.", action: onMagicReply)
                .accessibilityIdentifier("notch.magicReply")
            Spacer(minLength: 0)
            LumenActionButton(title: "Summarize", kind: .utility, animate: animate,
                help: summarizeHelp, action: onSummarize)
                .accessibilityIdentifier("notch.summarize")
            LumenActionButton(title: "Proofread", kind: .utility, animate: animate,
                help: proofreadHelp, action: onProofread)
                .accessibilityIdentifier("notch.proofread")
                .disabled(!inputReady)
        }
        .disabled(!actionsEnabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LumenActionButton: View {
    enum Kind { case takeOver, magicReply, utility }
    let title: String
    let kind: Kind
    let animate: Bool
    var demoCue: OnboardingActionCue = .idle
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var active: Bool { (hovering && enabled) || demoCue.isHighlighted }
    private var motion: Bool { animate && !reduceMotion }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 15, style: .continuous) }

    private var spectrum: LinearGradient {
        LinearGradient(colors: GlowHalo.stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if kind == .takeOver {
                    LumenCursor(size: 13, lifted: active && motion, illuminated: active)
                        .frame(width: 15, height: 16)
                } else if kind == .magicReply {
                    Image(systemName: "touchid")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(active || contrast == .increased ? 0.95 : 0.66))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: kind == .utility ? 11 : 12,
                                  weight: kind == .takeOver ? .medium : .regular))
                    .foregroundStyle(.white.opacity(kind == .utility && !active && contrast != .increased ? 0.60 : 0.94))
                    .lineLimit(1).fixedSize()
                    .overlay(alignment: .bottom) {
                        if kind == .magicReply {
                            Rectangle().fill(.white.opacity(0.55))
                                .frame(height: 0.5)
                                .scaleEffect(x: active && !demoCue.isHighlighted ? 1 : 0, anchor: .leading)
                                .offset(y: 4).accessibilityHidden(true)
                        }
                    }
            }
            .padding(.horizontal, kind == .takeOver ? 13 : kind == .magicReply ? 6 : 4)
            .frame(height: 34)
            .background {
                if kind == .takeOver || kind == .magicReply {
                    shape.fill(Color(white: active ? 0.15 : 0.095))
                        .overlay {
                            shape.strokeBorder(LinearGradient(
                                stops: [.init(color: .white.opacity(contrast == .increased ? 0.75 : active ? 0.55 : 0.33), location: 0),
                                        .init(color: .white.opacity(0.09), location: 0.45),
                                        .init(color: .white.opacity(0.05), location: 1)],
                                startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                        }
                        .opacity(kind == .takeOver || demoCue.isHighlighted ? 1 : 0)
                        .overlay {
                            // A quiet wash and crisp spectrum rim share the actual button's shape.
                            // Blur radius is fixed: only opacity changes as light gathers and releases.
                            shape.fill(spectrum).opacity(demoCue.isHighlighted ? 0.20 : 0)
                            shape.strokeBorder(spectrum, lineWidth: 1.25)
                                .opacity(demoCue.isHighlighted ? 0.95 : 0)
                        }
                        .background {
                            shape.stroke(spectrum, lineWidth: 3)
                                .blur(radius: 6)
                                .opacity(demoCue.isHighlighted ? (demoCue.isPressed ? 0.40 : 0.72) : 0)
                        }
                } else if kind == .utility {
                    RoundedRectangle(cornerRadius: 7).fill(.white.opacity(active ? 0.045 : 0))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(LumenPressStyle(animate: motion, demonstrationPressed: demoCue.isPressed))
        .opacity(enabled ? 1 : 0.38)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .animation(motion ? .easeOut(duration: 0.22) : nil, value: active)
        .animation(.easeInOut(duration: motion ? 0.48 : 0.16), value: demoCue.isHighlighted)
        .accessibilityHint(help)
        .help(help)
    }
}

private struct LumenPressStyle: ButtonStyle {
    let animate: Bool
    var demonstrationPressed = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || demonstrationPressed
        configuration.label
            .scaleEffect(pressed && animate ? 0.955 : 1)
            .offset(y: pressed && animate ? 1 : 0)
            .opacity(pressed ? 0.86 : 1)
            .animation(animate ? (pressed ? .easeIn(duration: 0.13)
                : .spring(response: 0.30, dampingFraction: 0.65)) : .easeOut(duration: 0.12), value: pressed)
    }
}

/// The same cursor appears in Take Over's control and its active task status.
/// The small radial fill is static; only its opacity and the icon's position transition.
struct LumenCursor: View {
    var size: CGFloat = 15
    var lifted = false
    var illuminated = false

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(0.97))
            .offset(x: lifted ? 1.5 : 0, y: lifted ? -1.5 : 0)
            .background {
                Circle().fill(RadialGradient(colors: [.white.opacity(illuminated ? 0.16 : 0.07), .clear],
                                            center: .center, startRadius: 0, endRadius: size * 1.05))
                    .frame(width: size * 2.1, height: size * 2.1)
            }
            .accessibilityHidden(true)
    }
}


/// Fixed to the hardware sensor, not to the expanding shell. Static spectral light;
/// only the hover/open transition animates. No timer, repeated animation or shader.
struct NotchTapLocationGuide: View {
    var expanded: Bool
    var visible: Bool
    private let opal = LinearGradient(stops: [
        .init(color: Color(red: 0.31, green: 0.86, blue: 1).opacity(0), location: 0),
        .init(color: Color(red: 0.40, green: 0.85, blue: 1), location: 0.15),
        .init(color: Color(red: 0.88, green: 1, blue: 0.95), location: 0.44),
        .init(color: Color(red: 1, green: 0.97, blue: 0.85), location: 0.60),
        .init(color: Color(red: 1, green: 0.77, blue: 0.54), location: 0.82),
        .init(color: Color(red: 1, green: 0.74, blue: 0.53).opacity(0), location: 1)
    ], startPoint: .leading, endPoint: .trailing)
    private let handLight = LinearGradient(colors: [
        Color(red: 0.76, green: 0.94, blue: 1),
        Color(red: 0.92, green: 1, blue: 0.91),
        Color(red: 1, green: 0.90, blue: 0.71)
    ], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        ZStack(alignment: .top) {
            // Two small, static falloffs supply Opal's refraction without an animated
            // blur, drawing clock, or physical-tap listener. Only layout/opacity morph.
            ZStack {
                Circle().fill(RadialGradient(colors: [
                    Color(red: 0.28, green: 0.79, blue: 1).opacity(0.36), .clear
                ], center: .center, startRadius: 0, endRadius: 17))
                    .frame(width: 34, height: 34)
                    .scaleEffect(x: expanded ? 0.85 : 1, y: expanded ? 0.74 : 0.50)
                    .offset(x: expanded ? -5 : -8)
                Circle().fill(RadialGradient(colors: [
                    Color(red: 1, green: 0.72, blue: 0.40).opacity(0.38), .clear
                ], center: .center, startRadius: 0, endRadius: 17))
                    .frame(width: 34, height: 34)
                    .scaleEffect(x: expanded ? 0.85 : 1, y: expanded ? 0.74 : 0.50)
                    .offset(x: expanded ? 5 : 8)
            }
            .frame(width: expanded ? 29 : 34, height: expanded ? 25 : 17)
            .offset(y: expanded ? 0 : -7)
            .opacity(expanded ? 0.65 : 1)

            TapLocationChevron(progress: expanded ? 1 : 0)
                .stroke(expanded ? handLight : opal,
                    style: StrokeStyle(lineWidth: expanded ? 1.5 : 2, lineCap: .round, lineJoin: .round))
                .frame(width: expanded ? 12 : 24, height: expanded ? 6 : 2)
            Capsule().fill(LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                                          startPoint: .leading, endPoint: .trailing))
                .frame(width: 12, height: 0.75)
                .offset(y: 0.1)
                .scaleEffect(x: expanded ? 0.35 : 1, anchor: .center)
                .opacity(expanded ? 0 : 0.9)
            TapLocationFinger()
                .stroke(handLight, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 16)
                .offset(y: expanded ? 8 : 1)
                .scaleEffect(expanded ? 1 : 0.25, anchor: .top)
                .opacity(expanded ? 0.92 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(visible ? 1 : 0)
    }
}

private struct TapLocationChevron: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * progress))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * progress))
        return path
    }
}

/// A raised fingertip with a folded-hand outline, drawn so its tip shares the arrow's axis.
struct TapLocationFinger: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX+x*rect.width, y: rect.minY+y*rect.height)
        }
        path.move(to: point(0.34, 0.62))
        path.addLine(to: point(0.34, 0.15))
        path.addCurve(to: point(0.66, 0.15), control1: point(0.34,-0.05), control2: point(0.66,-0.05))
        path.addLine(to: point(0.66, 0.43))
        path.addCurve(to: point(0.94, 0.60), control1: point(0.85,0.43), control2: point(0.94,0.46))
        path.addLine(to: point(0.87, 0.88))
        path.addQuadCurve(to: point(0.73, 0.98), control: point(0.84,0.98))
        path.addLine(to: point(0.43, 0.98))
        path.addQuadCurve(to: point(0.27, 0.88), control: point(0.34,0.98))
        path.addLine(to: point(0.07, 0.62))
        path.addCurve(to: point(0.27, 0.53), control1: point(-0.04,0.47), control2: point(0.12,0.42))
        path.addLine(to: point(0.34, 0.62))
        return path
    }
}
