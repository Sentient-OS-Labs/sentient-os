// Explains the first analysis and its timing. Run now starts on any battery level;
// overnight keeps its power requirements. Doc: Documentation - Onboarding.md

import SwiftUI

struct AnalysisTimingSheet: View {
    let onChoose: (ProcessingCoordinator.Timing) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var timing: ProcessingCoordinator.Timing = .now
    @State private var nextOvernight = OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                MonoCaps("YOUR FIRST ANALYSIS", size: 9, tracking: 2, color: Theme.faint)
                Text("When should analysis run?").display(27).foregroundStyle(.white)
                Text("Sentient’s models can take over an hour to understand your life for the first time and build your knowledge base.")
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary).lineSpacing(3)
                Text(CodexAuth.knowledgeBaseOnly
                     ? "Once your knowledge base is ready, Double Tap unlocks. You can explore Sentient while it runs."
                     : "Once your knowledge base is ready, Double Tap unlocks. Until then, you can use Sidekick; it just won’t have your personal context yet.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
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
                } else {
                    Text("Your progress is saved as it runs. You can close the analysis window and keep using Sentient.")
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
                nextOvernight = OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func choice(_ value: ProcessingCoordinator.Timing, title: String, icon: String, detail: String) -> some View {
        Button { timing = value } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .light)).frame(width: 25)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .medium))
                        if value == .now {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.white.opacity(0.08), in: Capsule())
                        }
                    }
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
