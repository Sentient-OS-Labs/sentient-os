// The final onboarding choice. Both options unlock Home; battery checks apply to the work,
// never to Sidekick. Doc: Documentation - Onboarding.md

import SwiftUI

struct AnalysisTimingSheet: View {
    let onChoose: (ProcessingCoordinator.Timing) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var timing: ProcessingCoordinator.Timing = .overnight
    @State private var power = PowerState.snapshot()
    @State private var nextOvernight = OvernightScheduler.nextOccurrence(minutesSinceMidnight: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                MonoCaps("YOUR FIRST ANALYSIS", size: 9, tracking: 2, color: Theme.faint)
                Text("When should analysis run?").display(27).foregroundStyle(.white)
                Text(CodexAuth.knowledgeBaseOnly ? "Continue to Home either way." : "You can use Sidekick either way.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
            VStack(spacing: 12) {
                choice(.now, title: "Run processing now", icon: "sparkles",
                       detail: "Build your knowledge in a separate window while you use Sentient.")
                choice(.overnight, title: "Run processing overnight", icon: "moon.stars",
                       detail: "Next run: \(ProcessingCoordinator.scheduleLabel(nextOvernight)).")
            }
            VStack(alignment: .leading, spacing: 9) {
                if timing == .overnight {
                    Text("Plug in your Mac overnight or make sure the battery is at least 50%.")
                    Text("Keep Sentient open in your menu bar. You can close its windows.")
                        .foregroundStyle(Theme.faint)
                } else if !power.onAC && (power.percent.map { $0 < 50 } ?? true) {
                    Text("Plug in your Mac or make sure the battery is at least 50%.")
                        .foregroundStyle(Theme.Ink.amber)
                    Text("You can continue now. Analysis will start when your Mac is ready.")
                        .foregroundStyle(Theme.faint)
                } else {
                    Text("The first analysis can take a few hours. Your progress is saved as it runs.")
                }
            }
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { dismiss() }.buttonStyle(BackButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                OnboardingNextButton(title: "Continue", glow: 0.25) { onChoose(timing) }
                    .accessibilityIdentifier("analysis.timing.continue")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 540)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                power = PowerState.snapshot()
                nextOvernight = OvernightScheduler.nextOccurrence(minutesSinceMidnight: 180)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func choice(_ value: ProcessingCoordinator.Timing, title: String, icon: String, detail: String) -> some View {
        Button { timing = value } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).frame(width: 25)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 15, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(3)
                }
                Spacer(minLength: 0)
                Image(systemName: timing == value ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(timing == value ? .white : Theme.faint)
            }
            .foregroundStyle(.white)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(timing == value ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(timing == value ? 0.38 : 0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("analysis.timing.\(value.rawValue)")
        .accessibilityAddTraits(timing == value ? .isSelected : [])
    }
}

#Preview { AnalysisTimingSheet(onChoose: { _ in }) }
