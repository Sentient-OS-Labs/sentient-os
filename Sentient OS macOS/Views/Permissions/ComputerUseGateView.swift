//
//  ComputerUseGateView.swift
//  Sentient OS macOS
//
//  The one-time setup window's face (ComputerUseGate presents it): the action grants as the same
//  StatusLine rows Settings → Health uses. The cua driver acts as Sentient, so SENTIENT
//  PERMISSIONS holds Sentient's own Accessibility and Screen Recording as the REQUIRED pair;
//  SIDEKICK holds the OPTIONAL Microphone & Speech row (amber, never blocking). Mic & Speech and
//  Accessibility fix via the native system prompts; the Screen Recording list fixes via
//  PermissionGuide's floating drag panel (a system-TCC list — only the user can flip it). Continue
//  fires the held action whether or not the optional is green; the rows re-probe when the app
//  foregrounds (returning from System Settings).
//

import SwiftUI
import AppKit
import AVFoundation

struct ComputerUseGateView: View {
    let gate: ComputerUseGate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWhisper("ONE-TIME SETUP")
                .frame(maxWidth: .infinity)

            Text("Give Sentient its hands and eyes.")
                .display(23)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

            Text("Acting on your Mac needs these grants, once. You will not be asked again.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 26) {
                SentientPermissionRows(gate: gate)

                SettingsGroup(label: "Sidekick") {
                    StatusLine(title: "Microphone & Speech",
                               health: gate.micSpeech == .granted ? .ok : .warn,   // optional — amber, never blocking
                               note: micSpeechNote,
                               tip: "Optional but recommended.\nLets Sidekick hear you and turn your words into text when you hold the shortcut key.\n\nWithout it, hold-to-talk stays off — you can still tap the key (or click the notch) and type.\n\nYour voice is heard and transcribed on this Mac, never in the cloud.",
                               fixTitle: gate.micSpeech == .notAsked ? "Allow…" : "Fix…") {
                        fixMicSpeech()
                    }
                }
            }
            .padding(.top, 30)

            // No bypass: while any required grant is red the button is disabled and says so, so a
            // feature can never be fired half-granted. It enables the instant every row goes green
            // (the rows re-probe on foreground + after the mic prompt).
            OnboardingNextButton(title: gate.allRequiredGranted ? "Continue" : "Grant permissions to continue",
                                 enabled: gate.allRequiredGranted) {
                gate.continueNow()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)

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
        .onAppear { gate.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gate.refresh()   // the user may just have flipped a switch in System Settings
        }
    }

    // MARK: Sentient's grants — native prompts first, the guide as the fallback

    private var micSpeechNote: String {
        switch gate.micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "recommended"
        case .denied:   return "off"
        }
    }

    private func fixMicSpeech() {
        switch gate.micSpeech {
        case .granted:
            break
        case .notAsked:
            Task { _ = await VoiceCapture.requestPermissions(); gate.refresh() }
        case .denied:
            // Deep-link to whichever grant is actually the blocker (mic first — it gates speech).
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                Permissions.openMicrophoneSettings()
            } else {
                Permissions.openSpeechRecognitionSettings()
            }
        }
    }

}

/// The REQUIRED pair — Sentient's own Accessibility (the driver's hands) and Screen Recording
/// (its eyes) as StatusLine rows, with their fix flows. Shared by the first-fire gate and the
/// update-migration window (ComputerUseUpgrade), so the two surfaces can never drift apart.
/// `gate` is the one probe source; call `gate.refresh()` around presentation.
struct SentientPermissionRows: View {
    let gate: ComputerUseGate

    var body: some View {
        // The driver acts inside Sentient's own responsibility chain, so these two grants,
        // given to the app the user already trusts, are what let it act.
        SettingsGroup(label: "Sentient Permissions") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Accessibility (act in your apps)",
                           health: gate.sentientAccessibility ? .ok : .bad,
                           note: gate.sentientAccessibility ? "granted" : "not granted",
                           tip: "Lets Sentient read what's on a window and click and type inside it — in the background, without taking over your cursor.\n\nGranted to Sentient itself, so there's no second helper app to trust.",
                           fixTitle: "Allow…") {
                    fixSentientAccessibility()
                }
                StatusLine(title: "Screen Recording (see the screen)",
                           health: gate.sentientScreen ? .ok : .bad,
                           note: gate.sentientScreen ? "granted" : "not granted",
                           tip: "Lets Sentient see the window it's working in, so it acts on the right thing.\n\nGranted to Sentient itself. Screenshots are read on this Mac and passed to your own Codex; they never reach a Sentient server.",
                           fixTitle: "Allow…") {
                    fixSentientScreen()
                }
            }
        }
    }

    /// The Screen Recording list is drag-authorizable, and Sentient may not be IN the list at all
    /// (on Tahoe, CGRequestScreenCaptureAccess doesn't reliably add it — field-verified) — so the
    /// guide always carries Sentient itself as the drag card. Dragging when the row already exists
    /// is harmless; the user just flips the existing switch.
    private func fixSentientScreen() {
        guard !gate.sentientScreen else { return }
        PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
    }

    /// Accessibility has a real system prompt (unlike Screen Recording on Tahoe), so ask for it
    /// directly. macOS shows that prompt once per app identity, so a user who already dismissed it
    /// gets nothing — hence the deep-link fallback a beat later, once the probe says it didn't take.
    private func fixSentientAccessibility() {
        guard !gate.sentientAccessibility else { return }
        Permissions.requestAccessibility()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            gate.refresh()
            if !gate.sentientAccessibility { Permissions.openAccessibilitySettings() }
        }
    }
}

#Preview("Computer-use gate") {
    ComputerUseGateView(gate: ComputerUseGate.shared)
        .preferredColorScheme(.dark)
}
