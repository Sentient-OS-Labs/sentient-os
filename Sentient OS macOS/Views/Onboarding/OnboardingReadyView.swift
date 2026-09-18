//
// OnboardingReadyView.swift
// The final onboarding step uses the same source picker and connection flows as Settings.
// Sources scroll independently of Start Analysis, which stays visible and requires the
// shared four-source minimum. The selection feeds the first analysis and overnight runs.
// Doc: Documentation - Onboarding.md
//

import SwiftUI

struct OnboardingReadyView: View {
    let onStart: () -> Void

    @State private var selectionCount = SourceSelection.selectionCount
    private var canStart: Bool { selectionCount >= SourceSelection.minimumSelections }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 36) {
                    VStack(spacing: 24) {
                        OnboardingWhisper("READY")
                        Text("Sentient is ready to understand your life.\nConnect your files, conversations, and apps.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }

                    KnowledgeSourcesPicker(context: .onboarding) { count in
                        selectionCount = count
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 40)
                .padding(.top, 84)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    MonoCaps(canStart ? "\(selectionCount) sources selected"
                                      : "\(selectionCount) of \(SourceSelection.minimumSelections) sources selected",
                             size: 8.5, tracking: 1.6,
                             color: canStart ? Theme.faint : Theme.Ink.amber)
                    if !canStart {
                        Text("Supported apps are selected for your knowledge base when connected.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                GlowButton(title: "Start Analysis", active: canStart) {
                    // Recheck the persisted selection in case a connection changed this turn.
                    guard SourceSelection.selectionCount >= SourceSelection.minimumSelections else { return }
                    onStart()
                }
                .frame(maxWidth: 380)

                Text("This initial analysis can take a few hours. We recommend you run this overnight.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
        }
    }
}

#Preview("Onboarding — ready to process") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingReadyView(onStart: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — compact window") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingReadyView(onStart: {})
    }
    .frame(width: 900, height: 620)
    .preferredColorScheme(.dark)
}
