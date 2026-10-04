//  OnboardingDoubleTapView.swift
//  Native Mail and Messages, a face-on keyboard invitation, and the real caret spiral teach
//  Double Tap after the film's Sidekick scene, before frontier-model selection.
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
            let flightProgress = reduceMotion ? 0 : (demo.sample == .email ? demo.emailDeparture : 1 - demo.messageArrival)
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 10)

                    sampleWindow
                        .frame(width: windowWidth, height: demo.sample == .message ? 350 : 440)
                        .scaleEffect(demo.sample == .email && !demo.windowVisible && !reduceMotion ? 0.97 : 1)
                        .offset(y: demo.sample == .email && !demo.windowVisible && !reduceMotion ? 16 : 0)
                        .opacity(demo.sample == .message && !reduceMotion ? 1 : (demo.windowVisible ? 1 : 0))
                        .modifier(DemoWindowFlight(progress: flightProgress,
                                                   side: demo.sample == .email ? .right : .left,
                                                   viewport: geometry.size))
                        .accessibilityHidden(!demo.windowVisible || demo.emailDeparture > 0)
                        // Both windows occupy the same stage. Messages is shorter within it,
                        // so changing samples cannot move the instruction or keyboard below.
                        .frame(height: 440)

                    Text("Double tap your right command key")
                        .font(Self.instructionFont)
                        .foregroundStyle(.white)
                        .opacity(demo.instructionVisible ? (demo.phase == .waiting ? 1 : 0.42) : 0)
                        .accessibilityHidden(!demo.instructionVisible)
                        .animation(.easeOut(duration: 0.18), value: demo.instructionVisible)
                        .animation(.easeOut(duration: 0.35), value: demo.phase)
                        .frame(width: windowWidth, height: 38)
                        .overlay(alignment: .bottom) {
                            // The completion copy uses the space freed above this fixed row
                            // by the shorter Messages window. It never adds layout height.
                            VStack(spacing: 10) {
                                Text("Your replies, drafted instantly with two taps")
                                    .font(Self.instructionFont)
                                    .foregroundStyle(.white)
                                personalContextLine
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(demo.completionVisible ? 1 : 0)
                            .accessibilityHidden(!demo.completionVisible)
                            .animation(.easeOut(duration: 0.4), value: demo.completionVisible)
                        }
                        .padding(.top, 16)

                    OnboardingDoubleTapKeyboard(pressed: demo.keyIsDown, inviting: demo.phase == .waiting,
                                                reduceMotion: reduceMotion, tapFeedback: demo.tapFeedback,
                                                action: { demo.clicked() })
                        .disabled(demo.phase != .waiting)
                        .opacity(demo.controlsVisible ? (demo.phase == .complete ? 0.55 : 1) : 0)
                        .animation(.easeOut(duration: 0.35), value: demo.phase)
                        .accessibilityHidden(!demo.controlsVisible)
                        .padding(.top, 12)

                    // Both actions occupy the same reserved row, leaving room for the keyboard
                    // at the minimum window size without shrinking or shifting the sample reply.
                    ZStack {
                        DemoNextSampleButton(action: demo.showMessages)
                            .disabled(!demo.nextVisible)
                            .opacity(demo.nextVisible ? 1 : 0)
                            .animation(.easeOut(duration: 0.3), value: demo.nextVisible)
                            .accessibilityHidden(!demo.nextVisible)

                        HStack(spacing: 12) {
                            // Balance the info button so Continue stays centered on the lesson.
                            Color.clear.frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                            OnboardingNextButton(title: "Continue", enabled: demo.continueVisible, action: onContinue)
                            DoubleTapInferenceInfo()
                        }
                        .opacity(demo.continueVisible ? 1 : 0)
                        .disabled(!demo.continueVisible)
                        .allowsHitTesting(demo.continueVisible)
                        .accessibilityHidden(!demo.continueVisible)
                    }
                    .frame(height: 44)
                    .padding(.top, 14)

                    Spacer(minLength: 10)
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

    private var personalContextLine: some View {
        Text("From your entire personal context")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                HStack(spacing: -12) {
                    ForEach([0, 1, 3, 4, 6], id: \.self) { index in
                        Circle()
                            .fill(RadialGradient(colors: [GlowHalo.stops[index].opacity(0.32), .clear],
                                                 center: .center, startRadius: 0, endRadius: 32))
                            .frame(width: 64, height: 64)
                            .scaleEffect(x: 1.35, y: 0.7)
                    }
                }
                    .frame(height: 32)
                    .accessibilityHidden(true)
            }
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

/// Hover for a quick explanation, or click to keep a native popover open for reading.
private struct DoubleTapInferenceInfo: View {
    @State private var hovering = false
    @State private var showingPopover = false

    private static let text = PrivacyCopy.doubleTapInfo

    var body: some View {
        Button {
            hovering = false
            showingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(hovering || showingPopover ? 0.8 : 0.5))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("About Double Tap inference")
            .accessibilityHint("Learn how drafts are processed and how to choose a provider in Settings.")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                explanation
                    .textSelection(.enabled)
                    .padding(16)
                    .preferredColorScheme(.dark)
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering && !showingPopover {
                    explanation
                        .padding(16)
                        .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                        .offset(y: -40)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var explanation: some View {
        Text(Self.text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.8))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 310, alignment: .leading)
    }
}

/// The first demo's primary action, as prominent as the final Continue.
private struct DemoNextSampleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text("Next").font(.system(size: 15, weight: .semibold))
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(Capsule().fill(.white.opacity(hovering ? 0.9 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel("Next: iMessage demo")
    }
}

/// One cubic arc for both windows: email flies out to the top-right; Messages follows the
/// mirrored path in reverse from the top-left, including the same tilt and change in scale.
/// Zero is the resting position and one is fully outside the viewport.
private struct DemoWindowFlight: GeometryEffect {
    enum Side { case left, right }
    var progress: CGFloat
    let side: Side
    let viewport: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = min(max(progress, 0), 1)
        let u = 1 - t
        let direction: CGFloat = side == .right ? 1 : -1
        let x = direction * viewport.width * (3 * u * u * t * 0.26 + 3 * u * t * t * 0.52 + t * t * t * 0.66)
        let y = viewport.height * (3 * u * u * t * 0.08 - 3 * u * t * t * 0.38 - t * t * t * 1.05)
        let tilt = -direction * CGFloat.pi / 10 * t * t
        let scale = 1 - 0.07 * t
        let transform = CGAffineTransform(translationX: size.width / 2 + x, y: size.height / 2 + y)
            .rotated(by: tilt)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
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

#Preview("Double Tap · Messages curved entrance") {
    OnboardingDoubleTapView(onContinue: {}, demo: .preview(sample: .message, arrival: 0.45))
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
