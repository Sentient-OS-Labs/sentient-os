//
//  ComputerUseGateView.swift
//  Sentient OS macOS
//
//  The one-time setup window's face (ComputerUseGate presents it): the four action grants as the
//  same StatusLine rows Settings → Health uses, in two groups — SIDEKICK & PROACTIVE (Sentient's
//  Microphone & Speech, plus its OPTIONAL Screen Recording — amber, never blocking) and CODEX
//  PERMISSIONS (the helper's Accessibility, Screen Recording). Mic & Speech fix via the native
//  system prompts; the other three fix via PermissionGuide's floating drag panel (they're
//  system-TCC lists — only the user can flip them). Continue fires the held action whether or
//  not everything is green; the rows re-probe when the app foregrounds (returning from System
//  Settings).
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
                SettingsGroup(label: "Sidekick & Proactive") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Microphone & Speech",
                                   health: micSpeechHealth,
                                   note: micSpeechNote,
                                   tip: "Lets Sidekick hear you and turn your words into text when you hold the shortcut key. Your voice is heard and transcribed on this Mac, never in the cloud.",
                                   fixTitle: gate.micSpeech == .notAsked ? "Allow…" : "Fix…") {
                            fixMicSpeech()
                        }
                        StatusLine(title: "Screen Recording",
                                   health: gate.sentientScreen ? .ok : .warn,   // optional — amber, never blocking
                                   note: gate.sentientScreen ? "granted" : "optional",
                                   tip: "Optional. Lets Sentient snap a still of your screen the moment you fire a command, so it can see the thing you're asking about. Without it, commands run without screen context. Takes effect after you restart Sentient.",
                                   fixTitle: "Allow…") {
                            fixSentientScreen()
                        }
                    }
                }

                SettingsGroup(label: "Codex Permissions") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Accessibility (move the mouse, type)",
                                   health: gate.helperAccessibility ? .ok : (gate.helperOnDisk ? .bad : .warn),
                                   note: helperNote(granted: gate.helperAccessibility),
                                   tip: "Lets Codex's helper app move the mouse and type for you. Granted to OpenAI's helper, not to Sentient.",
                                   fixTitle: "Grant…") {
                            fixHelper(.accessibility)
                        }
                        StatusLine(title: "Screen Recording (see the screen)",
                                   health: gate.helperScreen ? .ok : (gate.helperOnDisk ? .bad : .warn),
                                   note: helperNote(granted: gate.helperScreen),
                                   tip: "Lets Codex's helper app see the screen so it acts on the right thing. Granted to OpenAI's helper, not to Sentient.",
                                   fixTitle: "Grant…") {
                            fixHelper(.screenRecording)
                        }
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

    private var micSpeechHealth: StatusLine.Health {
        switch gate.micSpeech {
        case .granted:  return .ok
        case .notAsked: return .bad   // compulsory here — this window exists to get them granted
        case .denied:   return .bad
        }
    }

    private var micSpeechNote: String {
        switch gate.micSpeech {
        case .granted:  return "granted"
        case .notAsked: return "not asked yet"
        case .denied:   return "denied"
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

    /// The Screen Recording list is drag-authorizable, and Sentient may not be IN the list at all
    /// (on Tahoe, CGRequestScreenCaptureAccess doesn't reliably add it — field-verified) — so the
    /// guide always carries Sentient itself as the drag card. Dragging when the row already exists
    /// is harmless; the user just flips the existing switch.
    private func fixSentientScreen() {
        guard !gate.sentientScreen else { return }
        PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
    }

    // MARK: The helper's grants — system TCC; the drag panel is the only honest path

    private func helperNote(granted: Bool) -> String {
        if granted { return "granted" }
        return gate.helperOnDisk ? "not granted" : "computer use still setting up"
    }

    private func fixHelper(_ pane: PermissionGuide.Pane) {
        guard let helper = Permissions.computerUseHelperURL() else { return }
        PermissionGuide.shared.guide(pane, dragging: helper)
    }
}

#Preview("Computer-use gate") {
    ComputerUseGateView(gate: ComputerUseGate.shared)
        .preferredColorScheme(.dark)
}
