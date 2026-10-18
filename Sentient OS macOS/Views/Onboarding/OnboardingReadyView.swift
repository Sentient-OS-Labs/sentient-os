//
// OnboardingReadyView.swift
// The final onboarding step uses the same source picker and connection flows as Settings.
// Sources scroll independently of Start Analysis, which stays visible and requires the
// shared four-source minimum. The selection feeds the first analysis and overnight runs.
// Doc: Documentation - Onboarding.md
//

import SwiftUI

struct OnboardingReadyView: View {
    let onStart: (ProcessingCoordinator.Timing) -> Void

    @AppStorage("onboarding.emailSubmitted") private var emailSubmitted = false
    @State private var showEmailPrompt = false
    @State private var selectionCount = SourceSelection.selectionCount
    @State private var showTiming = false
    @State private var chosenTiming: ProcessingCoordinator.Timing?
    private var canStart: Bool { selectionCount >= SourceSelection.minimumSelections }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        Text("Connect your world")
                            .display(29).foregroundStyle(.white)
                        Text("Sentient privately understands your world to make life easier.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }

                    KnowledgeSourcesPicker(context: .onboarding) { count in
                        selectionCount = count
                    }
                }
                .frame(maxWidth: 660)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 18) {
                MonoCaps(canStart ? "\(selectionCount) sources selected"
                                  : "\(selectionCount) of \(SourceSelection.minimumSelections) sources selected",
                         size: 8.5, tracking: 1.6,
                         color: canStart ? Theme.faint : Theme.Ink.amber)

                GlowButton(title: "Start Analysis", active: canStart) {
                    guard emailSubmitted else { showEmailPrompt = true; return }
                    // Recheck the persisted selection in case a connection changed this turn.
                    guard SourceSelection.selectionCount >= SourceSelection.minimumSelections else { return }
                    showTiming = true
                }
                .frame(maxWidth: 380)

                VStack(spacing: 6) {
                    if CodexAuth.knowledgeBaseOnly {
                        Text("Choose when to build your knowledge.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    } else {
                        Text("Sidekick is ready as soon as you finish setup.")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Ink.bright)
                        Text("Analysis runs in the background to give Sidekick personal context and unlock Double Tap.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                .multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 540)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
        }
        .disabled(!emailSubmitted)
        .onAppear { showEmailPrompt = !emailSubmitted }
        .sheet(isPresented: $showEmailPrompt) {
            OnboardingEmailPrompt {
                emailSubmitted = true
                showEmailPrompt = false
            }
        }
        .sheet(isPresented: $showTiming, onDismiss: {
            if let chosenTiming {
                self.chosenTiming = nil
                onStart(chosenTiming)
            }
        }) {
            AnalysisTimingSheet { timing in
                chosenTiming = timing
                showTiming = false
            }
        }
    }
}

#Preview("Analysis setup") {
    OnboardingReadyView(onStart: { _ in }).frame(width: 1040, height: 800)
}
