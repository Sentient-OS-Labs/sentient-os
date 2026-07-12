//
//  UninstallView.swift
//  Sentient OS macOS
//
//  The farewell sheet (Settings → System → Uninstall Sentient…). Four phases: the farewell
//  (the two-college-students note, the what-gets-removed manifest, Keep Sentient / the red
//  Uninstall as a uniform pill pair, Email the Founders below, the GitHub mark bottom-right),
//  the working teardown (Uninstall.Stage whispers over a quiet spinner), the helper-password
//  interstitial (Enter Password / Skip, Cancel as a quiet link — shown only when the admin
//  prompt is declined), and the gone screen (drag Sentient to the Trash, then Quit via
//  Uninstall.finishAndQuit). Drives System/Uninstall.swift; the teardown itself lives there.
//

import SwiftUI

struct UninstallView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    fileprivate enum Phase { case farewell, working, helperPrompt, gone }
    @State private var phase: Phase = .farewell
    @State private var stage: Uninstall.Stage = .helper
    /// Fulfilled by the interstitial's buttons while the teardown awaits a helper decision.
    @State private var helperResolver: ((Uninstall.HelperChoice) -> Void)?
    /// Feedback fallback: true briefly after the address was copied because no mail app answered.
    @State private var feedbackCopied = false

    init() {}

    /// Preview-only: open the sheet directly in a later phase.
    fileprivate init(previewPhase: Phase) { _phase = State(initialValue: previewPhase) }

    var body: some View {
        Group {
            switch phase {
            case .farewell:     farewell
            case .working:      working
            case .helperPrompt: helperPrompt
            case .gone:         gone
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 470)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(phase != .farewell)   // mid-teardown there's no walking away
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    // MARK: - Phase 1 · the farewell

    private var farewell: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Before you go.")
                .display(24).foregroundStyle(.white)
            prose("We’re two college students who built Sentient to push the bounds of what private, on-device LLM inference can do: understand your entire life, and proactively offer to help with anything you have going on. That future should be accessible to everyone, so Sentient is 100% open source and free forever.")
                .padding(.top, 14)
            prose("Something here didn’t land for you, and we would love to hear what. We read every note.")
                .padding(.top, 10)

            MonoCaps("Uninstalling removes", size: 9, tracking: 2.2, color: Theme.Ink.label, weight: .semibold)
                .padding(.top, 22)
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                GridRow {
                    manifestRow("cpu", "The on-device model")
                    manifestRow("book.closed", "Your knowledge base")
                }
                GridRow {
                    manifestRow("cloud", "The private cloud copy")
                    manifestRow("moon.zzz", "The overnight wake helper")
                }
            }
            .padding(.top, 12)

            HStack(spacing: 10) {
                FarewellPill(title: "Keep Sentient", style: .quiet) { dismiss() }
                FarewellPill(title: "Uninstall Sentient", style: .danger) { beginUninstall() }
            }
            .padding(.top, 26)

            feedbackButton
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { githubButton }
                .padding(.top, 16)
        }
    }

    /// The quiet GitHub mark in the sheet's bottom-right corner — the receipt for the
    /// "100% open source" line above it.
    private var githubButton: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/Sentient-OS-Labs/sentient-os")!)
        } label: {
            Image("GitHubMark")
                .resizable().scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(Theme.Ink.label)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help("Sentient OS on GitHub")
    }

    /// One line of the what-gets-removed manifest — a quiet symbol + body ink.
    private func manifestRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Ink.label)
                .frame(width: 15)
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
        }
    }

    // MARK: - Phase 2 · the teardown

    private var working: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps(stage.whisper, size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
                .id(stage)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: stage)
            Text("Taking Sentient apart, gently.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("Give us a moment. We are cleaning up after ourselves so nothing of ours is left behind.")
                .padding(.top, 14)
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.6))
                .padding(.top, 22)
        }
    }

    // MARK: - Phase 3 · the helper needs a password (only if the admin prompt was declined)

    private var helperPrompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("One more step", size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
            Text("This part needs your password.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("Sentient set up a small system helper so it could wake your Mac for the overnight run. macOS asks for your password to remove it; that is the same prompt you saw when it was installed. You can also skip it for now, and Sentient will still clear everything else.")
                .padding(.top, 14)
            HStack(spacing: 10) {
                FarewellPill(title: "Skip for Now", style: .quiet) { helperResolver?(.skip) }
                FarewellPill(title: "Enter Password", style: .bright) { helperResolver?(.retry) }
            }
            .padding(.top, 26)
            quietLink("Cancel Uninstall") { helperResolver?(.cancel) }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }

    /// The centered quiet text action that sits under a pill pair (Cancel Uninstall here;
    /// the feedback button is its sibling on the farewell and gone screens).
    private func quietLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Ink.bright.opacity(0.9))
        }
        .buttonStyle(PressScaleStyle())
    }

    // MARK: - Phase 4 · gone

    private var gone: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoCaps("All clear", size: 9.5, tracking: 2.4, color: .white.opacity(0.7), weight: .semibold)
            Text("Sentient is gone from this Mac.")
                .display(24).foregroundStyle(.white)
                .padding(.top, 12)
            prose("Everything Sentient made here has been removed. To finish, drag the Sentient OS app from your Applications folder to the Trash. Thank you for giving Sentient a try; it meant a lot to the two of us.")
                .padding(.top, 14)
            HStack(spacing: 10) {
                FarewellPill(title: "Show App in Finder", style: .quiet) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                FarewellPill(title: "Quit Sentient", style: .bright) { Uninstall.finishAndQuit() }
            }
            .padding(.top, 26)
            feedbackButton
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
    }

    // MARK: - The run

    private func beginUninstall() {
        phase = .working
        stage = .helper
        Task { @MainActor in
            let finished = await Uninstall.run(
                appState: appState,
                progress: { stage = $0 },
                helperDecision: {
                    await withCheckedContinuation { cont in
                        phase = .helperPrompt
                        helperResolver = { choice in
                            helperResolver = nil
                            phase = .working
                            cont.resume(returning: choice)
                        }
                    }
                })
            phase = finished ? .gone : .farewell   // a cancel backs out with nothing removed
        }
    }

    // MARK: - Shared bits

    private func prose(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(Theme.Ink.body)
            .lineSpacing(3.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var feedbackButton: some View {
        Button(action: shareFeedback) {
            HStack(spacing: 6) {
                Image(systemName: feedbackCopied ? "checkmark" : "envelope").font(.system(size: 10))
                Text(feedbackCopied ? "feedback@sentient-os.ai copied" : "Email the founders")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.Ink.bright.opacity(0.9))
        }
        .buttonStyle(PressScaleStyle())
        .animation(.easeInOut(duration: 0.2), value: feedbackCopied)
    }

    /// Open a pre-addressed compose in a real mail app. The naive `open(mailto:)` is not enough:
    /// when a BROWSER owns the mailto scheme (Chrome et al. — field-seen 2026-07-11), it reports
    /// success and then silently swallows the link unless the user once opted into its webmail
    /// handling. So: a dedicated mail app as handler → the default route; the handler is the web
    /// browser (or nothing) → Apple Mail directly; Mail missing too → copy the address and say so
    /// on the button. The click must never silently do nothing.
    private func shareFeedback() {
        let mailto = URL(string: "mailto:feedback@sentient-os.ai?subject=Sentient%20OS%20feedback")!
        let mailtoHandler = NSWorkspace.shared.urlForApplication(toOpen: mailto)
        let webHandler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)

        if let mailtoHandler, mailtoHandler != webHandler {
            Log("UninstallView: feedback compose via the default mail app (\(mailtoHandler.lastPathComponent))")
            NSWorkspace.shared.open(mailto)
        } else if let mailApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            Log("UninstallView: mailto handler is the web browser — opening Apple Mail directly")
            NSWorkspace.shared.open([mailto], withApplicationAt: mailApp,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { Task { @MainActor in copyFeedbackAddress() } }
            }
        } else {
            copyFeedbackAddress()
        }
    }

    private func copyFeedbackAddress() {
        Log("UninstallView: no mail app answered — copied the feedback address instead")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("feedback@sentient-os.ai", forType: .string)
        feedbackCopied = true
        Task { try? await Task.sleep(for: .seconds(4)); feedbackCopied = false }
    }

}

/// The sheet's one action shape — equal-width capsules that share a two-up row, so every
/// phase's choices sit as a uniform pair. Quiet for the safe choice, danger for the
/// destructive one, bright for the single primary (no halo: the glow is jewelry, and a
/// farewell is not the place to wear it). Local on purpose: Settings' small
/// SettingsPillButton stays the pane-level danger affordance.
private struct FarewellPill: View {
    enum Style { case quiet, danger, bright }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var ink: Color {
        switch style {
        case .quiet:  Theme.Ink.bright
        case .danger: Theme.Ink.red
        case .bright: .black
        }
    }
    private var fill: Color {
        switch style {
        case .quiet:  .white.opacity(0.07)
        case .danger: Theme.Ink.red.opacity(0.09)
        case .bright: .white
        }
    }
    private var stroke: Color {
        switch style {
        case .quiet:  .white.opacity(0.16)
        case .danger: Theme.Ink.red.opacity(0.42)
        case .bright: .clear
        }
    }
}

#Preview("Farewell") { UninstallView() }
#Preview("Working") { UninstallView(previewPhase: .working) }
#Preview("Helper prompt") { UninstallView(previewPhase: .helperPrompt) }
#Preview("Gone") { UninstallView(previewPhase: .gone) }
