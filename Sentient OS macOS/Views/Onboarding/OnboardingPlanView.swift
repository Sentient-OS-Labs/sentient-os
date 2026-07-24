//
//  OnboardingPlanView.swift
//  Sentient OS macOS
//
//  The plan crossroads — the step between codex login and the ready screen, and ONLY free/go
//  accounts ever see it: a full plan (plus/pro/team/…, or anything we can't read — fail open)
//  auto-advances before a single pixel renders. Free/go users get an honest fork: upgrade to
//  Plus (opens ChatGPT's pricing page, then this screen notices the upgrade on its own via
//  CodexAuth.refreshPlan — the same on-demand token re-mint codex does every 8 days), say they
//  ALREADY upgraded (a confirm, then we simply believe them — CodexAuth.assertedPlus; people
//  upgrade in their own browser and arrive here before any check could prove it), or continue
//  with just the knowledge base (sets CodexAuth.knowledgeBaseOnly, the app-wide limited-mode
//  gate). This screen sets expectations; the real conversion surface is the home's post-reveal
//  preview message, after they've seen the magic.
//

import SwiftUI
import AppKit

struct OnboardingPlanView: View {
    let onContinue: () -> Void
    /// Preview-only: skip the disk probe and render the crossroads for this plan.
    var previewPlan: CodexAuth.Plan? = nil

    private enum Phase { case checking, crossroads, waiting, unlocked }
    @State private var phase: Phase = .checking
    @State private var plan: CodexAuth.Plan?
    @State private var checkingUpgrade = false
    @State private var confirmingUpgrade = false

    private var planName: String { plan?.displayName ?? "Free" }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            switch phase {
            case .checking:
                Color.clear.frame(height: 1)   // invisible: full plans skip this screen entirely

            case .crossroads:
                OnboardingWhisper("Your ChatGPT plan · \(planName)")

                Text("We noticed you're not on ChatGPT Plus.")
                    .display(26)
                    .foregroundStyle(Theme.Ink.bright)

                // Two balanced single lines (no width cap — each takes its natural width, so
                // neither ever wraps into an orphan on a normal window).
                VStack(spacing: 6) {
                    Text("Right now, Sentient uses your ChatGPT plan's Codex frontier model for a small part of its compute.")
                    Text("You can still build your private knowledge base from this Mac and offer it to your AIs.")
                }
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

                VStack(alignment: .leading, spacing: 11) {
                    MonoCaps("With ChatGPT Plus", size: 9, tracking: 2.2, color: Theme.Ink.label)
                        .padding(.bottom, 3)
                    featureRow("sunrise", "Proactive mornings: things worth doing, already done")
                    featureRow("command", "Sidekick anywhere: hold right \u{2318} and just say it")
                    featureRow("moon.stars", "Gmail, Calendar, and a knowledge base that keeps learning")
                }

                VStack(spacing: 18) {
                    // The two ways forward, side by side: go buy it, or tell us you already did.
                    HStack(spacing: 16) {
                        GlowButton(title: "Upgrade on ChatGPT",
                                   systemImage: "arrow.up.forward",
                                   action: openUpgrade)
                        QuietPillButton(title: "I've upgraded to ChatGPT Plus", large: true) {
                            confirmingUpgrade = true
                        }
                    }
                    .frame(maxWidth: 540)
                    continueFreeButton
                }

            case .waiting:
                OnboardingWhisper("Your ChatGPT plan · \(planName)")

                Text("Finish upgrading in your browser.\nThis screen notices on its own.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("waiting for your upgrade…")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.faint)
                    }
                    // The trust path, not a check: the account can read Free here long after a
                    // real payment (the refreshed token re-mints from the same stale session),
                    // so the button takes the user's word — same confirm as the crossroads'.
                    OnboardingNextButton(title: "I've upgraded") {
                        confirmingUpgrade = true
                    }
                    continueFreeButton
                        .padding(.top, 8)
                }

            case .unlocked:
                OnboardingWhisper("Your ChatGPT plan · \(planName)")
                OnboardingDoneLine("\(planName) unlocked. Welcome to the full Sentient.")
            }

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
        .task {
            // The silent gate: read the claim off disk (no network). Anything but a positive
            // free/go read means this screen isn't for them.
            let current = previewPlan ?? CodexAuth.currentPlan()
            plan = current
            if current?.tier == .limited {
                Analytics.signal("PlanGate.shown", parameters: ["plan": current?.raw ?? "unknown"])
                withAnimation(.easeInOut(duration: 0.25)) { phase = .crossroads }
            } else {
                CodexAuth.knowledgeBaseOnly = false
                onContinue()
            }
        }
        .alert("Are you on ChatGPT Plus?", isPresented: $confirmingUpgrade) {
            Button("Yes, I'm on Plus!") { acceptSelfAttestedUpgrade() }
            Button("Wait", role: .cancel) { }
        } message: {
            Text("Sentient will unlock the full experience and take your word for it.\n\nNote that the ChatGPT Go plan does not offer enough Codex use to unlock the full experience.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the browser — quietly re-check, and auto-advance if the fresh claim
            // happens to read full. Always silent: the trust button is the real way forward.
            if phase == .waiting { check() }
        }
    }

    // MARK: Actions

    private func openUpgrade() {
        NSWorkspace.shared.open(CodexAuth.upgradeURL)
        withAnimation(.easeInOut(duration: 0.25)) { phase = .waiting }
    }

    /// "I've upgraded", confirmed — the trust path, and the ONLY user-driven way forward from
    /// either phase. A real payment can read Free here indefinitely (the refresh POST re-mints
    /// a token from the same stale session — only OpenAI's server knows the truth, and it checks
    /// at exec time), so we take the user's word and move on immediately: full mode, same as a
    /// verified Plus account. The refresh still fires, unawaited — if it lands, the claim on
    /// disk becomes true too and nothing downstream has to lean on the assertion.
    private func acceptSelfAttestedUpgrade() {
        CodexAuth.assertedPlus = true
        CodexAuth.knowledgeBaseOnly = false
        Analytics.signal("PlanGate.selfAttested", parameters: ["plan": plan?.raw ?? "unknown"])
        Task { _ = try? await CodexAuth.refreshPlan() }
        onContinue()
    }

    /// The silent focus-return check — CodexAuth.refreshPlan re-mints the token, and IF the
    /// fresh claim reads full the screen auto-advances. Best-effort only (the claim often stays
    /// stale after a real payment); the user's own way forward is the trust button above, so
    /// this never reports failure. Single in-flight.
    private func check() {
        guard !checkingUpgrade else { return }
        checkingUpgrade = true
        Task {
            defer { checkingUpgrade = false }
            let fresh: CodexAuth.Plan?
            do { fresh = try await CodexAuth.refreshPlan() }
            catch { return }   // network/refresh failure — stay quiet, the trust button carries
            if let fresh { plan = fresh }
            // Fail open like every other gate: an unreadable fresh claim counts as full.
            if fresh?.tier != .limited {
                CodexAuth.knowledgeBaseOnly = false
                Analytics.signal("PlanGate.upgraded")
                withAnimation(.easeInOut(duration: 0.3)) { phase = .unlocked }
                try? await Task.sleep(for: .seconds(1.4))
                onContinue()
            }
        }
    }

    /// The escape hatch — a real (grey) button, visible without competing with the glow CTA.
    private var continueFreeButton: some View {
        QuietPillButton(title: "Continue with just the knowledge base") {
            CodexAuth.knowledgeBaseOnly = true
            Analytics.signal("PlanGate.continuedFree")
            onContinue()
        }
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Ink.label)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.78))
        }
    }
}

#Preview("Onboarding — plan crossroads (Free)") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingPlanView(onContinue: {}, previewPlan: CodexAuth.Plan(raw: "free"))
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — plan crossroads (Go)") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingPlanView(onContinue: {}, previewPlan: CodexAuth.Plan(raw: "go"))
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
