//
//  OnboardingTelemetryConsent.swift
//  Sentient OS macOS
//
//  The frontier-model page's privacy block — "We never collect your personal info." over two
//  capsules, bottom-left: Read More (the Settings Privacy Policy
//  sheet, PrivacyPolicyView, reused verbatim) and Configure Telemetry, which blooms a small
//  anchored card with the two anonymous-telemetry toggles (crash reports → Sentry ·
//  analytics → TelemetryDeck): the SAME @AppStorage keys as Settings → System, applied live
//  through CrashReporting/Analytics.applyEnabledChange(), so the choice made here IS the
//  Settings choice. Click anywhere outside dismisses; the model picker stays undimmed behind it.
//

import SwiftUI

struct OnboardingTelemetryConsent: View {
    /// Same keys as Settings → System (SystemPane) — the original `diagnosticsEnabled` name
    /// carries existing installs' crash-reports choice; analytics has its own key.
    @AppStorage("diagnosticsEnabled") private var crashReportsEnabled = true
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    @State private var open = false
    @State private var showPrivacyPolicy = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Click-outside dismiss: an invisible catcher over the picker while the card
            // is up. Sits UNDER the card/pill in this ZStack, so their controls keep
            // their own clicks.
            if open {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { setOpen(false) }
            }

            VStack(alignment: .leading, spacing: 12) {
                if open {
                    card
                        .transition(.scale(scale: 0.96, anchor: .bottomLeading)
                            .combined(with: .opacity))
                }
                pillBlock
            }
            .padding(.leading, 36)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onChange(of: crashReportsEnabled) { _, _ in CrashReporting.applyEnabledChange() }
        .onChange(of: analyticsEnabled) { _, _ in Analytics.applyEnabledChange() }
        .sheet(isPresented: $showPrivacyPolicy) { PrivacyPolicyView() }
    }

    // MARK: - The pill block (the Settings protection line over its two doors)

    private var pillBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("We never collect your personal info.")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            HStack(spacing: 10) {
                SettingsPillButton(title: "Read More") { showPrivacyPolicy = true }
                SettingsPillButton(title: "Configure Telemetry") { setOpen(!open) }
            }
        }
    }

    // MARK: - The anchored card (the two toggles, Settings dialect)

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            MonoCaps("Anonymous telemetry", size: 9.5, tracking: 2.4,
                     color: .white.opacity(0.7), weight: .semibold)
                .padding(.bottom, 8)
            SettingToggleLine(title: "Crash reports · Sentry",
                              sub: "Privacy-friendly, structure-only reports that help us fix your bugs; never your content.",
                              isOn: $crashReportsEnabled)
            SettingsHairline()
            SettingToggleLine(title: "Analytics · TelemetryDeck",
                              sub: "Anonymous usage signals through a privacy-first, open-source framework; never anything personal.",
                              isOn: $analyticsEnabled)
            if !analyticsEnabled {
                // The core-tier disclosure — keeps the switch honest (Analytics.swift,
                // Tier.core), same caption as Settings shows on opt-out.
                Text("Even with this off, Sentient still sends a handful of extremely anonymized usage-count pings: how many people use Sentient, and how often core features fire (Sidekick, proactive cards, overnight runs, home opens). Counts only, through a privacy-first, open-source tool, so a two-person team can see our work is being used. Never your content, never anything personal.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: analyticsEnabled)
        .padding(18)
        .frame(width: 330)
        .background(Theme.Ink.cardBG,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func setOpen(_ value: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { open = value }
    }
}

#if DEBUG
#Preview("Telemetry consent — pill + card") {
    ZStack {
        Theme.bg
        OnboardingTelemetryConsent()
    }
    .frame(width: 1180, height: 820)
    .preferredColorScheme(.dark)
}
#endif
