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
    @State private var showConnectorRecommendation = false
    @State private var startAfterRecommendation = false
    @State private var focusConnectors = false
    private var canStart: Bool { selectionCount >= SourceSelection.minimumSelections }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
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
                .onChange(of: focusConnectors) { _, focus in
                    guard focus else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(KnowledgeSourcesPicker.Section.connectors, anchor: .center)
                    }
                    focusConnectors = false
                }
            }

            VStack(spacing: 18) {
                MonoCaps(canStart ? "\(selectionCount) sources selected"
                                  : "\(selectionCount) of \(SourceSelection.minimumSelections) sources selected",
                         size: 8.5, tracking: 1.6,
                         color: canStart ? Theme.faint : Theme.Ink.amber)

                GlowButton(title: "Start Analysis", active: canStart) {
                    // Recheck the persisted selection in case a connection changed this turn.
                    guard SourceSelection.selectionCount >= SourceSelection.minimumSelections else { return }
                    if !CodexAuth.connectorsLocked && !SourceSelection.hasEmailAndCalendar {
                        showConnectorRecommendation = true
                    } else {
                        onStart()
                    }
                }
                .frame(maxWidth: 380)

                Text("This initial analysis can take a few hours. We recommend you run this overnight.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
        }
        .sheet(isPresented: $showConnectorRecommendation, onDismiss: {
            if startAfterRecommendation {
                startAfterRecommendation = false
                // A sheet or another window may have changed the source selection meanwhile.
                guard SourceSelection.selectionCount >= SourceSelection.minimumSelections else { return }
                onStart()
            } else {
                focusConnectors = true
            }
        }) {
            OnboardingConnectorRecommendation(onConnect: {
                showConnectorRecommendation = false
            }, onSkip: {
                startAfterRecommendation = true
                showConnectorRecommendation = false
            })
        }
    }
}

/// A recommendation, not another prerequisite. Only the explicit orange action starts
/// analysis; accepting or dismissing returns to the existing connector choices.
private struct OnboardingConnectorRecommendation: View {
    let onConnect: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "envelope")
                Image(systemName: "calendar")
            }
            .font(.system(size: 23, weight: .light))
            .foregroundStyle(Theme.Ink.green)

            Text("We recommend you connect Email and Calendar")
                .display(23)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text("Sentient works best when its knowledge base can learn from your email and calendar.\n\nPrivacy is at its core. The developers of Sentient OS cannot see your email nor calendar, as you connect them directly through OpenAI or Anthropic's email or calendar connectors.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Ink.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                choice("Sure!", color: Theme.Ink.green, action: onConnect)
                    .keyboardShortcut(.defaultAction)
                choice("Don't connect", color: .orange, action: onSkip)
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(width: 500)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onConnect)
    }

    private func choice(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

#Preview("Onboarding — recommend Email and Calendar") {
    OnboardingConnectorRecommendation(onConnect: {}, onSkip: {})
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
