// Shared sign-in link copy action, with short feedback that resets for each login attempt.
// Copying never launches or restarts a login. The waiting status stays in the owning panel.
// Doc: Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI
import AppKit

struct LoginLinkButton: View {
    let url: URL?
    @State private var copied = false
    @State private var copyFailed = false
    @State private var feedbackID: UUID?

    private var title: String { copied ? "Copied" : "Copy link" }

    var body: some View {
        VStack(spacing: 8) {
            OnboardingNextButton(title: title, enabled: url != nil,
                                 minimumLabelWidth: 146, action: copy)
            if copyFailed {
                Text("Couldn't copy the link. Please try again.")
                    .font(.system(size: 12)).foregroundStyle(Theme.Ink.red)
            }
        }
        .frame(maxWidth: .infinity)
        .help("Copy the sign-in link to open it in another browser on this Mac.")
        .accessibilityLabel(copied ? "Sign-in link copied" : "Copy sign-in link")
        .onChange(of: url) { _, _ in resetFeedback() }
        .task(id: feedbackID) {
            guard feedbackID != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            resetFeedback()
        }
    }

    private func copy() {
        guard let url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(url.absoluteString, forType: .string)
        copyFailed = !copied
        feedbackID = UUID()
    }

    private func resetFeedback() {
        copied = false
        copyFailed = false
        feedbackID = nil
    }
}

#Preview("Sign-in link waiting") {
    VStack(alignment: .leading, spacing: 14) {
        LoginLinkButton(url: URL(string: "https://example.com"))
        Text("Finish signing in in your browser.")
            .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
        MonoWaitLine("waiting for the browser sign-in…")
    }
    .padding(40).frame(width: 640).background(Theme.bg).preferredColorScheme(.dark)
}
