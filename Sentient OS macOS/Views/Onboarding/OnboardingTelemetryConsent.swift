//
//  OnboardingTelemetryConsent.swift
//  Sentient OS macOS
//
//  The film's hood-park privacy block — "We never collect your personal info." over two
//  capsules, bottom-left on the hood Continue's row: Read More (the Settings Privacy Policy
//  sheet, PrivacyPolicyView, reused verbatim) and Configure Telemetry, which blooms a small
//  anchored card with the two anonymous-telemetry toggles (crash reports → Sentry ·
//  analytics → TelemetryDeck): the SAME @AppStorage keys as Settings → System, applied live
//  through CrashReporting/Analytics.applyEnabledChange(), so the choice made here IS the
//  Settings choice. Click anywhere outside dismisses; the film stays undimmed behind it.
//

import SwiftUI

struct OnboardingTelemetryConsent: View {
    /// The pill row's vertical center — the film view passes the hood Continue's
    /// page-measured y, so the pill and Continue read as one composed footer row.
    let rowCenterY: CGFloat

    /// Same keys as Settings → System (SystemPane) — the original `diagnosticsEnabled` name
    /// carries existing installs' crash-reports choice; analytics has its own key.
    @AppStorage("diagnosticsEnabled") private var crashReportsEnabled = true
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    @State private var open = false
    @State private var showPrivacyPolicy = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Click-outside dismiss: an invisible catcher over the film while the card
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
                // Center the ~52pt pill block on the Continue's y; the clamp keeps it
                // on-screen if the page ever reports a band below the viewport.
                .padding(.bottom, max(20, geo.size.height - rowCenterY - 26))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
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
                Text("Even with this off, Sentient keeps a bare minimum of anonymous telemetry: simple counts of app opens and feature use that are core to building Sentient. Never your content, never anything personal.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Ink.deepMuted)
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
    struct Host: View {
        @State private var height: CGFloat = 820
        var body: some View {
            ZStack {
                Theme.bg
                OnboardingTelemetryConsent(rowCenterY: height - 60)
            }
            .frame(width: 1180, height: height)
        }
    }
    return Host().preferredColorScheme(.dark)
}
#endif
