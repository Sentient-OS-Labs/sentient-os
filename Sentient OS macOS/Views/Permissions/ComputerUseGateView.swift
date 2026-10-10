// Shared setup and permission rows for native OpenAI and CUA computer use.
// Reuses the existing Settings visual language and the floating macOS permission guide.
// Doc: Documentation - Permission Gate & Guide.md

import SwiftUI
import AppKit
import AVFoundation

struct ComputerUseGateView: View {
    let gate: ComputerUseGate

    var body: some View {
        PermissionSetupView(title: "Allow the permissions needed to control your computer",
                            continueTitle: continueTitle, canContinue: gate.allRequiredGranted,
                            onContinue: gate.continueNow) {
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

/// The selected computer-use runtime's required grants. Sentient's own rows are also reused by
/// Double Tap; the native helper's rows remain specific to computer use.
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
            SentientAppPermissionRows(accessibility: gate.backend == .cua ? gate.sentientAccessibility : nil,
                                     screen: gate.sentientScreen)
        }
    }
}

/// Native helper grants are shared by the first-use gate, upgrade flow and Settings.
struct NativeComputerUsePermissionRows: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let gate: ComputerUseGate
    var body: some View {
        SettingsGroup(label: formStyle ? "Computer use" : "Computer Use") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Accessibility",
                           health: gate.helperAccessibility ? .ok : .bad,
                           note: gate.helperAccessibility ? "granted" : "not granted",
                           tip: "Allows clicking and typing in your apps.",
                           fixTitle: "Allow…",
                           fix: !gate.setup.ready || gate.helperAccessibility ? nil : {
                    PermissionGuide.shared.guide(.accessibility, dragging: OpenAIComputerUse.appURL)
                })
                if formStyle { SettingsHairline(opacity: 0.10) }
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
                } else if gate.setup.ready, gate.checkingAutomation, gate.automation != .granted {
                    SettingsProse("Checking permissions…")
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
