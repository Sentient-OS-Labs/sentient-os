//
// OnboardingReadyView.swift
// Optional personal setup uses the same source picker and connection flows as Settings.
// Sources scroll independently of Start Analysis, which stays visible and requires the
// shared three-source minimum. The selection feeds the first analysis and overnight runs.
// Doc: Documentation - Onboarding.md
//

import SwiftUI
import AppKit
import Observation

struct OnboardingReadyView: View {
    let onStart: (ProcessingCoordinator.Timing) -> Void
    var isProcessing = false
    @AppStorage(PersonalSetupProgress.stageKey) private var stageRaw = PersonalSetupProgress.Stage.sources.rawValue
    @State private var selectionCount = SourceSelection.selectionCount
    @State private var showTiming = false
    @State private var timingHandoff = AnalysisTimingHandoff()
    @AppStorage(PersonalSetupProgress.homeKey) private var homeAdmitted = false
    private var canStart: Bool { !isProcessing && !timingHandoff.isPending && selectionCount >= SourceSelection.minimumSelections }

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .sheet(isPresented: $showTiming, onDismiss: {
                    stageRaw = PersonalSetupProgress.Stage.sources.rawValue
                    timingHandoff.sheetDidDismiss()
                }) {
                    AnalysisTimingSheet(viewportHeight: max(420, min(620, geometry.size.height - 16))) { timing in
                        if timingHandoff.choose(timing, onStart: onStart) { showTiming = false }
                    }
                }
        }
        .background(AnalysisTimingOwnerAttachment(handoff: timingHandoff))
        .onDisappear { timingHandoff.cancel() }
        .onChange(of: homeAdmitted) { _, admitted in
            if !admitted { timingHandoff.cancel(); showTiming = false }
        }
        .onAppear {
            selectionCount = SourceSelection.selectionCount
            showTiming = stageRaw == PersonalSetupProgress.Stage.timing.rawValue && canStart
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Do not publish the source catalog's full intrinsic height as the window minimum.
            // The viewport takes the space left above the fixed action/footer.
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 10) {
                            Text("Connect your world")
                                .display(29).foregroundStyle(.white)
                            Text("Choose at least three sources to give Sentient personal context. You can add more later.")
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
                .frame(width: viewport.size.width, height: viewport.size.height)
            }

            VStack(spacing: 18) {
                MonoCaps(canStart ? "\(selectionCount) sources selected"
                                  : "\(selectionCount) of \(SourceSelection.minimumSelections) sources selected",
                         size: 8.5, tracking: 1.6,
                         color: canStart ? Theme.faint : Theme.Ink.amber)

                GlowButton(title: "Start Analysis", active: canStart) {
                    // Recheck the persisted selection in case a connection changed this turn.
                    guard SourceSelection.selectionCount >= SourceSelection.minimumSelections else { return }
                    stageRaw = PersonalSetupProgress.Stage.timing.rawValue
                    showTiming = true
                }
                .frame(maxWidth: 380)
                .accessibilityIdentifier("personalSetup.startAnalysis")

                VStack(spacing: 6) {
                    if CodexAuth.knowledgeBaseOnly {
                        Text("Choose when to build your knowledge.")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    } else {
                        Text("Keep using Sidekick while your Mac learns.")
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
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.bg)
        }
    }
}

#Preview("Analysis setup") {
    OnboardingReadyView(onStart: { _ in }).frame(width: 1040, height: 800)
}

/// SwiftUI's onDismiss can precede AppKit's actual sheet detachment. Keep the chosen action
/// until both lifecycle signals agree, so its callback may safely close the setup window.
@MainActor @Observable
final class AnalysisTimingHandoff {
    private(set) var isPending = false
    @ObservationIgnored private weak var owner: NSWindow?
    @ObservationIgnored private var chosen: ProcessingCoordinator.Timing?
    @ObservationIgnored private var onStart: ((ProcessingCoordinator.Timing) -> Void)?
    @ObservationIgnored private var swiftUIDismissed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var delivery: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var nativeSheetObservation: NSKeyValueObservation?

    func attach(to window: NSWindow?) {
        guard owner !== window else { return }
        cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        nativeSheetObservation?.invalidate(); nativeSheetObservation = nil
        owner = window
        guard let window else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleDelivery() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        nativeSheetObservation = window.observe(\.attachedSheet, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleDelivery() }
        }
    }

    @discardableResult
    func choose(_ timing: ProcessingCoordinator.Timing, onStart: @escaping (ProcessingCoordinator.Timing) -> Void) -> Bool {
        guard owner != nil, !isPending else { return false }
        generation &+= 1
        chosen = timing; self.onStart = onStart
        swiftUIDismissed = false; isPending = true
        return true
    }

    func sheetDidDismiss() {
        guard isPending else { return }
        swiftUIDismissed = true
        scheduleDelivery()
    }

    func cancel() {
        generation &+= 1
        delivery?.cancel(); delivery = nil
        chosen = nil; onStart = nil; swiftUIDismissed = false; isPending = false
    }

    private func scheduleDelivery() {
        guard isPending, swiftUIDismissed, delivery == nil else { return }
        let ticket = generation
        delivery = Task { @MainActor [weak self] in
            // Finish the current AppKit notification/update before inspecting attachment.
            // This is event-driven; no guessed animation duration or polling timer is used.
            await Task.yield()
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            self.delivery = nil
            guard self.swiftUIDismissed, let owner = self.owner, owner.attachedSheet == nil,
                  let timing = self.chosen, let callback = self.onStart else { return }
            self.cancel() // consume before callbacks can close/reset/recreate the owner
            callback(timing)
        }
    }
}

/// Mounted in the parent content, not the sheet. Moving/closing the owner invalidates the
/// handoff, including late SwiftUI dismissal or native notification callbacks after reset.
private struct AnalysisTimingOwnerAttachment: NSViewRepresentable {
    let handoff: AnalysisTimingHandoff
    func makeNSView(context: Context) -> Attachment { Attachment(handoff: handoff) }
    func updateNSView(_ view: Attachment, context: Context) { view.handoff = handoff; handoff.attach(to: view.window) }
    static func dismantleNSView(_ view: Attachment, coordinator: ()) { view.handoff?.attach(to: nil) }

    final class Attachment: NSView {
        weak var handoff: AnalysisTimingHandoff?
        init(handoff: AnalysisTimingHandoff) { self.handoff = handoff; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); handoff?.attach(to: window) }
    }
}
