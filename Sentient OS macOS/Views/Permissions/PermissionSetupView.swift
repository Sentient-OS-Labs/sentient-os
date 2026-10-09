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
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 26) { content }
                .padding(.top, 30)

            OnboardingNextButton(title: continueTitle, enabled: canContinue, action: onContinue)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 560)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

/// A nil Accessibility state omits that row when only Sentient's screen context is required.
/// These grants always belong to Sentient itself, independently of the computer-use helper.
struct SentientAppPermissionRows: View {
    var accessibility: Bool?
    let screen: Bool
    var accessibilityTitle = "Accessibility (act in your apps)"
    var accessibilityTip = "Lets Sentient read windows and act inside your apps in the background."

    var body: some View {
        SettingsGroup(label: "Sentient Permissions") {
            VStack(alignment: .leading, spacing: 2) {
                if let accessibility {
                    StatusLine(title: accessibilityTitle,
                               health: accessibility ? .ok : .bad,
                               note: accessibility ? "granted" : "not granted",
                               tip: accessibilityTip,
                               fixTitle: "Allow…") {
                        guard !accessibility else { return }
                        PermissionGuide.shared.guide(.accessibility, dragging: Bundle.main.bundleURL)
                    }
                }
                StatusLine(title: "Screen Recording (see the screen)",
                           health: screen ? .ok : .bad,
                           note: screen ? "granted" : "not granted",
                           tip: PrivacyCopy.screenCapture,
                           fixTitle: "Allow…") {
                    guard !screen else { return }
                    // Sentient may not be in Tahoe's list yet. The guide carries its app bundle.
                    PermissionGuide.shared.guide(.screenRecording, dragging: Bundle.main.bundleURL)
                }
            }
        }
    }

}
