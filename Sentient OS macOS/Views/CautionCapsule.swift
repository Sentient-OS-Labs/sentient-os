//
//  CautionCapsule.swift
//  Sentient OS macOS
//
//  The banner capsule for the home's single top-right slot: amber for the morning-after
//  caution, red for a live HealthCaution issue, green for the just-updated notice. Message +
//  optional action pill + dismiss ✕. UpdateNoticeCapsule is the self-contained green variant
//  (reads/retires UpdateNotice itself) — rendered by the home's banner slot AND overlaid on
//  onboarding by RootView, the second render site that moved this out of HomeView.swift.
//

import SwiftUI

struct CautionCapsule: View {
    let message: LocalizedStringKey
    var accent: Color = Theme.Ink.amber
    var actionTitle: LocalizedStringKey? = nil
    var onAction: () -> Void = {}
    let onDismiss: () -> Void

    /// Health / overnight caution messages live as English catalog keys in Foundation types.
    init(messageKey: String, accent: Color = Theme.Ink.amber,
         actionTitle: LocalizedStringKey? = nil,
         onAction: @escaping () -> Void = {}, onDismiss: @escaping () -> Void) {
        self.message = LocalizedStringKey(stringLiteral: messageKey)
        self.accent = accent
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    init(message: LocalizedStringKey, accent: Color = Theme.Ink.amber,
         actionTitle: LocalizedStringKey? = nil,
         onAction: @escaping () -> Void = {}, onDismiss: @escaping () -> Void) {
        self.message = message
        self.accent = accent
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HealthDot(color: accent)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Ink.statusInk)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                SettingsPillButton(title: actionTitle, action: onAction)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Ink.label)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: 480, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(accent.opacity(0.28), lineWidth: 1))
    }
}

/// The green "Sentient just updated!" capsule — self-contained: reads UpdateNotice on
/// appearance, draws nothing when no notice is armed, and retires it on dismiss or on
/// opening the changelog. Hosts decide placement; this owns everything else.
struct UpdateNoticeCapsule: View {
    @State private var armed = false

    var body: some View {
        Group {
            if armed {
                CautionCapsule(message: "Sentient just updated!",
                               accent: Theme.Ink.green,
                               actionTitle: "Read the changelog",
                               onAction: {
                                   UpdateNotice.openChangelog()
                                   retire()
                               },
                               onDismiss: {
                                   UpdateNotice.dismiss()
                                   retire()
                               })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { armed = UpdateNotice.pending != nil }
    }

    private func retire() {
        withAnimation(.easeInOut(duration: 0.25)) { armed = false }
    }
}

#Preview("Caution capsules") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(alignment: .trailing, spacing: 14) {
            CautionCapsule(messageKey: OvernightCaution.Kind.loggedOut.message,
                           actionTitle: "Open Settings", onAction: {}, onDismiss: {})
            CautionCapsule(messageKey: OvernightCaution.Kind.noInternet.message, onDismiss: {})
            CautionCapsule(messageKey: OvernightCaution.Kind.usageLimit.message, onDismiss: {})
            CautionCapsule(messageKey: HealthCaution.Issue.permissions([.fullDiskAccess]).message,
                           accent: Theme.Ink.red,
                           actionTitle: "Open Settings", onAction: {}, onDismiss: {})
            CautionCapsule(messageKey: HealthCaution.Issue.permissions([.fullDiskAccess, .launchAtLogin]).message,
                           accent: Theme.Ink.red,
                           actionTitle: "Open Settings", onAction: {}, onDismiss: {})
            CautionCapsule(messageKey: HealthCaution.Issue.codexSignedOut.message,
                           accent: Theme.Ink.red,
                           actionTitle: "Open Settings", onAction: {}, onDismiss: {})
            CautionCapsule(messageKey: HealthCaution.Issue.computerUseBroken(payloadGone: true).message,
                           accent: Theme.Ink.red,
                           actionTitle: "Open Settings", onAction: {}, onDismiss: {})
            CautionCapsule(message: "Sentient just updated!",
                           accent: Theme.Ink.green,
                           actionTitle: "Read the changelog", onAction: {}, onDismiss: {})
        }
        .padding(40)
    }
    .frame(width: 620, height: 620)
    .preferredColorScheme(.dark)
}
