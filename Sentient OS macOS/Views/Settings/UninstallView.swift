//
//  UninstallView.swift
//  Sentient OS macOS
//
//  The farewell sheet (Settings → System → Uninstall Sentient…). Four phases: the farewell
//  (the two-college-students note, Share Feedback via mailto, Keep Sentient, and the red
//  Uninstall), the working teardown (Uninstall.Stage whispers over a quiet spinner), the
//  helper-password interstitial (Enter Password / Skip / Cancel — shown only when the admin
//  prompt is declined), and the gone screen (drag Sentient to the Trash, then Quit via
//  Uninstall.finishAndQuit). Drives System/Uninstall.swift; the teardown itself lives there.
//

import SwiftUI

struct UninstallView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    fileprivate enum Phase { case farewell, working, helperPrompt, gone }
    @State private var phase: Phase = .farewell
    @State private var stage: Uninstall.Stage = .helper
    /// Fulfilled by the interstitial's buttons while the teardown awaits a helper decision.
    @State private var helperResolver: ((Uninstall.HelperChoice) -> Void)?

    init() {}

    /// Preview-only: open the sheet directly in a later phase.
    fileprivate init(previewPhase: Phase) { _phase = State(initialValue: previewPhase) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch phase {
                case .farewell:     farewell
                case .working:      working
                case .helperPrompt: helperPrompt
                case .gone:         gone
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 26)

            trustFooter
        }
        .frame(width: 470)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(phase != .farewell)   // mid-teardown there's no walking away
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    // MARK: - Phase 1 · the farewell

    private var farewell: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("Before you go", size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
            Text("Sorry to see you go.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("We are two college students who built Sentient in the open, because we believed your Mac could truly know you while keeping everything private. We are sad to see you leave, and we would genuinely love to hear what did not land for you.")
                .padding(.top, 14)
            prose("Uninstalling removes everything Sentient made on this Mac: the on-device model, your knowledge base, the private cloud copy your AIs read, the overnight wake helper, and every setting. Your own files are never touched.")
                .padding(.top, 10)
            HStack(spacing: 10) {
                feedbackButton
                Spacer()
                QuietPillButton(title: "Keep Sentient") { dismiss() }
                DangerPillButton(title: "Uninstall Sentient") { beginUninstall() }
            }
            .padding(.top, 24)
        }
    }

    // MARK: - Phase 2 · the teardown

    private var working: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps(stage.whisper, size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
                .id(stage)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: stage)
            Text("Taking Sentient apart, gently.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("Give us a moment. We are cleaning up after ourselves so nothing of ours is left behind.")
                .padding(.top, 14)
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.6))
                .padding(.top, 22)
        }
    }

    // MARK: - Phase 3 · the helper needs a password (only if the admin prompt was declined)

    private var helperPrompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("One more step", size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
            Text("This part needs your password.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("Sentient set up a small system helper so it could wake your Mac for the overnight run. macOS asks for your password to remove it; that is the same prompt you saw when it was installed. You can also skip it for now, and Sentient will still clear everything else.")
                .padding(.top, 14)
            HStack(spacing: 10) {
                QuietPillButton(title: "Cancel Uninstall") { helperResolver?(.cancel) }
                Spacer()
                QuietPillButton(title: "Skip for Now") { helperResolver?(.skip) }
                BrightPillButton(title: "Enter Password") { helperResolver?(.retry) }
            }
            .padding(.top, 24)
        }
    }

    // MARK: - Phase 4 · gone

    private var gone: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("All clear", size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
            Text("Sentient is gone from this Mac.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("Everything Sentient made here has been removed. To finish, drag the Sentient OS app from your Applications folder to the Trash. Thank you for giving us a try; it meant a lot to the two of us.")
                .padding(.top, 14)
            HStack(spacing: 10) {
                feedbackButton
                Spacer()
                QuietPillButton(title: "Show App in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                BrightPillButton(title: "Quit Sentient") { Uninstall.finishAndQuit() }
            }
            .padding(.top, 24)
        }
    }

    // MARK: - The run

    private func beginUninstall() {
        phase = .working
        stage = .helper
        Task { @MainActor in
            let finished = await Uninstall.run(
                appState: appState,
                progress: { stage = $0 },
                helperDecision: {
                    await withCheckedContinuation { cont in
                        phase = .helperPrompt
                        helperResolver = { choice in
                            helperResolver = nil
                            phase = .working
                            cont.resume(returning: choice)
                        }
                    }
                })
            phase = finished ? .gone : .farewell   // a cancel backs out with nothing removed
        }
    }

    // MARK: - Shared bits

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var feedbackButton: some View {
        Button {
            if let url = URL(string: "mailto:feedback@sentient-os.ai?subject=Sentient%20OS%20feedback") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "envelope").font(.system(size: 10))
                Text("Share feedback").font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.Ink.bright.opacity(0.9))
        }
        .buttonStyle(PressScaleStyle())
    }

    /// The same trust ribbon Settings rides — continuity to the very last screen.
    private var trustFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield").font(.system(size: 10.5)).foregroundStyle(Theme.Ink.label)
            Text("Private by design. Your files never leave this Mac.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.label)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }
}

/// QuietPillButton's destructive sibling — red ink on a faint red wash. Local on purpose:
/// Settings' small SettingsPillButton stays the pane-level danger affordance.
private struct DangerPillButton: View {
    let title: String
    let action: () -> Void
    private static let red = Color(red: 1.0, green: 0.36, blue: 0.36)

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Self.red)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Capsule().fill(Self.red.opacity(0.09)))
                .overlay(Capsule().strokeBorder(Self.red.opacity(0.42), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// The sheet's one primary affordance — a white capsule, GlowButton's calm cousin (no halo:
/// the glow is jewelry, and a farewell is not the place to wear it).
private struct BrightPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Capsule().fill(.white))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

#Preview("Farewell") { UninstallView() }
#Preview("Working") { UninstallView(previewPhase: .working) }
#Preview("Helper prompt") { UninstallView(previewPhase: .helperPrompt) }
#Preview("Gone") { UninstallView(previewPhase: .gone) }
