// Presents free Sentient-hosted inference as a visible choice before subscription setup.
// Opens the existing hosted panel; only that panel's explicit activation saves the provider.
// Doc: Views/Onboarding/Documentation - Onboarding.md

import SwiftUI

struct OnboardingHostedUsageButton: View {
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.Ink.bright)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        Text("Sentient hosted usage")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Ink.bright)
                        MonoCaps("free", size: 8, tracking: 1.4, color: Theme.Ink.body)
                        if active { HealthDot(color: Theme.Ink.green) }
                    }
                    Text("No subscription needed. Up to 60 active Sidekick minutes a day.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                Image(systemName: selected ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.elevated : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(selected ? 0.28 : 0.16), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityIdentifier("onboarding.hostedUsage")
        .accessibilityLabel("Sentient hosted usage, free")
        .accessibilityHint("Shows hosted setup, included usage, and privacy details. No subscription needed.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview("Hosted usage choice") {
    VStack(spacing: 18) {
        OnboardingHostedUsageButton(selected: false, active: false, action: {})
        OnboardingHostedUsageButton(selected: true, active: true, action: {})
    }
    .padding(30)
    .frame(width: 604)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}
