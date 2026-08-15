//
//  OnboardingFrontierModelView.swift
//  Sentient OS macOS
//
//  Onboarding's frontier-model step (grew out of the codex-login-only screen, 2026-07-25): the
//  five engine pills in one centered row over the SAME per-engine panels Settings renders
//  (FrontierEnginePicker), with the live codex login embedded as the ChatGPT panel
//  (OnboardingCodexLoginPanel). Continue gates on the ACTIVE engine being healthy — ChatGPT
//  logged in, or a custom endpoint that passed Test & Select — and browsing tabs never disturbs
//  the active engine. The codex CLI install kick + `codex --help` confirmation poll live HERE,
//  not in the ChatGPT panel: the CLI is the engine room even for custom endpoints (the vision
//  probe runs through `codex exec`), so Test & Select greys until it answers, whatever tab the
//  user is on.
//

import SwiftUI
import AppKit

struct OnboardingFrontierModelView: View {
    let onContinue: () -> Void

    @State private var codex = CodexSetup.shared
    /// `codex --help` answered — the ground-truth install confirmation (feeds the login button
    /// AND the custom panels' Test & Select).
    @State private var codexConfirmed = false

    @AppStorage(ModelBackend.key) private var backendRaw = ModelBackend.chatgpt.rawValue
    /// Observed so a passing Test & Select re-evaluates `engineReady` in place.
    @AppStorage(CustomProvider.visionVerifiedKey) private var visionVerified = false

    /// The one Continue gate: the ACTIVE engine is healthy. ChatGPT = logged in to codex;
    /// a custom endpoint = configured AND vision-verified (a passing Test & Select).
    private var engineReady: Bool {
        _ = visionVerified
        return ModelBackend(rawValue: backendRaw) == .custom
            ? CustomProvider.current.isUsable
            : codex.loggedIn
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

                        Text("Sentient's on-device model does about 90% of the thinking. The last 10%, the reasoning behind proactive intelligence, runs on a frontier model of your choice.")
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .frame(maxWidth: 640)
                    }

                    FrontierEnginePicker(layout: .singleRow,
                                         chatgptHealthy: codex.loggedIn,
                                         codexReady: codexConfirmed) {
                        OnboardingCodexLoginPanel(codexReady: codexConfirmed)
                    }

                    // The quiet reward: the halo lights only once an engine is actually
                    // ready (GlowHalo's `active` rides `enabled`), at the armed-CTA subtlety.
                    OnboardingNextButton(title: "Continue", enabled: engineReady,
                                         glow: 0.28, action: onContinue)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            OnboardingTrustFooter()
        }
        .onAppear {
            Task {
                await codex.refreshInstalled()
                // No binary (the launch kick failed or skipped a half-deleted setup) → retry via
                // ensureInstalled, which surfaces the manual-install panel if it gives up. Binary
                // already present but the installer hasn't run this launch → run it anyway (it
                // doubles as the updater, handing the latest CLI to the later steps).
                if !codex.installed {
                    await codex.ensureInstalled()
                } else if !codex.ranInstallerThisLaunch {
                    await codex.installCodex()
                }
            }
            Task { await codex.refreshLoginStatus() }
        }
        .task {
            // The confirmation poll: run `codex --help` now, then every 2s until it answers —
            // "command not found" (no binary) means the install is still going. On the normal
            // path this succeeds on the first try and nothing is ever seen greyed.
            while !Task.isCancelled {
                if await CodexCLI.isRunnable() {
                    await codex.refreshInstalled()   // align the shared engine's flag
                    withAnimation(.easeInOut(duration: 0.3)) { codexConfirmed = true }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the browser — often already signed in. Step-level on purpose: the
            // ChatGPT panel (and its own watcher) may not exist while another tab is showing.
            Task { await codex.refreshLoginStatus() }
        }
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
