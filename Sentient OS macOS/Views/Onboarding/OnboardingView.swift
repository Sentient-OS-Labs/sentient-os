//
//  OnboardingView.swift
//  Sentient OS macOS
//
//  First-launch onboarding: the film slide (OnboardingFilmView — the website's self-scrolling
//  film in a webview, parking on the morning home),
//  then permissions (OnboardingPermissionsView), then codex login (OnboardingCodexSteps),
//  then the plan crossroads (OnboardingPlanView — free/go accounts only; full plans skip it),
//  then the ready-to-process screen (OnboardingReadyView) whose Start Analysis presents the REAL
//  ProcessingView takeover (pausable) — and only a finished run calls `onFinished` and reveals
//  the home. If the on-device model hasn't finished downloading (ModelDownload — AppState kicks
//  it 2s after the post-FDA-relaunch launch), Start Analysis shows the downloading-model screen
//  first and the analysis takes over by itself the moment the model verifies. The current step
//  persists (UserDefaults "onboarding.step") so a quit-and-relaunch mid-onboarding — which
//  granting Full Disk Access requires — resumes exactly where the user left. The background
//  codex install is NOT here: AppState kicks it off 1s after launch while the film plays.
//  Computer use (codex step 3) IS here: the analysis takeover appearing arms a silent
//  one-shot that bootstraps it 2 minutes in (armComputerUseSetup) — armed at analysis start,
//  not at Start Analysis, so its ~535 MB DMG never competes with the model download's tail.
//

import SwiftUI

struct OnboardingView: View {
    let onFinished: () -> Void

    /// For the DEBUG skip handle only — the quiet flag flip, no finale.
    @Environment(AppState.self) private var appState

    /// Persisted so a relaunch mid-onboarding (the FDA grant needs one) resumes at the same step.
    @AppStorage("onboarding.step") private var step = 0

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

    /// The onboarding model download (AppState kicks it post-FDA-relaunch; the downloading
    /// screen renders it). Held here so this body observes its phase.
    @State private var download = ModelDownload.shared

    /// Keeps the screen on for ALL of onboarding — the model download runs behind the slides
    /// and the first analysis takes hours; idle-sleep would kill both. Held for this view's
    /// whole lifetime (see body), released when the home replaces onboarding.
    @State private var awake = DisplayAwake()

    /// Live model path (env → bundle → App Support → repo root); nil = not on this Mac YET.
    /// Reading the download phase first makes SwiftUI re-evaluate this body when the download
    /// verifies, so the path flips non-nil in place and the analysis takes over by itself (the
    /// old `static let` would have needed an app relaunch to notice the freshly-landed model).
    private var modelPath: String? {
        _ = download.phase
        return ModelLocator.resolve()
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            switch step {
            case 0:
                // Step 1 is the website's film in a webview — it plays to the morning-home
                // rest and blooms its own Continue (OnboardingFilmView owns the choreography).
                OnboardingFilmView(onContinue: advance).transition(.opacity)
            case 1:
                OnboardingPermissionsView(onContinue: advance).transition(.opacity)
            case 2:
                OnboardingCodexLoginView(onContinue: advance).transition(.opacity)
            case 3:
                // The plan crossroads — free/go accounts decide here; full plans skip it
                // before it renders (OnboardingPlanView auto-advances).
                OnboardingPlanView(onContinue: advance).transition(.opacity)
            default:
                if analyzing, let modelPath {
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
                        .onAppear(perform: armComputerUseSetup)
                } else if analyzing {
                    // Start Analysis outran the model download — the honest wait, never a dead
                    // button. The `modelPath` read above re-resolves when the phase flips, so
                    // this hands off to the analysis on its own.
                    OnboardingModelDownloadView(download: download)
                        .transition(.opacity)
                } else {
                    OnboardingReadyView {
                        withAnimation(.easeInOut(duration: 0.3)) { analyzing = true }
                    }
                    .transition(.opacity)
                }
            }
        }
        // The whole-onboarding display hold: slides → permissions → codex login → downloads →
        // analysis → finale, pauses included. The FDA quit-and-relaunch re-begins on remount;
        // the DEBUG skip and the real finish both release via onDisappear when RootView swaps
        // to home. (ProcessingView's own hold covers home-launched first ingests; during
        // onboarding the two overlap harmlessly — independent tokens.)
        .onAppear { awake.begin(reason: "Onboarding — keeping the screen on") }
        .onDisappear { awake.end() }
        // No right-clicks anywhere in onboarding — the film's webview would offer a browser
        // context menu (Reload…), and no onboarding surface has a legitimate right-click.
        // Window-scoped, gone with this view.
        .background(RightClickBlocker())
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
        // The GitHub mark in the window's absolute top-right corner — the open-source receipt on
        // every onboarding screen, the film included; only the takeover is kept clean. The
        // flexible frame + ignoresSafeArea pins it past the title-bar inset to the true corner.
        .overlay(alignment: .topTrailing) {
            if !analyzing {
                OnboardingGitHubButton()
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        // DEV-ONLY: skip straight to the home (testing relaunches land back in onboarding until
        // a full first analysis flips the flag). Quietly marks onboarding complete — deliberately
        // NOT onFinished, so the Constellation finale stays reserved for the real finish.
        // Compile-gated out of Release entirely. Hidden on step 0 (the film webview) — the film
        // is meant to read as a native screen, not a page with dev chrome floating over it.
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if !analyzing && step > 0 {
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
    /// no onboarding screen of its own. Armed when the analysis takeover APPEARS (not at Start
    /// Analysis), so its ~535 MB DMG never races the model download still finishing behind the
    /// downloading screen. An unstructured Task on purpose: pausing or exiting the
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
        if target == 3 && !CodexAuth.isLimited() { target -= 1 }
        withAnimation(.easeInOut(duration: 0.25)) { step = max(0, target) }
    }

}

/// The onboarding CTA — a quiet white capsule, shared across the onboarding screens.
/// `glow` adds the rotating AI-gradient halo (GlowHalo intensity) — off by default, reserved
/// for the one deliberate jewelry moment (the film's hood-park Continue).
struct OnboardingNextButton: View {
    let title: String
    var enabled: Bool = true
    var glow: Double = 0
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
        .background { if glow > 0 { GlowHalo(active: enabled, intensity: glow) } }
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

/// The onboarding GitHub mark — top-right on every screen the back button lives on, opening the
/// public repo. Quiet by default, brightening on hover, so it reads as chrome, never a CTA.
struct OnboardingGitHubButton: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/Sentient-OS-Labs/sentient-os")!)
        } label: {
            Image("GitHubMark")
                .resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(hovering ? Theme.secondary : Theme.faint)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .help("Sentient OS on GitHub")
    }
}

/// Swallows right-clicks in the window hosting onboarding, for onboarding's whole lifetime.
/// The film's webview serves WebKit's context menu (Reload Page restarts the film), and no
/// onboarding screen has a legitimate right-click — so the event is eaten at the door.
/// Window-scoped on purpose: other windows (dev tools, the notch) keep theirs. The local
/// monitor installs on view-did-move-to-window (post-launch — never during app init, the
/// notch lesson) and dies with the view. Ctrl-click menus are covered separately by
/// PassiveWebView's willOpenMenu override.
private struct RightClickBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> Blocker { Blocker() }
    func updateNSView(_ view: Blocker, context: Context) {}

    final class Blocker: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .rightMouseUp]) { [weak self] event in
                event.window === self?.window ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
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

#Preview("Onboarding") {
    OnboardingView(onFinished: {})
        .frame(width: 1180, height: 880)
        .preferredColorScheme(.dark)
}
