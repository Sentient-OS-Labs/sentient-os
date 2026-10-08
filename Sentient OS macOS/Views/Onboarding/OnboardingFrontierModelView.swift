//
//  OnboardingFrontierModelView.swift
//  Sentient OS macOS
//
//  Onboarding's frontier-model step (grew out of the codex-login-only screen, 2026-07-25): the
//  five engine pills in one centered row over the SAME per-engine panels Settings renders
//  (FrontierEnginePicker), with the live codex login embedded as the ChatGPT panel
//  (OnboardingCodexLoginPanel). Continue prepares and commits a signed-in Claude choice;
//  other choices must already be the active, healthy engine, including the selected custom
//  preset. Every choice prepares its CLI, so an existing login cannot bypass its update check.
//  Joins shared Codex preparation at launch; browsing tabs never changes the saved engine.
//  Doc: Views/Onboarding/Documentation - Onboarding.md
//

import SwiftUI
import AppKit

struct OnboardingFrontierModelView: View {
    let onContinue: () -> Void

    @State private var codex = CodexSetup.shared
    @State private var claude = ClaudeSetup.shared
    @State private var tab: FrontierEngineTab = .chatgpt
    @State private var continueAttempt: UUID?
    @State private var continueTask: Task<Void, Never>?
    @State private var continueStatus: String?
    private var continuing: Bool { continueAttempt != nil }
    private var enginePreparing: Bool {
        tab == .claude
            ? claude.preparing || claude.installing
            : codex.preparing || codex.installing
    }

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    @AppStorage(CustomProvider.presetKey) private var presetRaw = CustomProvider.Preset.openRouter.rawValue
    /// Observed so a passing Test & Select re-evaluates `engineReady` in place.
    @AppStorage(CustomProvider.visionVerifiedKey) private var visionVerified = false

    private var activeTab: FrontierEngineTab {
        FrontierEngineTab(backend: ModelBackend(rawValue: backendRaw) ?? .chatgpt,
                          preset: CustomProvider.Preset(rawValue: presetRaw) ?? .openRouter)
    }

    /// Claude needs a login; Continue prepares and commits it. Other displayed engines must
    /// already be committed and healthy, including a passing Test & Select for custom endpoints.
    private var engineReady: Bool {
        _ = visionVerified
        if tab == .claude { return claude.loggedIn }
        guard tab == activeTab else { return false }
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

                        Text(PrivacyCopy.frontierSummary)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .frame(maxWidth: 640)
                    }

                    FrontierEnginePicker(tab: $tab, layout: .singleRow,
                                         chatgptHealthy: codex.loggedIn) {
                        OnboardingCodexLoginPanel()
                    }

                    if tab != .claude {
                        if codex.preparing || codex.installing { MonoWaitLine("preparing codex…") }
                        OnboardingStatusText(codex.installStatus)
                    }

                    OnboardingStatusText(continueStatus)

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
            InviteRedemptionView(startsCollapsed: true)
                .frame(width: 320)
                .padding(.trailing, 36).padding(.bottom, 28)
        }
        .onAppear {
            // Join launch preparation, including adoption of a portable existing login into
            // the private runtime. A legacy CLI's login alone cannot make this screen ready.
            Task {
                _ = await codex.ensureCurrent()
                await codex.refreshLoginStatus()
            }
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
        .onChange(of: presetRaw) { cancelContinue() }
        .onChange(of: tab) { cancelContinue() }
        .onDisappear { cancelContinue() }
    }

    private func continueWithEngine() {
        guard engineReady, !continuing else { return }
        let initialBackend = backendRaw
        let selectedTab = tab
        let attempt = UUID()
        continueStatus = nil
        continueAttempt = attempt
        continueTask = Task {
            defer {
                if continueAttempt == attempt { continueAttempt = nil; continueTask = nil }
            }
            let prepared: Bool
            if selectedTab == .claude {
                prepared = await claude.ensureCurrent()
            } else {
                prepared = await codex.ensureCurrent()
            }
            guard !Task.isCancelled, continueAttempt == attempt,
                  backendRaw == initialBackend, tab == selectedTab else { return }
            guard prepared else {
                continueStatus = selectedTab == .claude
                    ? claude.installStatus ?? "✗ Claude Code couldn't be prepared. Try again."
                    : codex.installStatus ?? "✗ Codex couldn't be prepared. Try again."
                return
            }
            if selectedTab == .claude {
                await claude.refreshLoginStatus()
            } else if selectedTab == .chatgpt {
                await codex.refreshLoginStatus()
            }
            // The user can browse or select another engine while preparation is in flight.
            guard !Task.isCancelled, continueAttempt == attempt,
                  backendRaw == initialBackend, tab == selectedTab else { return }
            guard engineReady else {
                continueStatus = "✗ Sign in to your selected provider, then try Continue again."
                return
            }
            // Commit only after preparation and a fresh login check succeed, immediately
            // before navigation so the next step sees the selected provider.
            if selectedTab == .claude { backendRaw = ModelBackend.claude.rawValue }
            onContinue()
        }
    }

    private func cancelContinue() {
        continueTask?.cancel()
        continueTask = nil
        continueAttempt = nil
        continueStatus = nil
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
