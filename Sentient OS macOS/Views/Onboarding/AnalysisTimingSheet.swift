// An explicit analysis choice. Only the overnight choice presents wake/login setup;
// neither choosing now nor opening Home asks for those optional capabilities.
import SwiftUI

struct AnalysisTimingSheet: View {
    var viewportHeight: CGFloat = 620
    let onChoose: (ProcessingCoordinator.Timing) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var timing: ProcessingCoordinator.Timing = .now
    @State private var overnightReady = false
    @State private var sourcesReady = SourceSelection.selectionCount >= SourceSelection.minimumSelections
    @State private var nextOvernight = OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes)
    private var canContinue: Bool { sourcesReady && (timing == .now || overnightReady) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            MonoCaps("YOUR FIRST ANALYSIS", size: 9, tracking: 2, color: Theme.faint)
                            Text("When should analysis run?").display(27).foregroundStyle(.white)
                            Text("Your first analysis can take over an hour to understand your sources and build your knowledge base.")
                                .font(.system(size: 14)).foregroundStyle(Theme.secondary).lineSpacing(3)
                            Text(CodexAuth.knowledgeBaseOnly
                                 ? "You can explore Sentient while it runs. Double Tap becomes available after your knowledge is ready."
                                 : "Keep using Sidekick while it runs. Personal context and Double Tap become available after your knowledge is ready.")
                                .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineSpacing(3)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 12) {
                            choice(.now, title: "Run processing now", icon: "sparkles",
                                   detail: "Build your knowledge in the background while you use Sentient.")
                            choice(.overnight, title: "Run processing overnight", icon: "moon.stars",
                                   detail: "Next run: \(ProcessingCoordinator.scheduleLabel(nextOvernight)).")
                        }
                        if timing == .overnight {
                            OvernightSetupRequirements { overnightReady = $0 }
                            Text("Keep Sentient open in your menu bar. Plug in your Mac overnight or leave at least 50% battery.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(3)
                        } else {
                            Text("Progress is saved as it runs. You can close the analysis window and keep using Sentient.")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineSpacing(3)
                        }
                        if !sourcesReady {
                            Text("Some sources are no longer available. Go back and choose three available sources.")
                                .font(.system(size: 12)).foregroundStyle(Theme.Ink.amber)
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
                OnboardingNextButton(title: timing == .now ? "Start analysis" : "Schedule analysis",
                                     enabled: canContinue, glow: 0.25) {
                    guard canContinue else { return }
                    onChoose(timing)
                }
                .accessibilityIdentifier("analysis.timing.continue")
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .fixedSize(horizontal: false, vertical: true)
        }
        // A sheet gets a finite viewport from its owner; overnight requirements scroll inside
        // it instead of increasing the native window's minimum past a small display.
        .frame(width: 560, height: viewportHeight)
        .background(Theme.bg).preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                nextOvernight = OvernightScheduler.nextOccurrence(minutesSinceMidnight: OvernightScheduler.configuredMinutes)
                sourcesReady = SourceSelection.selectionCount >= SourceSelection.minimumSelections
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
            .foregroundStyle(.white).padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(timing == value ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(timing == value ? 0.38 : 0.1)))
        }
        .buttonStyle(.plain).accessibilityIdentifier("analysis.timing.\(value.rawValue)")
        .accessibilityAddTraits(timing == value ? .isSelected : [])
    }
}

#Preview { AnalysisTimingSheet(onChoose: { _ in }) }
