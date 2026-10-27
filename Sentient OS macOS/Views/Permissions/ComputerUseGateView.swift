// Shared setup and permission rows for native OpenAI and CUA computer use.
// Reuses the existing Settings visual language and the floating macOS permission guide.
// Doc: Documentation - Permission Gate & Guide.md

import SwiftUI
import AppKit
import AVFoundation

struct ComputerUseGateView: View {
    let gate: ComputerUseGate

    var body: some View {
        PermissionSetupView(title: gate.showingVoiceRepair ? "Set up voice input" : "Allow Sidekick to use your computer",
                            continueTitle: continueTitle, canContinue: gate.showingVoiceRepair || gate.allRequiredGranted,
                            onContinue: gate.continueNow) {
            if !gate.showingVoiceRepair {
                SentientPermissionRows(gate: gate)
                if !gate.sentientScreen, SafeAppRelaunch.shared.canRelaunchPermissionWait {
                    SettingsProse("If macOS asks you to restart, keep this request as a draft. Send it again after relaunching.")
                    SettingsPillButton(title: "Save request & relaunch") { _ = SafeAppRelaunch.shared.relaunchPermissionWait() }
                }
                if let failure = SafeAppRelaunch.shared.failure { SettingsProse(failure) }
            }
            if gate.showingVoiceRepair { SettingsGroup(label: "Voice input") {
                StatusLine(title: "Microphone & Speech",
                           health: gate.micSpeech == .granted ? .ok : .warn,   // optional — amber, never blocking
                           note: micSpeechNote,
                           tip: ComputerUseGate.micSpeechTip,
                           fixTitle: gate.micSpeech == .notAsked ? "Allow…" : "Fix…") {
                    fixMicSpeech()
                }
            } }
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
        if gate.showingVoiceRepair { return "Done" }
        if gate.allRequiredGranted { return "Continue" }
        if gate.backend == .openAI {
            return gate.checkingAutomation ? "Checking computer use…" : "Finish setup to continue"
        }
        return "Grant permissions to continue"
    }

    private var micSpeechNote: String {
        switch gate.micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "not requested"
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
    private var automationNote: String {
        if gate.requestingAutomation || gate.checkingAutomation { return "checking…" }
        switch gate.automation {
        case .granted: return "granted"
        case .denied: return "not allowed"
        case .notAsked: return "not requested"
        case .unavailable: return "not checked"
        }
    }
    private func note(_ state: NativePermissionReadiness.State) -> String {
        switch state {
        case .verified: "verified"
        case .denied: "not allowed"
        case .unknown: "not checked"
        }
    }
    var body: some View {
        SettingsGroup(label: formStyle ? "Computer use" : "Computer Use") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Accessibility",
                           health: gate.helperAccessibility ? .ok : .warn,
                           note: note(gate.helperPermissionState.accessibility),
                           tip: "Allows clicking and typing in your apps.",
                           fixTitle: "Open Settings",
                           fix: !gate.setup.ready || gate.helperAccessibility ? nil : {
                    PermissionGuide.shared.guide(.accessibility, dragging: OpenAIComputerUse.appURL)
                })
                if formStyle { SettingsHairline(opacity: 0.10) }
                StatusLine(title: "Screen Recording",
                           health: gate.helperScreen ? .ok : (gate.helperPermissionState.screenRecording == .denied ? .bad : .warn),
                           note: note(gate.helperPermissionState.screenRecording),
                           tip: "Allows computer use to see the app it is working in.",
                           fixTitle: "Open Settings",
                           fix: !gate.setup.ready || gate.helperScreen ? nil : {
                    PermissionGuide.shared.guide(.screenRecording, dragging: OpenAIComputerUse.appURL)
                })
                if formStyle { SettingsHairline(opacity: 0.10) }
                StatusLine(title: "Automation",
                           health: gate.automation == .granted ? .ok : (gate.automation == .denied ? .bad : .warn),
                           note: automationNote,
                           tip: "Allows Sentient OS to control its computer-use helper. This is separate from Screen Recording and Accessibility.",
                           fixTitle: gate.automation == .denied ? "Open Settings" : (gate.automation == .notAsked ? "Allow…" : "Check again"),
                           fix: !gate.setup.ready || gate.automation == .granted || gate.requestingAutomation || gate.checkingAutomation ? nil : {
                    if gate.automation == .denied { Permissions.openAutomationSettings() }
                    else { gate.requestAutomation() }
                })
                if gate.restartingNative {
                    SettingsProse("Restarting computer use…")
                } else if gate.requestingAutomation {
                    SettingsProse(gate.automation == .granted ? "Checking computer use…" : "Choose Allow in the macOS permission prompt.")
                } else if gate.automation == .denied {
                    SettingsProse("In System Settings → Privacy & Security → Automation, expand Sentient OS and turn on ChatGPT Computer Use (called Codex Computer Use in some versions).")
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
                if gate.setup.ready, gate.automation == .granted, !gate.helperPermissionState.isReady,
                   gate.nativePermissionError == nil, !gate.requestingAutomation {
                    SettingsProse("Already allowed these permissions? Check them using a temporary Sentient window. Full Disk Access is not needed.")
                    SettingsPillButton(title: "Check computer use") { gate.requestAutomation() }
                        .disabled(gate.checkingAutomation)
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
