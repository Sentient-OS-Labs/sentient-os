//  OnboardingMagicReplyDemo.swift
//  Native Magic Reply lesson choreography. start() performs the entrance; draft() lands
//  a local sample reply after the notch's simulated button press.
//  One email example; Continue appears only after the draft and its landing animation finish.
//  stop() cancels every delayed beat. No inference, clipboard, or permissions are involved.
//  Doc: Documentation - Onboarding.md (this folder).

import SwiftUI
import AppKit

@MainActor @Observable
final class OnboardingMagicReplyDemo {
    enum Phase { case entering, waiting, drafting, complete }

    private(set) var phase: Phase = .entering
    let swirl = SwirlModel()
    private(set) var windowVisible = false
    private(set) var controlsVisible = false
    private(set) var spiralVisible = false
    private(set) var spiralAtCaret = false
    private(set) var replyVisible = false
    private(set) var continueVisible = false
    private(set) var reduceMotion = false

    private var sequence: Task<Void, Never>?


    var instructionVisible: Bool { controlsVisible && phase != .complete }

    func start(reduceMotion: Bool, entranceRadius: Double = SwirlMath.startRadius) {
        guard phase == .entering, sequence == nil else { return }
        self.reduceMotion = reduceMotion
        sequence = Task { [weak self] in
            guard let self else { return }
            do {
                // Let the departing film recede before the first light appears.
                try await Task.sleep(for: .milliseconds(230))
                if !self.reduceMotion {
                    self.swirl.begin(orbit: 24, initialRadius: entranceRadius)
                    // Light becomes visible while the comets are still at the window edges.
                    withAnimation(.easeOut(duration: 0.85)) { self.spiralVisible = true }
                    try await Task.sleep(for: .milliseconds(850))
                }
                withAnimation(self.reduceMotion ? .easeOut(duration: 0.25) : .spring(duration: 0.65, bounce: 0.08)) {
                    self.windowVisible = true
                    self.spiralAtCaret = true
                }
                try await Task.sleep(for: .milliseconds(480))
                withAnimation(.easeOut(duration: 0.38)) { self.spiralVisible = false }
                try await Task.sleep(for: .milliseconds(260))
                self.phase = .waiting
                withAnimation(.easeOut(duration: 0.4)) { self.controlsVisible = true }
                try await Task.sleep(for: .milliseconds(180))
                self.swirl.phase = .idle
                self.sequence = nil
            } catch { /* Leaving the scene cancels the choreography. */ }
        }
    }

    /// Called only after the notch's scripted Magic Reply press has released.
    func draft() {
        guard phase == .waiting else { return }
        phase = .drafting
        sequence?.cancel()
        sequence = Task { [weak self] in
            guard let self else { return }
            do {
                if !self.reduceMotion {
                    self.swirl.begin(orbit: 17)
                    self.spiralVisible = true
                }
                try await Task.sleep(for: .milliseconds(850))
                if !self.reduceMotion { self.swirl.transition(landing: true) }
                try await Task.sleep(for: CaretSwirl.landingDelay)
                withAnimation(.easeOut(duration: 0.12)) { self.replyVisible = true }
                // Let the landing bloom finish, then give the pasted reply a brief settle.
                let landingTail = max(Duration.zero, .seconds(SwirlMath.landDuration) - CaretSwirl.landingDelay)
                try await Task.sleep(for: landingTail + .milliseconds(70))
                self.spiralVisible = false
                self.swirl.phase = .idle

                withAnimation(.easeOut(duration: 0.4)) {
                    self.phase = .complete
                    self.continueVisible = true
                }
                self.sequence = nil
            } catch { /* No late reply or Continue after the scene leaves. */ }
        }
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
        if enabled {
            spiralVisible = false
            swirl.phase = .idle
        }
    }

    func stop() {
        sequence?.cancel()
        sequence = nil
        swirl.phase = .idle
    }

    #if DEBUG
    static func preview(completed: Bool = false) -> OnboardingMagicReplyDemo {
        let demo = OnboardingMagicReplyDemo()
        demo.phase = completed ? .complete : .waiting
        demo.windowVisible = true
        demo.controlsVisible = true
        demo.spiralAtCaret = true
        demo.replyVisible = completed
        demo.continueVisible = completed
        return demo
    }
    #endif
}
