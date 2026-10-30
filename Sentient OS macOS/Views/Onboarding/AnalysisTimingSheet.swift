// First analysis starts now after explicit wake/login setup. Pausing is always available
// in the app-owned analysis window; initial creation is never deferred to an overnight timer.
import SwiftUI

struct AnalysisTimingSheet: View {
    var viewportHeight: CGFloat = 540
    let onChoose: (ProcessingCoordinator.Timing) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backgroundReady = false
    @State private var sourcesReady = SourceSelection.selectionCount >= SourceSelection.minimumSelections
    @State private var starting = false
    @State private var startTask: Task<Void, Never>?
    @State private var setupChanged = false
    private var canContinue: Bool { sourcesReady && backgroundReady && !starting }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            MonoCaps("YOUR FIRST ANALYSIS", size: 9, tracking: 2, color: Theme.faint)
                            Text("Keep your knowledge up to date").display(27).foregroundStyle(.white)
                            Text("Start now and pause anytime. Enable these two settings for nightly updates after your first analysis finishes.")
                                .font(.system(size: 14)).foregroundStyle(Theme.secondary).lineSpacing(3)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        OvernightSetupRequirements { backgroundReady = $0 }
                        Text(CodexAuth.knowledgeBaseOnly
                             ? "Your first analysis may take over an hour. You can keep using Sentient while it runs."
                             : "Your first analysis may take over an hour. You can keep using Sidekick while it runs.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if !sourcesReady {
                            SettingsProse("Go back and choose at least three sources before starting analysis.")
                        } else if setupChanged {
                            SettingsProse("Background setup needs another look. Enable both settings above, then try again.")
                        }
                    }
                    .padding(28)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            HStack {
                Button("Back") { dismiss() }.buttonStyle(BackButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                OnboardingNextButton(title: starting ? "Checking setup…" : "Start analysis",
                                     enabled: canContinue, glow: 0.25, action: startAnalysis)
                    .accessibilityIdentifier("analysis.timing.continue")
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 560, height: viewportHeight)
        .background { PermissionWindowAtmosphere() }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                sourcesReady = SourceSelection.selectionCount >= SourceSelection.minimumSelections
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onDisappear { startTask?.cancel(); startTask = nil }
    }

    private func startAnalysis() {
        guard canContinue else { return }
        starting = true; setupChanged = false
        startTask = Task { @MainActor in
            defer { starting = false }
            let ready = await checkBackgroundSetup()
            guard !Task.isCancelled else { return }
            sourcesReady = SourceSelection.selectionCount >= SourceSelection.minimumSelections
            backgroundReady = ready
            guard sourcesReady && backgroundReady else { setupChanged = !backgroundReady; return }
            onChoose(.now)
        }
    }

    private func checkBackgroundSetup() async -> Bool {
        #if DEBUG
        if let fixture = OvernightWakeSetup.sourceFixtureReadiness { return fixture }
        #endif
        let login = await LoginItem.refresh()
        guard !Task.isCancelled else { return false }
        let wake = await WakeHelperClient.shared.healthProbe()
        return login && wake == .ready
    }
}

#Preview { AnalysisTimingSheet(onChoose: { _ in }) }
