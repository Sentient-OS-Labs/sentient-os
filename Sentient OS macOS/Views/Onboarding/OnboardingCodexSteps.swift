//
//  OnboardingCodexSteps.swift
//  Sentient OS macOS
//
//  Onboarding's codex login, in panel form — a pure renderer over the SHARED CodexSetup engine
//  (the same instance the dev tools' CodexSetupView drives; zero setup logic lives here).
//
//  OnboardingCodexLoginPanel is the ChatGPT panel inside the frontier-model step's engine
//  picker (OnboardingFrontierModelView): one button that opens the OAuth page, then the panel
//  NOTICES the finished sign-in on its own (a 2s `codex login status` poll while the browser is
//  out; the step adds a re-check on app foreground) — no "I'm done" button. The login button
//  stays greyed until the step's `codex --help` poll confirms the background CLI install landed
//  (`codexReady` — the install kicks live in the step, since custom endpoints need the CLI too).
//  Also home to the shared onboarding bits: OnboardingWhisper · OnboardingDoneLine ·
//  MonoWaitLine · OnboardingStatusText.
//
//  (Computer-use setup is deliberately NOT in onboarding — it happens later, elsewhere.)
//

import SwiftUI
import AppKit

// MARK: - The ChatGPT panel: log in to codex

struct OnboardingCodexLoginPanel: View {
    /// The step's `codex --help` confirmation — the ground truth that un-greys the login button.
    let codexReady: Bool

    @State private var codex = CodexSetup.shared
    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue

    private var backend: ModelBackend { ModelBackend(rawValue: backendRaw) ?? .chatgpt }

    var body: some View {
        SettingsGroup(label: "Your ChatGPT") {
            VStack(alignment: .leading, spacing: 14) {
                SettingsProse("This sign-in authenticates Codex model access. It does not import your ChatGPT conversations, memories, custom instructions, projects, or uploaded files. Gmail and Calendar are connected and enabled separately.")

                loginStates
            }
        }
        .task(id: codex.loggingIn) {
            // The sign-in watcher (replaces the old "I've finished" button): while the browser
            // flow is out, quietly re-check `codex login status` every 2s — the section flips to
            // the green done line by itself the moment auth.json lands. (Switching tabs cancels
            // this; the step's foreground re-check still notices a finished sign-in.)
            guard codex.loggingIn else { return }
            while !Task.isCancelled, codex.loggingIn, !codex.loggedIn {
                try? await Task.sleep(for: .seconds(2))
                await codex.refreshLoginStatus()
            }
        }
    }

    /// The login state machine: done → browser out → install failed → the button.
    @ViewBuilder private var loginStates: some View {
        if codex.loggedIn {
            OnboardingDoneLine("Logged in to Codex")
            if backend != .chatgpt {
                // A custom engine won Test & Select earlier — logging in doesn't switch
                // by itself (browsing never disturbs a live engine); this does.
                SettingsPillButton(title: "Use ChatGPT") {
                    backendRaw = ModelBackend.chatgpt.rawValue
                }
            }
        } else if codex.loggingIn {
            Text("Finish signing in in your browser. This screen notices on its own.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.body)
            MonoWaitLine("waiting for the browser sign-in…")
        } else if codex.installGaveUp && !codex.installed {
            // The auto-install couldn't finish (no network, connection reset, or Codex is
            // unavailable in this region). Point the user to install it themselves; the
            // step's poll picks Codex up automatically the moment it lands.
            CodexInstallFailedPanel()
        } else {
            // The login button — greyed until `codex --help` confirms the install
            // landed. Centered with its status lines: it's the panel's one big CTA.
            VStack(spacing: 10) {
                OnboardingNextButton(title: "Log in with ChatGPT", enabled: codexReady) {
                    codex.startLogin()
                }
                if !codexReady {
                    MonoWaitLine("installing codex in the background…")
                }
                OnboardingStatusText(codex.loginStatusLine)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Shown on the ChatGPT panel when the automatic install has clearly failed (retries exhausted):
/// no network, a connection reset, or Codex being unavailable in the user's region. It points the
/// user to install Codex themselves; the step's `codex --help` poll picks it up the moment it
/// lands, and a relaunch resumes right here (onboarding persists its step). Copy approved 2026-07-24.
private struct CodexInstallFailedPanel: View {
    private let guideURL = URL(string: "https://learn.chatgpt.com/docs/codex/cli#getting-started")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sentient couldn't finish installing Codex automatically.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Ink.body)

            SettingsProse("You can install it yourself in a minute. Once you do that, you can restart Sentient and pick up right where you left off.")

            OnboardingNextButton(title: "Open the Codex install guide") {
                NSWorkspace.shared.open(guideURL)
            }
            .frame(maxWidth: .infinity)

            SettingsProse("We also suggest connecting through a VPN.")

            Text("Codex isn't available in a few countries.")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(0.5)
                .foregroundStyle(Theme.faint)
        }
    }
}

// MARK: - Shared onboarding bits

/// The monospace-caps whisper label every onboarding screen opens with.
struct OnboardingWhisper: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .kerning(2)
            .foregroundStyle(Theme.faint)
    }
}

/// A green-dot "this step is done" line (shared: the login panel and the plan crossroads).
struct OnboardingDoneLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 11) {
            HealthDot(color: Theme.Ink.green)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.statusInk)
        }
    }
}

/// A mini spinner + mono-caps whisper — the quiet "something is happening on its own" line
/// (waiting for the browser sign-in, the background codex install, the upgrade watch).
struct MonoWaitLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .kerning(1.5)
                .foregroundStyle(Theme.faint)
        }
    }
}

/// The engine's latest streamed/status line — monospaced, colored by its ✓/✗ prefix (the same
/// convention the dev CodexSetupView renders).
struct OnboardingStatusText: View {
    let status: String?
    init(_ status: String?) { self.status = status }

    var body: some View {
        if let status {
            Text(status)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(status.hasPrefix("✓") ? Theme.Ink.green
                               : status.hasPrefix("✗") ? .red : Theme.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Onboarding — codex login panel") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingCodexLoginPanel(codexReady: true)
            .frame(maxWidth: 640)
            .padding(40)
    }
    .frame(width: 780, height: 500)
    .preferredColorScheme(.dark)
}
