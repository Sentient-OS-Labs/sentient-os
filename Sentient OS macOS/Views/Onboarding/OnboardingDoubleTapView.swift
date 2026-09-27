//  OnboardingDoubleTapView.swift
//  Native Mail and Messages, a physical-feeling Command key, and the real caret spiral teach
//  Double Tap between the film's Sidekick and Under-the-hood scenes.
//  DoubleTapDemoInput connects only this key window to the coordinator's existing key monitor.
//  Doc: Documentation - Onboarding.md (this folder).

import AppKit
import CoreText
import SwiftUI

struct OnboardingDoubleTapView: View {
    /// nil lets previews run without creating AppState or starting global services.
    var coordinator: CommandCoordinator?
    let onContinue: () -> Void
    @State var demo = OnboardingDoubleTapDemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches SidekickScene.tsx's background headline: Instrument Serif 400, upright, 30 px
    /// at the desktop breakpoint. Load the bundled OFL font directly so previews and offline
    /// onboarding use the actual face without relying on a system-installed font.
    private static let instructionFont: Font = {
        guard let url = Bundle.main.url(forResource: "InstrumentSerif-Regular", withExtension: "ttf"),
              let provider = CGDataProvider(url: url as CFURL),
              let font = CGFont(provider) else {
            Log("Onboarding: could not load bundled Instrument Serif")
            return .system(size: 30, weight: .regular, design: .serif)
        }
        return Font(CTFontCreateWithGraphicsFont(font, 30, nil, nil))
    }()

    var body: some View {
        GeometryReader { geometry in
            let windowWidth = min(660, geometry.size.width - 96)
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 32)

                    sampleWindow
                        .frame(width: windowWidth, height: 440)
                        .scaleEffect(demo.windowVisible || reduceMotion ? 1 : 0.97)
                        .offset(y: demo.windowVisible || reduceMotion ? 0 : 16)
                        .opacity(demo.windowVisible ? 1 : 0)
                        .modifier(DemoEmailDeparture(progress: demo.sample == .email && !reduceMotion ? demo.emailDeparture : 0,
                                                     viewport: geometry.size))
                        .accessibilityHidden(!demo.windowVisible || demo.emailDeparture > 0)

                    VStack(spacing: 16) {
                        Text("Double tap right command key")
                            .font(Self.instructionFont)
                            .foregroundStyle(.white)
                            .opacity(demo.instructionVisible ? (demo.phase == .waiting ? 1 : 0.42) : 0)
                            .animation(.easeOut(duration: 0.3), value: demo.instructionVisible)
                            .animation(.easeOut(duration: 0.35), value: demo.phase)
                            .accessibilityHidden(!demo.instructionVisible)

                        DemoCommandKey(pressed: demo.keyIsDown, inviting: demo.phase == .waiting,
                                       reduceMotion: reduceMotion, action: demo.draft)
                            .disabled(demo.phase != .waiting)
                            .opacity(demo.controlsVisible ? (demo.phase == .complete ? 0.55 : 1) : 0)
                            .animation(.easeOut(duration: 0.35), value: demo.phase)
                            .accessibilityHidden(!demo.controlsVisible)
                    }
                    .padding(.top, 26)

                    ZStack {
                        Text("Your replies, drafted instantly with two taps")
                            .font(Self.instructionFont)
                            .foregroundStyle(.white)
                            .opacity(demo.completionVisible ? 1 : 0)
                            .accessibilityHidden(!demo.completionVisible)

                        DemoNextSampleButton(action: demo.showMessages)
                            .disabled(!demo.nextVisible)
                            .opacity(demo.nextVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.3), value: demo.nextVisible)
                            .accessibilityHidden(!demo.nextVisible)
                    }
                    .padding(.top, 24)

                    // Reserve the exact space from the first frame. Revealing Continue never
                    // moves the windows, changes their line wraps, or shifts the user's gaze.
                    OnboardingNextButton(title: "Continue", enabled: demo.continueVisible, action: onContinue)
                        .padding(.top, 22)
                        .opacity(demo.continueVisible ? 1 : 0)
                        .allowsHitTesting(demo.continueVisible)
                        .accessibilityHidden(!demo.continueVisible)

                    Spacer(minLength: 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(DoubleTapDemoCaretAnchor.self) { anchor in
                    GeometryReader { overlay in
                        let caret = anchor.map { overlay[$0] }
                            ?? CGRect(x: overlay.size.width / 2, y: overlay.size.height / 2, width: 1, height: 18)
                        CaretSwirlView(model: demo.swirl)
                            .frame(width: max(overlay.size.width, SwirlMath.canvasSide),
                                   height: max(overlay.size.height, SwirlMath.canvasSide))
                            .position(demo.spiralAtCaret
                                      ? CGPoint(x: caret.midX, y: caret.midY)
                                      : CGPoint(x: overlay.size.width / 2, y: overlay.size.height / 2))
                            .opacity(demo.spiralVisible && !reduceMotion ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if demo.continueVisible {
                    DoubleTapInferenceInfo()
                        .padding(24)
                        .transition(.opacity)
                }
            }
            .clipped()
            .onAppear {
                // Begin beyond the edges of the whole window. Only the orbit expands; the
                // original comet strokes stay fine as the light gathers into the reply field.
                demo.start(reduceMotion: reduceMotion,
                           entranceRadius: Double(max(geometry.size.width, geometry.size.height)) * 0.78)
            }
        }
        .background {
            if let coordinator {
                DoubleTapDemoInput(coordinator: coordinator, onKeyChange: { demo.keyChanged($0) },
                                   onFocusLost: demo.resetGesture)
            }
        }
        .onChange(of: reduceMotion) { demo.setReduceMotion(reduceMotion) }
        .onDisappear { demo.stop() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var sampleWindow: some View {
        switch demo.sample {
        case .email:
            DoubleTapDemoEmailWindow(replied: demo.replyVisible, waiting: demo.phase == .waiting,
                                    reduceMotion: reduceMotion)
        case .message:
            DoubleTapDemoMessageWindow(replied: demo.replyVisible, waiting: demo.phase == .waiting,
                                      reduceMotion: reduceMotion)
        }
    }
}

/// The final beat's quiet disclosure, placed above the icon without moving the lesson.
private struct DoubleTapInferenceInfo: View {
    @State private var hovering = false
    @State private var expanded = false

    private static let text = """
    Due to latency requirements, Double Tap uses the OpenAI API with Zero Data Retention for maximum privacy.
    We’re covering the cost for all our first users :)
    If you’d like, in Double Tap settings, you can change the inference provider to your own.
    """

    private var shown: Bool { hovering || expanded }

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(shown ? 0.8 : 0.4))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("About Double Tap inference")
        .accessibilityHint(Self.text)
        .overlay(alignment: .bottomLeading) {
            if shown {
                Text(Self.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 310, alignment: .leading)
                    .padding(16)
                    .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                    .offset(y: -40)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: shown)
        .onExitCommand {
            hovering = false
            expanded = false
        }
    }
}

/// A quiet secondary action; the bright Continue remains reserved for finishing both demos.
private struct DemoNextSampleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("Next").font(.system(size: 13, weight: .medium))
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.5))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Next: iMessage demo")
    }
}

/// One animated progress value follows a cubic arc, rather than interpolating two offsets
/// along a straight diagonal. It starts with a small rightward scoop, then accelerates upward,
/// lifting the right edge as the email leaves through the top-right of the window.
private struct DemoEmailDeparture: GeometryEffect {
    var progress: CGFloat
    let viewport: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = min(max(progress, 0), 1)
        let u = 1 - t
        let x = viewport.width * (3 * u * u * t * 0.26 + 3 * u * t * t * 0.52 + t * t * t * 0.66)
        let y = viewport.height * (3 * u * u * t * 0.08 - 3 * u * t * t * 0.38 - t * t * t * 1.05)
        let tilt = -CGFloat.pi / 10 * t * t
        let scale = 1 - 0.07 * t
        let transform = CGAffineTransform(translationX: size.width / 2 + x, y: size.height / 2 + y)
            .rotated(by: tilt)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

private struct DemoCommandKey: View {
    let pressed: Bool
    let inviting: Bool
    let reduceMotion: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !inviting || reduceMotion)) { context in
                let breath = inviting ? (reduceMotion ? 0.5 : 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * .pi * 2 / 2.6)) : 0
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(.white.opacity(0.035 + breath * 0.035))
                        .blur(radius: 13)
                        .padding(-7)

                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(white: 0.06))
                        .offset(y: 4)

                    VStack(alignment: .trailing, spacing: 8) {
                        Image(systemName: "command")
                            .font(.system(size: 27, weight: .regular))
                        Text("command")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(pressed ? 1 : 0.72 + breath * 0.18))
                    .frame(width: 96, height: 73)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color(white: pressed ? 0.14 : 0.105), Color(white: 0.055)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.5 : 0.2 + breath * 0.12), .white.opacity(0.08)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: pressed ? 1 : 3, y: pressed ? 0 : 3)
                    .offset(y: pressed && !reduceMotion ? 3 : 0)
                    .scaleEffect(pressed && !reduceMotion ? 0.985 : 1)
                }
                .frame(width: 96, height: 77)
            }
            .animation(reduceMotion ? nil : .spring(duration: pressed ? 0.1 : 0.2, bounce: pressed ? 0 : 0.12),
                       value: pressed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Try Double Tap")
        .accessibilityHint("Double tap the right Command key, or activate this button to fill the sample reply.")
    }
}

/// Reuses the app's modifier monitor; no additional keyboard listener or permission prompt.
private struct DoubleTapDemoInput: NSViewRepresentable {
    let coordinator: CommandCoordinator
    let onKeyChange: (Bool) -> Void
    let onFocusLost: () -> Void

    func makeNSView(context: Context) -> InputView {
        InputView(coordinator: coordinator, onKeyChange: onKeyChange, onFocusLost: onFocusLost)
    }
    func updateNSView(_ view: InputView, context: Context) {}
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.detach() }

    final class InputView: NSView {
        let coordinator: CommandCoordinator
        let onKeyChange: (Bool) -> Void
        let onFocusLost: () -> Void
        private let sessionID = UUID()
        private var observer: NSObjectProtocol?

        init(coordinator: CommandCoordinator, onKeyChange: @escaping (Bool) -> Void, onFocusLost: @escaping () -> Void) {
            self.coordinator = coordinator
            self.onKeyChange = onKeyChange
            self.onFocusLost = onFocusLost
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            coordinator.armOnboardingDoubleTapDemo(id: sessionID, in: window, onKeyChange: onKeyChange)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocusLost() }
            }
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            coordinator.disarmOnboardingDoubleTapDemo(id: sessionID)
            onFocusLost()
        }
    }
}

#if DEBUG
#Preview("Double Tap · entrance") {
    OnboardingDoubleTapView(onContinue: {})
        .frame(width: 1180, height: 880)
}

#Preview("Double Tap · ready") {
    OnboardingDoubleTapView(onContinue: {}, demo: .preview())
        .frame(width: 1180, height: 880)
}

#Preview("Double Tap · Messages") {
    OnboardingDoubleTapView(onContinue: {}, demo: .preview(sample: .message))
        .frame(width: 1180, height: 880)
}

#Preview("Double Tap · email ready for Next") {
    OnboardingDoubleTapView(onContinue: {}, demo: .preview(completed: true))
        .frame(width: 1040, height: 800)
}

#Preview("Double Tap · email throw") {
    OnboardingDoubleTapView(onContinue: {}, demo: .preview(completed: true, departure: 0.45))
        .frame(width: 1180, height: 880)
}

#Preview("Double Tap · complete, minimum window") {
    OnboardingDoubleTapView(onContinue: {}, demo: .preview(sample: .message, completed: true))
        .frame(width: 1040, height: 800)
}
#endif
