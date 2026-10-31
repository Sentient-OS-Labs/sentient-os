// Shared setup window layout and Sentient's own permission rows for Double Tap and computer use.
// PermissionSetupView owns the presentation; SentientAppPermissionRows opens the existing grant flows.
// Doc: Documentation - Permission Gate & Guide.md

import SwiftUI
import AppKit

struct PermissionSetupView<Content: View>: View {
    let title: String
    let continueTitle: String
    let canContinue: Bool
    let onContinue: () -> Void
    var compact = false
    var edgeGlow = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWhisper("ONE-TIME SETUP")
                .frame(maxWidth: .infinity)

            Text(title)
                .display(23)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, compact ? 14 : 18)

            VStack(alignment: .leading, spacing: 26) { content }
                .padding(.top, compact ? 24 : 30)

            OnboardingNextButton(title: continueTitle, enabled: canContinue, action: onContinue)
                .frame(maxWidth: .infinity)
                .padding(.top, compact ? 24 : 32)
        }
        .padding(.horizontal, compact ? 32 : 44)
        .padding(.top, compact ? 26 : 34)
        .padding(.bottom, 24)
        .frame(width: compact ? 480 : 560)
        .background {
            if edgeGlow { PermissionWindowAtmosphere() }
            else { Color.black }
        }
        .preferredColorScheme(.dark)
    }
}

/// Setup focuses on remaining steps; Debug keeps every row available for inspection.
nonisolated enum PermissionSetupPresentation {
    static func showsGrant(_ granted: Bool, compact: Bool) -> Bool {
        #if DEBUG
        return true
        #else
        return !compact || !granted
        #endif
    }
}

struct PermissionSetupGroup<Content: View>: View {
    let label: String
    let compact: Bool
    var showsHeading = true
    @ViewBuilder var content: Content

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 9) {
                if showsHeading {
                    MonoCaps(label, size: 8.5, tracking: 2.0, color: Theme.Ink.label, weight: .semibold)
                }
                content
            }
        }
        else { SettingsGroup(label: label) { content } }
    }
}

/// A nil Accessibility state omits that row when only Sentient's screen context is required.
/// These grants always belong to Sentient itself, independently of the computer-use helper.
struct SentientAppPermissionRows: View {
    var accessibility: Bool?
    let screen: Bool
    var accessibilityTitle = "Accessibility (act in your apps)"
    var accessibilityTip = "Lets Sentient read windows and act inside your apps in the background."
    var compact = false
    var onPermissionChange: (() -> Void)?

    var body: some View {
        if PermissionSetupPresentation.showsGrant(screen, compact: compact)
            || accessibility.map({ PermissionSetupPresentation.showsGrant($0, compact: compact) }) == true {
            PermissionSetupGroup(label: "Sentient Permissions", compact: compact) {
                VStack(alignment: .leading, spacing: 2) {
                    if let accessibility, PermissionSetupPresentation.showsGrant(accessibility, compact: compact) {
                        StatusLine(title: accessibilityTitle,
                                   health: accessibility ? .ok : .bad,
                                   note: accessibility ? "granted" : (compact ? "" : "not granted"),
                                   tip: accessibilityTip,
                                   fixTitle: compact ? "Grant" : "Allow…") {
                            guard !accessibility else { return }
                            onPermissionChange?()
                            PermissionGuide.shared.guide(.accessibility, dragging: Bundle.main.bundleURL)
                        }
                    }
                    if PermissionSetupPresentation.showsGrant(screen, compact: compact) {
                        StatusLine(title: compact ? "Screen Recording" : "Screen Recording (see the screen)",
                                   health: screen ? .ok : .bad,
                                   note: screen ? "granted" : (compact ? "" : "not granted"),
                                   tip: PrivacyCopy.screenCapture,
                                   fixTitle: compact ? "Grant" : "Allow…") {
                            guard !screen else { return }
                            onPermissionChange?()
                            // Sentient may not be in Tahoe's list yet. The guide carries its app bundle.
                            PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
                        }
                    }
                }
            }
        }
    }

}
