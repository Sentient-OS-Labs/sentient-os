//
//  OnboardingView.swift
//  Sentient OS macOS
//
//  First-launch onboarding: three intro slides (placeholder boxes for now — real design comes
//  later), then permissions (OnboardingPermissionsView), then codex login (OnboardingCodexSteps),
//  then the ready-to-process screen (OnboardingReadyView) whose Start Analysis presents the REAL
//  ProcessingView takeover (pausable) — and only a finished run calls `onFinished` and reveals
//  the home. The current step persists (UserDefaults "onboarding.step") so a quit-and-relaunch
//  mid-onboarding — which granting Full Disk Access requires — resumes exactly where the user
//  left. The background codex install is NOT here: AppState kicks it off 1s after launch while
//  the user reads the slides.
//

import SwiftUI

struct OnboardingView: View {
    let onFinished: () -> Void

    /// Persisted so a relaunch mid-onboarding (the FDA grant needs one) resumes at the same step.
    @AppStorage("onboarding.step") private var step = 0
    private static let slideCount = 3

    /// Start Analysis pressed — the ProcessingView takeover is up. Not persisted: a quit
    /// mid-run relaunches to the ready screen, and the durable marks resume the analysis.
    @State private var analyzing = false

    // The same run flags the home's Analyze Now reads (RootView).
    @AppStorage("dev.proactive.realCards") private var realCards = true
    @AppStorage("dbg.gmail.connected")     private var gmailConnected = false
    @AppStorage("dbg.run.gmail")           private var runGmail = false
    @AppStorage("dbg.calendar.connected")  private var calendarConnected = false
    @AppStorage("dbg.run.calendar")        private var runCalendar = false

    // Resolved at launch (env → bundle → App Support → repo root); nil = model not on this Mac.
    private static let modelPath = ModelLocator.resolve()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            switch step {
            case ..<Self.slideCount:
                slides.transition(.opacity)
            case Self.slideCount:
                OnboardingPermissionsView(onContinue: advance).transition(.opacity)
            case Self.slideCount + 1:
                OnboardingCodexLoginView(onContinue: advance).transition(.opacity)
            default:
                if analyzing, let modelPath = Self.modelPath {
                    // The REAL first analysis — the same engine + takeover as the home's Analyze
                    // Now, in pausable onboarding dress. Home appears only when this finishes.
                    ProcessingView(modelPath: modelPath,
                                   connectors: RunSource.connectors(from:
                                       SourceSelection.current(fdaGranted: Permissions.hasFullDiskAccess())),
                                   mode: .auto,
                                   runGmail: gmailConnected && runGmail,
                                   runCalendar: calendarConnected && runCalendar,
                                   fullCycle: realCards,
                                   pausable: true,
                                   onExitEarly: { withAnimation(.easeInOut(duration: 0.3)) { analyzing = false } },
                                   onDone: onFinished)
                        .transition(.opacity)
                } else {
                    OnboardingReadyView(modelMissing: Self.modelPath == nil) {
                        withAnimation(.easeInOut(duration: 0.3)) { analyzing = true }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
    }

    // MARK: The three intro slides (placeholders)

    private var slides: some View {
        VStack(spacing: 40) {
            Spacer()

            OnboardingWhisper("STEP \(step + 1) OF \(Self.slideCount)")

            // Placeholder for the real slide design.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1))
                .overlay(
                    Text("Intro slide \(step + 1)")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary))
                .frame(maxWidth: 560, maxHeight: 360)

            OnboardingNextButton(title: "Next", action: advance)

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
    }
}

/// The onboarding CTA — a quiet white capsule, shared by the slides and the permissions screen.
struct OnboardingNextButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? .black : .white.opacity(0.35))
                .padding(.horizontal, 36)
                .padding(.vertical, 12)
                .background(Capsule(style: .continuous)
                    .fill(enabled ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.3), value: enabled)
    }
}

/// The trust footer — on every onboarding surface, like everywhere else in the app.
struct OnboardingTrustFooter: View {
    var body: some View {
        Text("Private by design. Your files never leave this Mac.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .padding(.bottom, 28)
    }
}

#Preview("Onboarding — intro slides") {
    OnboardingView(onFinished: {})
        .frame(width: 1180, height: 880)
        .preferredColorScheme(.dark)
}
