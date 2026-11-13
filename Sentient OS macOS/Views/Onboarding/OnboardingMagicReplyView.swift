//  OnboardingMagicReplyView.swift
//  One native email teaches Magic Reply after the film's Take Over scene.
//  A physical notch tap demonstrates Magic Reply, then the caret spiral lands a local draft.
//  MagicReplyDemoInput owns the sensor lesson only while its sample is ready.
//  Doc: Documentation - Onboarding.md (this folder).

import AppKit
import SwiftUI

struct OnboardingMagicReplyView: View {
    /// nil lets previews run without creating AppState or starting global services.
    var coordinator: CommandCoordinator?
    let onContinue: () -> Void
    @State var demo = OnboardingMagicReplyDemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var choosingAction: Bool {
        coordinator?.onboardingDemoArmed == true && coordinator?.phase == .typing
    }
    private var physicalTapAvailable: Bool { OnboardingNotchPointer.hasPhysicalTarget }
    private var instructionTitle: String {
        switch demo.phase {
        case .waiting: choosingAction ? "Magic Reply" : "Tap your notch again"
        case .drafting: "Writing in your voice…"
        case .complete: ""
        default: "Tap your notch again"
        }
    }

    private func openDemo() {
        guard demo.phase == .waiting else { return }
        if let coordinator { coordinator.openNotchFromHome() }
        else { demo.draft() }
    }

    var body: some View {
        GeometryReader { geometry in
            let windowWidth = min(660, geometry.size.width - 96)
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 10)

                    MagicReplyDemoEmailWindow(replied: demo.replyVisible, waiting: demo.phase == .waiting,
                                              reduceMotion: reduceMotion)
                        .frame(width: windowWidth, height: 440)
                        .scaleEffect(!demo.windowVisible && !reduceMotion ? 0.97 : 1)
                        .offset(y: !demo.windowVisible && !reduceMotion ? 16 : 0)
                        .opacity(demo.windowVisible ? 1 : 0)
                        .accessibilityHidden(!demo.windowVisible)

                    ZStack {
                        if demo.phase == .waiting && !physicalTapAvailable && !choosingAction {
                            Button("Try Magic Reply", action: openDemo)
                                .buttonStyle(PressScaleStyle())
                                .padding(.horizontal, 22).padding(.vertical, 8)
                                .background(.white.opacity(0.09), in: Capsule())
                                .accessibilityIdentifier("onboarding.magicReply.fallback")
                        } else {
                            Text(instructionTitle)
                                .accessibilityIdentifier("onboarding.magicReply.instruction")
                                .transaction { $0.animation = nil }
                        }
                    }
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                        .opacity(demo.instructionVisible ? 1 : 0)
                        .accessibilityHidden(!demo.instructionVisible)
                        .animation(.easeOut(duration: 0.18), value: demo.instructionVisible)
                        .animation(.easeOut(duration: 0.35), value: demo.phase)
                        .frame(width: windowWidth, height: 38)
                        .padding(.top, 16)

                    // The sensor reminder yields to the only exit: Continue, after the draft.
                    ZStack(alignment: .top) {
                        if demo.phase == .waiting && physicalTapAvailable && !choosingAction {
                            OnboardingNotchTapIllustration().transition(.opacity)
                        }
                        if demo.continueVisible {
                            OnboardingNextButton(title: "Continue", action: onContinue)
                                .padding(.top, 24)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: min(480, windowWidth), height: 224, alignment: .top)
                    .animation(.easeOut(duration: 0.3), value: demo.phase)
                    .animation(.easeOut(duration: 0.2), value: choosingAction)
                    .padding(.top, 8)

                    Spacer(minLength: 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlayPreferenceValue(MagicReplyDemoCaretAnchor.self) { anchor in
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
                MagicReplyDemoInput(coordinator: coordinator, ready: demo.phase == .waiting,
                                    onFired: { demo.draft() })
            }
        }
        .onChange(of: reduceMotion) { demo.setReduceMotion(reduceMotion) }
        .onDisappear { demo.stop() }
        .preferredColorScheme(.dark)
    }

}

/// Own the inert notch lesson for this window's lifetime. Sample readiness gates the
/// physical sensor; leaving or replacing this view cancels only its own animation.
private struct MagicReplyDemoInput: NSViewRepresentable {
    let coordinator: CommandCoordinator
    let ready: Bool
    let onFired: () -> Void

    func makeNSView(context: Context) -> InputView {
        InputView(coordinator: coordinator, ready: ready, onFired: onFired)
    }
    func updateNSView(_ view: InputView, context: Context) { view.configure(ready: ready, onFired: onFired) }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.detach() }

    final class InputView: NSView {
        let coordinator: CommandCoordinator
        private let sessionID = UUID()
        private var registered = false
        private var ready: Bool
        private var onFired: () -> Void

        init(coordinator: CommandCoordinator, ready: Bool, onFired: @escaping () -> Void) {
            self.coordinator = coordinator; self.ready = ready; self.onFired = onFired
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(ready: Bool, onFired: @escaping () -> Void) {
            let changed = self.ready != ready
            self.ready = ready; self.onFired = onFired
            if registered && changed { coordinator.setOnboardingNotchDemoReady(ready, id: sessionID) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            registered = true
            coordinator.armOnboardingNotchDemo(id: sessionID, in: window, action: .magicReply,
                                               ready: ready) { [weak self] in self?.onFired() }
        }
        func detach() {
            guard registered else { return }
            registered = false
            coordinator.disarmOnboardingNotchDemo(id: sessionID)
        }
    }
}

#if DEBUG
#Preview("Magic Reply · entrance") {
    OnboardingMagicReplyView(onContinue: {}).frame(width: 1180, height: 880)
}
#Preview("Magic Reply · waiting") {
    OnboardingMagicReplyView(onContinue: {}, demo: .preview()).frame(width: 1180, height: 880)
}
#Preview("Magic Reply · email ready") {
    OnboardingMagicReplyView(onContinue: {}, demo: .preview(completed: true)).frame(width: 1040, height: 800)
}
#endif
