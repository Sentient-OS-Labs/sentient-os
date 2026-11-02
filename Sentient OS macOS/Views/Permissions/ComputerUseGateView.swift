// Shared setup and permission rows for native OpenAI and CUA computer use.
// Reuses the existing Settings visual language and the floating macOS permission guide.
// Doc: Documentation - Permission Gate & Guide.md

import SwiftUI
import AppKit
import AVFoundation

struct ComputerUseGateView: View {
    let gate: ComputerUseGate

    var body: some View {
        PermissionSetupView(title: gate.showingVoiceRepair ? "Set up voice input" : "Let Sidekick use your computer",
                            continueTitle: continueTitle,
                            canContinue: canContinue,
                            onContinue: gate.continueNow, compact: !gate.showingVoiceRepair,
                            edgeGlow: !gate.showingVoiceRepair) {
            if !gate.showingVoiceRepair {
                SentientPermissionRows(gate: gate, compact: true)
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
        return "Grant permissions to continue"
    }

    private var canContinue: Bool {
        if gate.showingVoiceRepair { return true }
        if gate.requiresPermissionRestart { return gate.canRestartAfterPermissions }
        return gate.isReadyForTask
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

/// Sentient's own required grants. Native helper consent appears during actual tool use.
/// Double Tap also reuses these app permission rows.
/// `gate` is the one probe source; call `gate.refresh()` around presentation.
struct SentientPermissionRows: View {
    let gate: ComputerUseGate
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 18 : 22) {
            SentientAppPermissionRows(accessibility: gate.backend == .cua ? gate.sentientAccessibility : nil,
                                     screen: gate.sentientScreen,
                                     compact: compact,
                                     onPermissionChange: {
                if gate.backend == .openAI { gate.beganPermissionAction(.sentientScreen) }
            }, onScreenRecordingDrop: {
                gate.completedPermissionDrag(.sentientScreen)
            }, automation: gate.backend == .openAI && gate.automation != .unavailable ? gate.automation : nil,
               requestingAutomation: gate.requestingAutomation,
               onRequestAutomation: gate.requestAutomation)
            if gate.requiresPermissionRestart {
                NativePermissionRestartSection(gate: gate, showsButton: false)
            }
        }
    }
}

/// Settings delegates helper grants to their actual owner instead of showing inferred statuses.
struct NativeComputerUseSettings: View {
    let gate: ComputerUseGate
    private var busy: Bool { gate.requestingAutomation || gate.checkingCapabilities }

    var body: some View {
        SettingsGroup(label: "Computer use") {
            SettingsRow(title: "Native helper permissions",
                        subtitle: "Manage Accessibility and Screen Recording in the helper’s own setup window.") {
                SettingsPillButton(title: busy ? "Opening setup…" : "Fix permissions…") {
                    gate.fixNativePermissions()
                }
                .disabled(busy || gate.checkingAutomation || !gate.setup.ready || ComputerUseDoctor.shared.isRunning)
                .accessibilityLabel("Fix computer-use permissions")
            }
            if !gate.setup.ready {
                SettingsProse("Finish installing computer use, then open its permission setup.")
            } else if gate.automation == .denied {
                SettingsProse("Allow Sentient OS to control ChatGPT/Codex Computer Use in System Settings → Privacy & Security → Automation.")
                SettingsPillButton(title: "Open Automation Settings") { Permissions.openAutomationSettings() }
            } else if let error = gate.nativePermissionError {
                SettingsProse(error)
            } else if gate.nativeRepairSucceeded && gate.helperPermissionState.isReady
                        && !NativePermissionSetup.shared.recoveryNeeded && !busy {
                SettingsProse("Computer-use permissions are ready.")
            }
        }
        .task { gate.refresh(); await gate.checkNativePermissionsIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gate.refresh()
            Task { await gate.checkNativePermissionsIfNeeded() }
        }
    }
}

/// Additional controls appear only when restart is blocked, or on the Settings surface.
struct NativePermissionRestartSection: View {
    let gate: ComputerUseGate
    var showsButton = true

    var body: some View {
        if showsButton || SafeAppRelaunch.shared.failure != nil
            || (!SafeAppRelaunch.shared.canRelaunchPermissionWait && !SafeAppRelaunch.shared.canRelaunch) {
            VStack(alignment: .leading, spacing: 12) {
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
}

#Preview("Computer-use gate") {
    ComputerUseGateView(gate: ComputerUseGate.shared)
        .preferredColorScheme(.dark)
}
