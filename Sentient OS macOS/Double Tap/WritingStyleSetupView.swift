//
// WritingStyleSetupView.swift
// The introduction sheet for existing knowledge bases: runs the same collector as initial
// processing, with cancellation and an explicit retry after failures. Hidden for now: RootView
// runs the same setup silently in the background instead, and this sheet waits for the
// introduction to return.
// Doc: Documentation - Double Tap.md
//

import SwiftUI

struct WritingStyleSetupView: View {
    var runsSetup = true
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0
    @State private var status = "Gathering examples of how you write…"
    @State private var failure: String?
    @State private var finished = false

    var body: some View {
        VStack(spacing: 22) {
            Orb(mode: failure == nil ? (finished ? .idle : .processing) : .attention, size: 72)
                .frame(height: 108)
            Text(finished ? "Double Tap is ready" : "Setting up double tap")
                .display(30)
                .foregroundStyle(.white)
            Text(failure ?? (finished ? "Double tap \(SidekickHotkey.current.label) in a reply box to write in your own voice." : status))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            if finished {
                primaryButton("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else if failure != nil {
                HStack(spacing: 18) {
                    Button("Open Settings") {
                        dismiss()
                        HomeWindowOpening.open(.settings, settingsPane: .doubleTap)
                    }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    primaryButton("Try again") { attempt += 1 }.keyboardShortcut(.defaultAction)
                }
            }
            if !finished {
                Text(PrivacyCopy.writingSetup)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(44)
        .frame(width: 500)
        .frame(minHeight: 380)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .task(id: attempt) {
            guard runsSetup else { return }
            failure = nil
            do {
                try await WritingStyle.generateIfNeeded { line in
                    Task { @MainActor in status = line }
                }
                try Task.checkCancellation()
                finished = true
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if let known = (error as? WritingStyle.Failure)?.errorDescription {
                    failure = known
                } else {
                    failure = Self.engineFailure(await OvernightCaution.classify(error))
                }
                Log("WritingStyle: setup failed (\(ErrorLabel(error)))")
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 26).padding(.vertical, 10)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension WritingStyleSetupView {
    /// The processing screen's vocabulary: a classified engine problem is named, anything else
    /// gets the generic line.
    static func engineFailure(_ kind: OvernightCaution.Kind?) -> String {
        let claude = ModelBackend.current == .claude
        return switch kind {
        case .usageLimit: "We hit \(claude ? "Claude's" : "ChatGPT's") usage limit. It resets on its own; try again in a while."
        case .loggedOut: claude ? "Claude isn't signed in. Sign in from Settings, then try again."
                                : "Codex isn't logged in. Log in from Settings, then try again."
        case .noInternet: "No internet connection. Once you're back online, try again."
        case .connectorAuth: "A connected app needs a fresh sign-in. Reconnect it in Settings, then try again."
        default: "Setup couldn’t finish. Check your AI and source connections in Settings, then try again."
        }
    }
}

#Preview { WritingStyleSetupView(runsSetup: false) }
