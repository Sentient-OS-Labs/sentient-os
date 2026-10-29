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
                            continueTitle: continueTitle,
                            canContinue: gate.showingVoiceRepair || (gate.requiresPermissionRestart
                                ? gate.canRestartAfterPermissions : gate.isReadyForTask),
                            onContinue: gate.continueNow) {
            if !gate.showingVoiceRepair {
                SentientPermissionRows(gate: gate)
                if gate.backend == .cua, !gate.sentientScreen, SafeAppRelaunch.shared.canRelaunchPermissionWait {
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
        if gate.requiresPermissionRestart {
            return SafeAppRelaunch.shared.isPreparing ? "Restarting Sentient…" : "Restart Sentient"
        }
        if gate.isReadyForTask { return "Continue" }
        if gate.backend == .openAI {
            return gate.checkingCapabilities ? "Finish helper setup…" : "Finish setup to continue"
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
            if gate.backend == .openAI { NativeComputerUsePermissionRows(gate: gate, showsRestartAction: false) }
            SentientAppPermissionRows(accessibility: gate.backend == .cua ? gate.sentientAccessibility : nil,
                                     screen: gate.sentientScreen,
                                     onPermissionChange: {
                if gate.backend == .openAI { gate.changingNativePermissions() }
            })
            if gate.requiresPermissionRestart {
                NativePermissionRestartSection(gate: gate, showsButton: false)
            }
        }
    }
}

/// Native helper grants are shared by the first-use gate, upgrade flow and Settings.
struct NativeComputerUsePermissionRows: View {
    @Environment(\.settingsFormStyle) private var formStyle
    let gate: ComputerUseGate
    var showsRestartAction = true
    private var automationNote: String {
        switch gate.automation {
        case .granted: return "granted"
        case .denied, .notAsked, .unavailable: return "not granted"
        }
    }
    private func note(_ state: NativePermissionReadiness.State, grant: NativePermissionSetup.Grant) -> String {
        if state == .verified { return "granted" }
        if gate.requiresPermissionRestart,
           NativePermissionSetup.shared.dropped.contains(grant) || gate.permissionSetupConfirmed {
            return "restart to finish"
        }
        if NativePermissionSetup.shared.canAttemptTask { return "ready to try" }
        return "not granted"
    }
    var body: some View {
        SettingsGroup(label: formStyle ? "Computer use" : "Computer Use") {
            VStack(alignment: .leading, spacing: 2) {
                StatusLine(title: "Accessibility",
                           health: gate.helperAccessibility ? .ok : .warn,
                           note: note(gate.helperPermissionState.accessibility, grant: .accessibility),
                           tip: "Allows clicking and typing in your apps.",
                           fixTitle: "Open Settings",
                           fix: !gate.setup.ready || gate.helperAccessibility ? nil : {
                    gate.changingNativePermissions()
                    PermissionGuide.shared.guide(.accessibility, dragging: OpenAIComputerUse.appURL) {
                        NativePermissionSetup.shared.didDrop(.accessibility)
                    }
                })
                if formStyle { SettingsHairline(opacity: 0.10) }
                StatusLine(title: "Screen Recording",
                           health: gate.helperScreen ? .ok : (gate.helperPermissionState.screenRecording == .denied ? .bad : .warn),
                           note: note(gate.helperPermissionState.screenRecording, grant: .screenRecording),
                           tip: "Allows computer use to see the app it is working in.",
                           fixTitle: "Open Settings",
                           fix: !gate.setup.ready || gate.helperScreen ? nil : {
                    gate.changingNativePermissions()
                    PermissionGuide.shared.guide(.screenRecording, dragging: OpenAIComputerUse.appURL) {
                        NativePermissionSetup.shared.didDrop(.screenRecording)
                    }
                })
                if formStyle { SettingsHairline(opacity: 0.10) }
                StatusLine(title: "Automation",
                           health: gate.automation == .granted ? .ok : (gate.automation == .denied ? .bad : .warn),
                           note: automationNote,
                           tip: "Allows Sentient OS to control its computer-use helper. This is separate from Screen Recording and Accessibility.",
                           fixTitle: gate.automation == .denied ? "Open Settings" : (gate.automation == .notAsked ? "Allow…" : "Check again"),
                           fix: !gate.setup.ready || gate.automation == .granted || gate.requestingAutomation || gate.checkingAutomation ? nil : {
                    if gate.automation == .denied {
                        gate.changingNativePermissions()
                        Permissions.openAutomationSettings()
                    }
                    else { gate.requestAutomation() }
                })
                if gate.restartingNative {
                    SettingsProse("Restarting computer use…")
                } else if gate.requestingAutomation || gate.checkingCapabilities {
                    SettingsProse(gate.automation == .granted ? "Finish the permissions in the helper’s setup window. The Chrome extension is optional." : "Choose Allow in the macOS permission prompt.")
                } else if gate.automation == .denied {
                    SettingsProse("In System Settings → Privacy & Security → Automation, expand Sentient OS and turn on ChatGPT Computer Use (called Codex Computer Use in some versions).")
                } else if gate.setup.ready, let error = gate.nativePermissionError {
                    SettingsProse(error)
                    if !gate.requiresPermissionRestart, gate.nativeRestartRequired {
                        SettingsPillButton(title: "Restart computer use") { gate.restartComputerUse() }
                            .disabled(gate.checkingAutomation)
                    } else if !gate.requiresPermissionRestart, NativePermissionSetup.shared.recoveryNeeded {
                        SettingsPillButton(title: "Open helper setup") { gate.verifyNativePermissions() }
                            .disabled(gate.checkingAutomation)
                    } else if !gate.requiresPermissionRestart {
                        SettingsPillButton(title: "Try again") { gate.requestAutomation() }
                            .disabled(gate.checkingAutomation)
                    }
                } else if gate.setup.ready, gate.checkingAutomation, gate.automation != .granted {
                    SettingsProse("Checking permissions…")
                }
                if gate.setup.ready, !gate.requiresPermissionRestart, gate.automation == .granted, NativePermissionSetup.shared.recoveryNeeded,
                   gate.nativePermissionError == nil, !gate.requestingAutomation, !gate.checkingCapabilities {
                    SettingsProse("Computer use reported a missing permission. Finish setup in its helper window; Chrome is optional.")
                    SettingsPillButton(title: "Open helper setup") { gate.verifyNativePermissions() }
                        .disabled(gate.checkingAutomation)
                }
                if showsRestartAction, gate.requiresPermissionRestart {
                    NativePermissionRestartSection(gate: gate)
                        .padding(.top, 16)
                }
            }
        }
        .task(id: gate.setup.ready) { await gate.prepareNativePermissions() }
        .task(id: gate.shouldCheckAfterRestart) { gate.checkAfterRestartIfNeeded() }
        .onChange(of: gate.automation) { _, state in
            if state == .notAsked, gate.setup.ready { gate.requestAutomation() }
        }
    }
}

/// Confirmation records the user's setup step, not a verified macOS permission.
struct NativePermissionRestartSection: View {
    let gate: ComputerUseGate
    var showsButton = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsProse("After dragging, turn each permission’s switch on in System Settings. Confirm below, then restart Sentient to finish setup.")
            Toggle("I’ve enabled the permissions above", isOn: Binding(
                get: { gate.permissionSetupConfirmed },
                set: { gate.permissionSetupConfirmed = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .disabled(!gate.setup.ready || SafeAppRelaunch.shared.isPreparing)
                .accessibilityIdentifier("computerUse.permissionsConfirmed")
            SettingsProse(SafeAppRelaunch.shared.canRelaunchPermissionWait
                ? "Your Sidekick request will be saved as a draft. Send it again when Sentient reopens."
                : "Unsent messages are kept. Nothing is sent automatically after restart.")
            if !SafeAppRelaunch.shared.canRelaunchPermissionWait, !SafeAppRelaunch.shared.canRelaunch,
               let reason = SafeAppRelaunch.shared.statusReason {
                SettingsProse(reason)
                if gate.hasWaitingAction, !SafeAppRelaunch.shared.isPreparing {
                    SettingsPillButton(title: "Stop waiting task") { gate.stopWaitingAction() }
                }
            }
            if let failure = SafeAppRelaunch.shared.failure { SettingsProse(failure) }
            if showsButton {
                SettingsPillButton(title: SafeAppRelaunch.shared.isPreparing ? "Restarting Sentient…" : "Restart Sentient") {
                    gate.restartAfterPermissions()
                }
                .disabled(!gate.canRestartAfterPermissions)
            }
        }
    }
}

#Preview("Computer-use gate") {
    ComputerUseGateView(gate: ComputerUseGate.shared)
        .preferredColorScheme(.dark)
}
