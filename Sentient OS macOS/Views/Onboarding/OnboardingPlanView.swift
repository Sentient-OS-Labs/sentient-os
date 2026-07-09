//
//  OnboardingPlanView.swift
//  Sentient OS macOS
//
//  The plan crossroads — the step between codex login and the ready screen, and ONLY free/go
//  accounts ever see it: a full plan (plus/pro/team/…, or anything we can't read — fail open)
//  auto-advances before a single pixel renders. Free/go users get an honest fork: upgrade to
//  Plus (opens ChatGPT's pricing page, then this screen notices the upgrade on its own via
//  CodexAuth.refreshPlan — the same on-demand token re-mint codex does every 8 days), or
//  continue with just the knowledge base (sets CodexAuth.knowledgeBaseOnly, the app-wide
//  limited-mode gate). This screen sets expectations; the real conversion surface is the home's
//  post-reveal preview message, after they've seen the magic.
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
    @State private var statusLine: String?

    private var planName: String { plan?.displayName ?? "Free" }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            switch phase {
            case .checking:
                Color.clear.frame(height: 1)   // invisible: full plans skip this screen entirely

            case .crossroads:
                OnboardingWhisper("YOUR CHATGPT PLAN · \(planName.uppercased())")

                Text("We noticed you're not on ChatGPT Plus.")
                    .display(26)
                    .foregroundStyle(Theme.Ink.bright)

                Text("Sentient uses your ChatGPT plan's Codex frontier model for a small part of its compute. You can still build your private knowledge base from this Mac and offer it to your AIs. But to use all of Sentient, proactive mornings, Sidekick, Gmail and Calendar, a knowledge base that keeps learning, you'll need ChatGPT Plus.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 580)

                VStack(spacing: 18) {
                    GlowButton(title: "Upgrade on ChatGPT",
                               systemImage: "arrow.up.forward",
                               action: openUpgrade)
                        .frame(maxWidth: 380)
                    continueFreeButton
                }

            case .waiting:
                OnboardingWhisper("YOUR CHATGPT PLAN · \(planName.uppercased())")

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
                    OnboardingNextButton(title: checkingUpgrade ? "Checking…" : "I've upgraded",
                                         enabled: !checkingUpgrade) {
                        check(manual: true)
                    }
                    if let statusLine {
                        Text(statusLine)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 480)
                    }
                    continueFreeButton
                        .padding(.top, 8)
                }

            case .unlocked:
                OnboardingWhisper("YOUR CHATGPT PLAN · \(planName.uppercased())")
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from the browser — quietly re-check. Silent when still free (they may just
            // be reading the pricing page); only the manual button reports a "still free" result.
            if phase == .waiting { check() }
        }
    }

    // MARK: Actions

    private func openUpgrade() {
        NSWorkspace.shared.open(CodexAuth.upgradeURL)
        statusLine = nil
        withAnimation(.easeInOut(duration: 0.25)) { phase = .waiting }
    }

    /// The upgrade check — CodexAuth.refreshPlan re-mints the token so a just-paid upgrade shows
    /// up immediately (the claim on disk would otherwise lag on codex's 8-day timer). Single
    /// in-flight; focus-return calls stay quiet on failure, the manual button explains itself.
    private func check(manual: Bool = false) {
        guard !checkingUpgrade else { return }
        checkingUpgrade = true
        if manual { statusLine = nil }
        Task {
            defer { checkingUpgrade = false }
            do {
                let fresh = try await CodexAuth.refreshPlan()
                if let fresh { plan = fresh }
                if fresh?.tier != .limited {
                    CodexAuth.knowledgeBaseOnly = false
                    Analytics.signal("PlanGate.upgraded")
                    withAnimation(.easeInOut(duration: 0.3)) { phase = .unlocked }
                    try? await Task.sleep(for: .seconds(1.4))
                    onContinue()
                } else if manual {
                    statusLine = "Still seeing \(fresh?.displayName ?? planName) on your account. It can take a minute after paying; try again shortly."
                }
            } catch {
                if manual { statusLine = "Couldn't check right now; try again in a moment." }
            }
        }
    }

    /// The quiet escape hatch — free users still get the knowledge base, honestly framed.
    private var continueFreeButton: some View {
        Button {
            CodexAuth.knowledgeBaseOnly = true
            Analytics.signal("PlanGate.continuedFree")
            onContinue()
        } label: {
            Text("Continue with just the knowledge base")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .underline(true, color: Theme.stroke)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
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
