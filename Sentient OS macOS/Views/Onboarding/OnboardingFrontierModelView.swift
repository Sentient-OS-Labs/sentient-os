//
//  OnboardingFrontierModelView.swift
//  Sentient OS macOS
//
//  Onboarding's frontier-model step (grew out of the codex-login-only screen, 2026-07-25): the
//  five engine pills in one centered row over the SAME per-engine panels Settings renders
//  (FrontierEnginePicker), with the live codex login embedded as the ChatGPT panel
//  (OnboardingCodexLoginPanel). Continue gates on the ACTIVE engine being healthy — ChatGPT
//  logged in, or a custom endpoint that passed Test & Select. Continue also prepares the CLI
//  through its shared setup engine, so an existing login cannot bypass its update check.
//  Browsing tabs only detects state; downloads start at a commitment action.
//  Doc: Views/Onboarding/Documentation - Onboarding.md
//

import SwiftUI
import AppKit

struct OnboardingFrontierModelView: View {
    let onContinue: () -> Void

    @State private var codex = CodexSetup.shared
    @State private var claude = ClaudeSetup.shared
    @State private var continueAttempt: UUID?
    @State private var continueTask: Task<Void, Never>?
    private var continuing: Bool { continueAttempt != nil }
    private var enginePreparing: Bool {
        backendRaw == ModelBackend.claude.rawValue
            ? claude.preparing || claude.installing
            : codex.preparing || codex.installing
    }

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    /// Observed so a passing Test & Select re-evaluates `engineReady` in place.
    @AppStorage(CustomProvider.visionVerifiedKey) private var visionVerified = false

    /// The one Continue gate: the ACTIVE engine is healthy. ChatGPT = logged in to codex;
    /// Claude = logged in to Claude Code; a custom endpoint = configured AND vision-verified
    /// (a passing Test & Select).
    private var engineReady: Bool {
        _ = visionVerified
        switch ModelBackend(rawValue: backendRaw) ?? .chatgpt {
        case .custom:  return CustomProvider.current.isUsable
        case .claude:  return claude.loggedIn
        case .chatgpt: return codex.loggedIn
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top-anchored, not vertically centered: panels differ in height, and re-centering
            // on every tab switch made the header and pills jump. Anchored, only the area
            // below the pills changes; the ScrollView carries the tall endpoint panels.
            ScrollView {
                VStack(spacing: 34) {
                    VStack(spacing: 14) {
                        OnboardingWhisper("FRONTIER MODEL")

                        Text("Choose your frontier model")
                            .display(26)
                            .foregroundStyle(Theme.Ink.bright)

                        Text("Sentient's on-device model understands your life. Proactive Intelligence and Sidekick run on a frontier model of your choice.")
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .frame(maxWidth: 640)
                    }

                    FrontierEnginePicker(layout: .singleRow,
                                         chatgptHealthy: codex.loggedIn) {
                        OnboardingCodexLoginPanel()
                    }

                    if backendRaw != ModelBackend.claude.rawValue {
                        if codex.preparing || codex.installing { MonoWaitLine("preparing codex…") }
                        OnboardingStatusText(codex.installStatus)
                    }

                    // The quiet reward: the halo lights only once an engine is actually
                    // ready (GlowHalo's `active` rides `enabled`), at the armed-CTA subtlety.
                    OnboardingNextButton(title: "Continue",
                                         enabled: engineReady && !continuing && !enginePreparing,
                                         glow: 0.28, action: continueWithEngine)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            // Keep room for the persistent bottom-left privacy controls even when a tall
            // custom-provider panel scrolls. The expanded telemetry card overlays the page.
            Color.clear.frame(height: 160)
        }
        .overlay { OnboardingTelemetryConsent() }
        .overlay(alignment: .bottomTrailing) {
            InviteRedemptionView()
                .frame(width: 320)
                .padding(.trailing, 36).padding(.bottom, 28)
        }
        .onAppear {
            // Detection only — NO install kicks here (decision 2026-08-21): each engine's CLI
            // downloads lazily when the user actually picks it (a pill click or a panel's
            // sign-in action), so a Claude user never downloads codex, and vice versa.
            Task { await codex.refreshInstalled() }
            Task { await codex.refreshLoginStatus() }
            Task {
                await claude.refreshInstalled()
                await claude.refreshLoginStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the browser — often already signed in. Step-level on purpose: the
            // ChatGPT panel (and its own watcher) may not exist while another tab is showing.
            Task {
                await codex.refreshInstalled()
                await codex.refreshLoginStatus()
            }
            Task {
                await claude.refreshInstalled()
                await claude.refreshLoginStatus()
            }
        }
        .onChange(of: backendRaw) { cancelContinue() }
        .onDisappear { cancelContinue() }
    }

    private func continueWithEngine() {
        guard engineReady, !continuing else { return }
        let selectedBackend = backendRaw
        let attempt = UUID()
        continueAttempt = attempt
        continueTask = Task {
            defer {
                if continueAttempt == attempt { continueAttempt = nil; continueTask = nil }
            }
            if selectedBackend == ModelBackend.claude.rawValue {
                guard await claude.ensureCurrent(), !Task.isCancelled else { return }
                await claude.refreshLoginStatus()
            } else {
                guard await codex.ensureCurrent(), !Task.isCancelled else { return }
                if selectedBackend == ModelBackend.chatgpt.rawValue { await codex.refreshLoginStatus() }
            }
            // The user can browse or select another engine while preparation is in flight.
            guard !Task.isCancelled, backendRaw == selectedBackend, engineReady else { return }
            onContinue()
        }
    }

    private func cancelContinue() {
        continueTask?.cancel()
        continueTask = nil
        continueAttempt = nil
    }
}

#Preview("Onboarding — frontier model") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingFrontierModelView(onContinue: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
