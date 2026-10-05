// Shared setup and permission rows for native OpenAI and CUA computer use.
// Reuses the existing Settings visual language and the floating macOS permission guide.
// Doc: Documentation - Permission Gate & Guide.md

import SwiftUI
import AppKit
import AVFoundation

struct ComputerUseGateView: View {
    let gate: ComputerUseGate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWhisper("ONE-TIME SETUP")
                .frame(maxWidth: .infinity)

            Text("Allow the permissions needed to control your computer")
                .display(23)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 26) {
                SentientPermissionRows(gate: gate)

                SettingsGroup(label: "Sidekick") {
                    StatusLine(title: "Microphone & Speech",
                               health: gate.micSpeech == .granted ? .ok : .warn,   // optional — amber, never blocking
                               note: micSpeechNote,
                               tip: ComputerUseGate.micSpeechTip,
                               fixTitle: gate.micSpeech == .notAsked ? "Allow…" : "Fix…") {
                        fixMicSpeech()
                    }
                }
            }
            .padding(.top, 30)

            // No bypass: while any required grant is red the button is disabled and says so, so a
            // feature can never be fired half-granted. It enables the instant every row goes green
            // (the rows re-probe on foreground + after the mic prompt).
            OnboardingNextButton(title: continueTitle,
                                 enabled: gate.allRequiredGranted) {
                gate.continueNow()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 32)

            HStack(spacing: 8) {
                Image(systemName: "shield").font(.system(size: 10)).foregroundStyle(Theme.Ink.label)
                Text(PrivacyCopy.screenFooter)
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
        .task {
            while !Task.isCancelled {
                gate.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gate.refresh()   // the user may just have flipped a switch in System Settings
        }
    }

    // MARK: Sentient's grants — native prompts first, the guide as the fallback

    private var continueTitle: String {
        if gate.allRequiredGranted { return "Continue" }
        if gate.backend == .openAI {
            return gate.checkingAutomation ? "Checking computer use…" : "Finish setup to continue"
        }
        return "Grant permissions to continue"
    }

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
        VStack(alignment: .leading, spacing: 22) {
            if gate.backend == .openAI, !gate.setup.ready || !CodexSetup.shared.computerUseReady {
                SettingsGroup(label: "Computer use") {
                    StatusLine(title: "Set up computer use",
                               health: gate.setup.isInstalling ? .warn : .bad,
                               note: gate.setup.isInstalling ? "setting up…" : "not set up",
                               tip: "Prepares the computer-use tools for your selected AI engine.",
                               fixTitle: "Set up…",
                               fix: gate.setup.isInstalling ? nil : { Task { await gate.setup.install() } })
                    if let line = gate.setup.status { SettingsProse(line) }
                }
            }
            if gate.backend == .openAI { NativeComputerUsePermissionRows(gate: gate) }
            SettingsGroup(label: "Sentient Permissions") {
                VStack(alignment: .leading, spacing: 2) {
                    if gate.backend == .cua {
                        StatusLine(title: "Accessibility (act in your apps)",
                                   health: gate.sentientAccessibility ? .ok : .bad,
                                   note: gate.sentientAccessibility ? "granted" : "not granted",
                                   tip: "Lets Sentient read windows and act inside your apps in the background.",
                                   fixTitle: "Allow…") { fixSentientAccessibility() }
                    }
                    StatusLine(title: "Screen Recording (see the screen)",
                               health: gate.sentientScreen ? .ok : .bad,
                               note: gate.sentientScreen ? "granted" : "not granted",
                               tip: PrivacyCopy.screenCapture,
                               fixTitle: "Allow…") { fixSentientScreen() }
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

/// Native helper grants are shared by the first-use gate, upgrade flow and Settings.
struct NativeComputerUsePermissionRows: View {
    let gate: ComputerUseGate
    var body: some View {
        SettingsGroup(label: "Computer Use") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Accessibility",
                           health: gate.helperAccessibility ? .ok : .bad,
                           note: gate.helperAccessibility ? "granted" : "not granted",
                           tip: "Allows clicking and typing in your apps.",
                           fixTitle: "Allow…",
                           fix: !gate.setup.ready || gate.helperAccessibility ? nil : {
                    PermissionGuide.shared.guide(.accessibility, dragging: OpenAIComputerUse.appURL)
                })
                StatusLine(title: "Screen Recording",
                           health: gate.helperScreen ? .ok : .bad,
                           note: gate.helperScreen ? "granted" : "not granted",
                           tip: "Allows computer use to see the app it is working in.",
                           fixTitle: "Allow…",
                           fix: !gate.setup.ready || gate.helperScreen ? nil : {
                    PermissionGuide.shared.guide(.screenRecording, dragging: OpenAIComputerUse.appURL)
                })
                if gate.restartingNative {
                    SettingsProse("Restarting computer use…")
                } else if gate.requestingAutomation {
                    SettingsProse(gate.automation == .granted ? "Checking computer use…" : "Choose Allow in the macOS permission prompt.")
                } else if gate.automation == .denied {
                    SettingsProse("Allow Sentient in System Settings to finish setup.")
                    SettingsPillButton(title: "Open Settings") { Permissions.openAutomationSettings() }
                } else if gate.setup.ready, let error = gate.nativePermissionError {
                    SettingsProse(error)
                    if gate.nativeRestartRequired {
                        SettingsPillButton(title: "Restart computer use") { gate.restartComputerUse() }
                            .disabled(gate.checkingAutomation)
                    } else {
                        SettingsPillButton(title: "Try again") { gate.requestAutomation() }
                            .disabled(gate.checkingAutomation)
                    }
                } else if gate.setup.ready, gate.checkingAutomation, !gate.nativeRuntimeReady {
                    SettingsProse("Checking computer use…")
                }
            }
        }
        .task(id: gate.setup.ready) { await gate.prepareNativePermissions() }
        .onChange(of: gate.automation) { _, state in
            if state == .notAsked, gate.setup.ready { gate.requestAutomation() }
        }
    }
}

#Preview("Computer-use gate") {
    ComputerUseGateView(gate: ComputerUseGate.shared)
        .preferredColorScheme(.dark)
}
