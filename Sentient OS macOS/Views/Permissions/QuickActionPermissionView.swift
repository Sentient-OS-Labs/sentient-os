// Shared one-time setup for Summarize and Proofread, using the existing permission shell and rows.
// Refreshes real grants while visible; Done closes setup without replaying a screen/text request.
// Doc: Documentation - Permission Gate & Guide.md
import AppKit
import SwiftUI

struct QuickActionPermissionView: View {
    enum Feature {
        case summarize, summaryAccessibility, proofread

        var title: String {
            self != .proofread ? "Let Sentient summarize your screen" : "Let Sentient proofread your text"
        }
        var hasPermission: Bool {
            self == .summarize ? Permissions.hasScreenRecording() : Permissions.hasAccessibility()
        }
        var explanation: String {
            self == .summaryAccessibility ? "Allow Accessibility so Sentient can read the document you want summarized, including text beyond the screen." : self == .summarize
                ? "Allow Screen Recording so Sentient can read the screen you ask it to summarize. If macOS asks, quit and reopen Sentient."
                : "Allow Accessibility so Sentient can read and correct the text you select."
        }
        var readyHint: String {
            self != .proofread
                ? "You're ready. Return to the screen you want to summarize, then choose Summarize again."
                : "You're ready. Select the text you want to correct, then choose Proofread again."
        }
    }

    let feature: Feature
    let onDone: () -> Void
    var permissionCheck: (() -> Bool)? = nil
    @State private var granted = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                PermissionSetupView(title: feature.title,
                                    continueTitle: granted ? "Done" : "Grant permission to continue",
                                    canContinue: granted,
                                    onContinue: finish,
                                    compact: true, edgeGlow: true, availableSize: geometry.size) {
                    SentientAppPermissionRows(accessibility: feature != .summarize ? granted : nil,
                                             screen: feature == .summarize ? granted : nil,
                                             accessibilityTitle: "Accessibility",
                                             accessibilityTip: feature == .proofread ? "Lets Sentient read and correct your selected text." : "Lets Sentient read your active document, including offscreen text.",
                                             compact: true)
                    SettingsProse(granted ? feature.readyHint : feature.explanation)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onDone) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).padding(10)
                .accessibilityLabel("Close permission setup")
            }
        }
        .background(.black).ignoresSafeArea()
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() { granted = permissionCheck?() ?? feature.hasPermission }
    private func finish() {
        refresh()
        guard granted else { return }
        onDone()
    }
}
