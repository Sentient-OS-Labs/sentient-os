//
//  OnboardingView.swift
//  Sentient OS macOS
//
//  First-launch onboarding: three intro slides (placeholder boxes for now — real design comes
//  later), then permissions (OnboardingPermissionsView), then codex login (OnboardingCodexSteps),
//  then the plan crossroads (OnboardingPlanView — free/go accounts only; full plans skip it),
//  then the ready-to-process screen (OnboardingReadyView) whose Start Analysis presents the REAL
//  ProcessingView takeover (pausable) — and only a finished run calls `onFinished` and reveals
//  the home. The current step persists (UserDefaults "onboarding.step") so a quit-and-relaunch
//  mid-onboarding — which granting Full Disk Access requires — resumes exactly where the user
//  left. The background codex install is NOT here: AppState kicks it off 1s after launch while
//  the user reads the slides. Computer use (codex step 3) IS here: Start Analysis arms a silent
//  one-shot that bootstraps it 2 minutes into the first analysis (armComputerUseSetup).
//

import SwiftUI

struct OnboardingView: View {
    let onFinished: () -> Void

    /// For the DEBUG skip handle only — the quiet flag flip, no finale.
    @Environment(AppState.self) private var appState

    /// Persisted so a relaunch mid-onboarding (the FDA grant needs one) resumes at the same step.
    @AppStorage("onboarding.step") private var step = 0
    private static let slideCount = 3

    /// Start Analysis pressed — the ProcessingView takeover is up. Not persisted: a quit
    /// mid-run relaunches to the ready screen, and the durable marks resume the analysis.
    @State private var analyzing = false

    /// One-shot: the deferred background computer-use setup (codex step 3) has been armed this
    /// launch, so a pause → resume never spawns a second timer.
    @State private var computerUseArmed = false

    // The same run flags the home's Analyze Now reads (RootView).
    @AppStorage(BriefingDeck.key) private var deckRaw = BriefingDeck.defaultRaw
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
            case Self.slideCount + 2:
                // The plan crossroads — free/go accounts decide here; full plans skip it
                // before it renders (OnboardingPlanView auto-advances).
                OnboardingPlanView(onContinue: advance).transition(.opacity)
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
                                   fullCycle: BriefingDeck(rawValue: deckRaw) == .real,
                                   pausable: true,
                                   onExitEarly: { withAnimation(.easeInOut(duration: 0.3)) { analyzing = false } },
                                   onDone: onFinished)
                        .transition(.opacity)
                } else {
                    OnboardingReadyView(modelMissing: Self.modelPath == nil) {
                        withAnimation(.easeInOut(duration: 0.3)) { analyzing = true }
                        armComputerUseSetup()
                    }
                    .transition(.opacity)
                }
            }
        }
        // A quiet back door on every screen but the first (and never over the analysis takeover,
        // which owns its own pause/exit). One shared code path, so every step gets it for free.
        .overlay(alignment: .topLeading) {
            if step > 0 && !analyzing {
                OnboardingBackButton(action: goBack)
                    .padding(.top, 24)
                    .padding(.leading, 24)
                    .transition(.opacity)
            }
        }
        // DEV-ONLY: skip straight to the home (testing relaunches land back in onboarding until
        // a full first analysis flips the flag). Quietly marks onboarding complete — deliberately
        // NOT onFinished, so the Constellation finale stays reserved for the real finish.
        // Compile-gated out of Release entirely.
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if !analyzing {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { appState.hasCompletedOnboarding = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "forward.end").font(.system(size: 8.5))
                        Text("SKIP TO HOME")
                            .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.6)
                    }
                    .foregroundStyle(Theme.Ink.deepMuted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .padding(.trailing, 22).padding(.bottom, 13)
                .transition(.opacity)
            }
        }
        #endif
    }

    /// Two minutes into the first analysis, bootstrap codex computer use (setup step 3) silently
    /// in the background — so it's ready by the time the home's cards and Sidekick need it, with
    /// no onboarding screen of its own. An unstructured Task on purpose: pausing or exiting the
    /// analysis must NOT cancel a DMG download mid-flight. setupComputerUse() self-guards (no-op
    /// when already bootstrapped, requires the codex binary), so a quit-and-relaunch that restarts
    /// the analysis just re-arms harmlessly; failures land in the log + Sentry, never in the UI.
    private func armComputerUseSetup() {
        guard !computerUseArmed else { return }
        computerUseArmed = true
        Task {
            try? await Task.sleep(for: .seconds(120))
            Log("Onboarding: 2 min into first analysis — starting background computer-use setup")
            await CodexSetup.shared.setupComputerUse()
        }
    }

    private func advance() {
        withAnimation(.easeInOut(duration: 0.25)) { step += 1 }
    }

    private func goBack() {
        var target = step - 1
        // The crossroads only exists for free/go accounts — never strand a full plan on an
        // auto-advancing screen (back would visibly bounce forward again).
        if target == Self.slideCount + 2 && !CodexAuth.isLimited() { target -= 1 }
        withAnimation(.easeInOut(duration: 0.25)) { step = max(0, target) }
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

/// The subtle onboarding back door — a small arrow + "Back", top-left on every screen but the
/// first. Quiet by default, brightening on hover, so it never competes with the screen's CTA.
struct OnboardingBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back")
                    .font(.system(size: 13))
            }
            .foregroundStyle(hovering ? Theme.secondary : Theme.faint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
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
