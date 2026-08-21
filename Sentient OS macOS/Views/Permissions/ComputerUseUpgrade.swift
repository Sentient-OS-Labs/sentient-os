//
//  ComputerUseUpgrade.swift
//  Sentient OS macOS  ·  Views/Permissions/
//
//  The one-time migration window for Macs UPDATING from the 1.x codex-helper era of computer
//  use. Those Macs had computer use working (HealthCaution's everReady latch) but carry none of
//  what the cua driver needs: the pinned binary isn't on disk, and Sentient's own Accessibility
//  was never asked for. Rather than a silent background download, the update gets its own moment:
//  the first home open after updating raises this window — "Computer use just got better", one
//  glowing CTA, the live install narration (download → verify → install, the same streamed lines
//  CodexSetup.setupCuaDriver produces), then the two grant rows the first-fire gate would
//  otherwise show (SentientPermissionRows, shared with ComputerUseGateView).
//
//  Deliberately NOT closable before the driver is installed (no close button, and Cmd-W has
//  nothing to perform): the download is the migration, and every fallback after it exists
//  (fire-time self-heal, the Health fix). After the install, the grants are a strong nudge, not a
//  hostage: Done enables when both are green, and a quiet "Finish later" hands enforcement back
//  to the first-fire gate. The trigger condition (everReady latch + binary missing) is
//  self-extinguishing — once the driver is on disk, this window can never appear again, so no
//  flag is persisted. Fresh installs never see it (onboarding fetches the driver itself and the
//  latch only sets once computer use has been seen working).
//
//  Key members: maybePresent() (RootView, first home open) · install() · finish()
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class ComputerUseUpgrade {

    static let shared = ComputerUseUpgrade()
    private init() {}

    enum Phase {
        case pitch        // the announcement + CTA (and, after a failed attempt, the retry)
        case installing   // setupCuaDriver running; the streamed line narrates
        case grants       // driver on disk; Sentient's two grant rows + Done
    }
    private(set) var phase: Phase = .pitch

    /// The ✗ line of a failed install attempt, shown under the CTA with the retry.
    private(set) var failureLine: String?

    private var window: NSWindow?

    /// True while the window is up — HealthCaution's driver-missing rung defers to it, so the
    /// home never shows the red "needs setting up again" banner behind this window's own fix.
    var isPresenting: Bool { window != nil }

    /// First home open after an update (RootView.onAppear, post-onboarding only). Shows ONLY on
    /// the migration Mac: computer use once worked here, and the pinned driver isn't on disk.
    /// A Mac that already self-healed (a Sidekick fire before the home ever opened) skips it.
    func maybePresent() {
        guard UserDefaults.standard.bool(forKey: HealthCaution.computerUseEverReadyKey),
              !CuaDriver.isInstalled,
              window == nil else { return }
        phase = .pitch
        failureLine = nil
        ComputerUseGate.shared.refresh()
        let hosting = NSHostingController(rootView: ComputerUseUpgradeView(model: self))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .fullSizeContentView]   // deliberately NO .closable — see header
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.isMovableByWindowBackground = true
        window = w
        // Lay the SwiftUI content out BEFORE centering: `center()` reads the window's current
        // frame, and against the pre-layout size the content then grows the window from that
        // origin — landing it visibly off-center (field-found on the first migration test).
        hosting.view.layoutSubtreeIfNeeded()
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Analytics.signal("ComputerUseUpgrade.shown")
        Log("ComputerUseUpgrade: window up (updated Mac, driver missing)")
    }

    /// The CTA — run the shared setup engine and narrate it. `ensureCuaDriver` (not a bare setup
    /// call) so an install already in flight — a Sidekick fire's self-heal racing this window —
    /// is awaited rather than misread as a failure. Success flows into the grant rows; failure
    /// returns to the pitch with the ✗ line and the CTA as the retry.
    func install() {
        guard phase != .installing else { return }
        phase = .installing
        failureLine = nil
        Task {
            if await CodexSetup.shared.ensureCuaDriver() {
                ComputerUseGate.shared.refresh()
                phase = .grants
                Analytics.signal("ComputerUseUpgrade.installed")
            } else {
                failureLine = CodexSetup.shared.cuaDriverStatus
                phase = .pitch
            }
        }
    }

    /// Done / Finish later — only reachable once the driver is installed, so closing is safe:
    /// anything still missing (a red grant) is the first-fire gate's job from here.
    func finish() {
        Analytics.signal("ComputerUseUpgrade.finished",
                         parameters: ["all_granted": String(ComputerUseGate.shared.allRequiredGranted)])
        window?.close()
        window = nil
    }
}

// MARK: - The window's face

struct ComputerUseUpgradeView: View {
    let model: ComputerUseUpgrade
    @State private var codexSetup = CodexSetup.shared

    private var gate: ComputerUseGate { ComputerUseGate.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWhisper(model.phase == .grants ? "ONE LAST STEP" : "SENTIENT UPDATED")
                .frame(maxWidth: .infinity)

            Text(model.phase == .grants ? "Now give it its hands and eyes."
                                        : "Computer use just got better.")
                .display(23)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)   // wrap — never truncate the pitch
                .padding(.top, 8)

            switch model.phase {
            case .pitch, .installing:
                installSection
            case .grants:
                SentientPermissionRows(gate: gate)
                    .padding(.top, 30)
                OnboardingNextButton(title: gate.allRequiredGranted ? "Done" : "Grant permissions to finish",
                                     enabled: gate.allRequiredGranted) {
                    model.finish()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                Button("Finish later") { model.finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }

            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 10)).foregroundStyle(Theme.Ink.label)
                Text("Private by design. Your files never leave this Mac.")
                    .font(.system(size: 11)).foregroundStyle(Theme.Ink.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 560)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gate.refresh()   // the user may just have flipped a switch in System Settings
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .pitch, .installing:
            "Sentient now acts inside the window it's working on, quietly in the background. Your cursor stays yours, and you keep working while it works."
        case .grants:
            "The new computer use acts as Sentient itself, so it needs these two grants, once. You will not be asked again."
        }
    }

    /// The pitch CTA and, while the engine runs, the live narration under it.
    @ViewBuilder
    private var installSection: some View {
        OnboardingNextButton(title: ctaTitle,
                             enabled: model.phase == .pitch,
                             glow: model.phase == .pitch ? 0.4 : 0) {   // the screen's ONE glowing object
            model.install()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)

        Group {
            if model.phase == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(codexSetup.cuaDriverStatus ?? "Starting…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                }
            } else if let line = model.failureLine {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            } else {
                Text("A one-time 40 MB download, verified on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var ctaTitle: String {
        switch model.phase {
        case .installing: "Setting up…"
        default:          model.failureLine == nil ? "Set up the new computer use" : "Try again"
        }
    }
}

#if DEBUG
#Preview("Computer-use upgrade") {
    ComputerUseUpgradeView(model: ComputerUseUpgrade.shared)
        .preferredColorScheme(.dark)
}
#endif
