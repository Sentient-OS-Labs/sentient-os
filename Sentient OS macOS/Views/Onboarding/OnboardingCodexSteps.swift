//
//  OnboardingCodexSteps.swift
//  Sentient OS macOS
//
//  Onboarding's codex step — a pure renderer over the SHARED CodexSetup engine (the same
//  instance the dev tools' CodexSetupView drives; zero setup logic lives here).
//
//  OnboardingCodexLoginView is purely the browser login: one button that opens the OAuth page,
//  then the screen NOTICES the finished sign-in on its own (a 2s `codex login status` poll while
//  the browser is out + a re-check on app foreground) — no "I'm done" button. Continue gates on
//  logged in. The CLI install happens in the BACKGROUND (AppState's launch kick); in the rare
//  case it hasn't finished yet, the login button stays greyed and the screen polls `codex --help`
//  (CodexCLI.isRunnable — the ground truth, not a path check) every 2s, un-greying the moment
//  codex actually answers. A silent same-engine re-kick is the safety net, so a failed or
//  skipped install can never dead-end the flow.
//
//  (Computer-use setup is deliberately NOT in onboarding — it happens later, elsewhere.)
//

import SwiftUI
import AppKit

// MARK: - Step: log in to codex

struct OnboardingCodexLoginView: View {
    let onContinue: () -> Void

    @State private var codex = CodexSetup.shared
    /// `codex --help` answered — the ground-truth install confirmation that un-greys the button.
    @State private var codexConfirmed = false

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            OnboardingWhisper("CONNECT CODEX")

            Text("Sign in with your ChatGPT account.\nSentient's cloud thinking runs through OpenAI's Codex, on your own plan.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            VStack(spacing: 16) {
                if codex.loggedIn {
                    OnboardingDoneLine("Logged in to Codex")
                } else if codex.loggingIn {
                    Text("Finish signing in in your browser. This screen notices on its own.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Ink.body)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("waiting for the browser sign-in…")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.faint)
                    }
                } else {
                    // The login button — greyed until `codex --help` confirms the install landed.
                    OnboardingNextButton(title: "Log in with ChatGPT", enabled: codexConfirmed) {
                        codex.startLogin()
                    }
                    if !codexConfirmed {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("installing codex in the background…")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .kerning(1.5)
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    OnboardingStatusText(codex.loginStatusLine)
                }
            }
            .frame(maxWidth: 560)

            OnboardingNextButton(title: "Continue", enabled: codex.loggedIn, action: onContinue)

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
        .onAppear {
            Task {
                await codex.refreshInstalled()
                // Two nets in one kick: no binary (the launch kick failed or skipped a half-deleted
                // setup) → install; binary present but the installer hasn't run this launch (the
                // launch kick deliberately skips USED setups) → run it anyway, because the installer
                // doubles as the updater and setup should hand the latest CLI to the later steps.
                if !codex.installing && (!codex.installed || !codex.ranInstallerThisLaunch) {
                    await codex.installCodex()
                }
            }
            Task { await codex.refreshLoginStatus() }
        }
        .task {
            // The confirmation poll: run `codex --help` now, then every 2s until it answers —
            // "command not found" (no binary) means the install is still going. On the normal
            // path this succeeds on the first try and the button is never seen greyed.
            while !Task.isCancelled {
                if await CodexCLI.isRunnable() {
                    await codex.refreshInstalled()   // align the shared engine's flag
                    withAnimation(.easeInOut(duration: 0.3)) { codexConfirmed = true }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: codex.loggingIn) {
            // The sign-in watcher (replaces the old "I've finished" button): while the browser
            // flow is out, quietly re-check `codex login status` every 2s — the section flips to
            // the green done line by itself the moment auth.json lands.
            guard codex.loggingIn else { return }
            while !Task.isCancelled, codex.loggingIn, !codex.loggedIn {
                try? await Task.sleep(for: .seconds(2))
                await codex.refreshLoginStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await codex.refreshLoginStatus() }   // back from the browser — often already done
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

/// A green-dot "this step is done" line (shared: the login step and the plan crossroads).
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

/// The engine's latest streamed/status line — monospaced, colored by its ✓/✗ prefix (the same
/// convention the dev CodexSetupView renders).
private struct OnboardingStatusText: View {
    let status: String?
    init(_ status: String?) { self.status = status }

    var body: some View {
        if let status {
            Text(status)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(status.hasPrefix("✓") ? Theme.Ink.green
                               : status.hasPrefix("✗") ? .red : Theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Onboarding — codex login") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingCodexLoginView(onContinue: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}

