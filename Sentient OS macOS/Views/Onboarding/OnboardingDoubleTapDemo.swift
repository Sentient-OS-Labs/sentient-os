//  OnboardingDoubleTapDemo.swift
//  The native Double Tap lesson's choreography and two-press state machine. start() performs
//  the entrance, keyChanged() follows the hardware, and draft() lands a local sample reply.
//  Next hands the drafted email off to Messages; only drafting the second reply unlocks Continue.
//  stop() cancels every delayed beat. No inference, clipboard, or permissions are involved.
//  Doc: Documentation - Onboarding.md (this folder).

import SwiftUI

@MainActor @Observable
final class OnboardingDoubleTapDemo {
    enum Phase { case entering, waiting, drafting, emailReady, switching, complete }
    enum Sample { case email, message }

    private(set) var phase: Phase = .entering
    private(set) var sample: Sample = .email
    let swirl = SwirlModel()
    private(set) var windowVisible = false
    private(set) var emailDeparture: CGFloat = 0
    private(set) var messageArrival: CGFloat = 1
    private(set) var controlsVisible = false
    private(set) var completionVisible = false
    private(set) var spiralVisible = false
    private(set) var spiralAtCaret = false
    private(set) var replyVisible = false
    private(set) var continueVisible = false
    private(set) var keyIsDown = false
    private(set) var reduceMotion = false

    private var lastPress: TimeInterval?
    private var sequence: Task<Void, Never>?

    private static let flightDuration = 0.78

    var instructionVisible: Bool { controlsVisible && !completionVisible }
    var nextVisible: Bool { phase == .emailReady }

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

    /// Down edges count; releases animate the cap and re-arm the next physical press. A hold
    /// cannot count twice. Monotonic time avoids clock corrections changing the gesture window.
    func keyChanged(_ down: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard down != keyIsDown else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: down ? 0.1 : 0.2, bounce: down ? 0 : 0.12)) {
            keyIsDown = down
        }
        guard down, phase == .waiting else { return }
        if let lastPress, time >= lastPress, time - lastPress <= DoubleTap.window {
            draft()
        } else {
            lastPress = time
        }
    }

    /// Losing the key window must not leave a depressed key or pair taps across apps.
    func resetGesture() {
        lastPress = nil
        withAnimation(.easeOut(duration: 0.15)) { keyIsDown = false }
    }

    /// Also the keycap's accessible button action, so hardware isn't the only way forward.
    func draft() {
        guard phase == .waiting else { return }
        phase = .drafting
        lastPress = nil
        sequence?.cancel()
        if sample == .message {
            withAnimation(.easeOut(duration: 0.35)) { completionVisible = true }
        }
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
                try await Task.sleep(for: .milliseconds(420))
                try await Task.sleep(for: .milliseconds(160))
                self.spiralVisible = false
                self.swirl.phase = .idle

                if self.sample == .email {
                    // Hold the reply until the user chooses Next. No timer advances this beat.
                    withAnimation(.easeOut(duration: 0.35)) { self.phase = .emailReady }
                } else {
                    self.phase = .complete
                    withAnimation(.easeOut(duration: 0.4)) { self.continueVisible = true }
                }
                self.sequence = nil
            } catch { /* No late reply or Continue after the scene leaves. */ }
        }
    }

    /// Next is the only handoff to Messages. Repeated clicks and taps cannot skip either draft.
    func showMessages() {
        guard sample == .email, phase == .emailReady else { return }
        phase = .switching
        resetGesture()
        sequence?.cancel()
        sequence = Task { [weak self] in
            guard let self else { return }
            do {
                if self.reduceMotion {
                    withAnimation(.easeOut(duration: 0.24)) { self.windowVisible = false }
                    try await Task.sleep(for: .milliseconds(260))
                } else {
                    // Keep the email opaque until its curved throw clears the top-right.
                    withAnimation(.timingCurve(0.3, 0, 0.65, 0.3, duration: Self.flightDuration)) {
                        self.emailDeparture = 1
                    }
                    try await Task.sleep(for: .seconds(Self.flightDuration + 0.04))
                }
                self.windowVisible = false
                self.sample = .message
                self.emailDeparture = 0
                self.messageArrival = self.reduceMotion ? 1 : 0
                self.replyVisible = false
                self.resetGesture()
                // Mount Messages beyond the top-left before following the mirrored arc home.
                try await Task.sleep(for: .milliseconds(30))
                let arrivalDuration = self.reduceMotion ? 0.25 : Self.flightDuration
                if self.reduceMotion {
                    withAnimation(.easeOut(duration: arrivalDuration)) { self.windowVisible = true }
                } else {
                    // Reverse the email's timing curve as well as its path: matching momentum
                    // from the top-left, slowing into the same resting position.
                    self.windowVisible = true
                    withAnimation(.timingCurve(0.35, 0.7, 0.7, 1, duration: arrivalDuration)) {
                        self.messageArrival = 1
                    }
                }
                try await Task.sleep(for: .seconds(arrivalDuration + 0.04))
                self.lastPress = nil
                self.phase = .waiting
                self.sequence = nil
            } catch { /* Leaving cancels the throw and the Messages entrance. */ }
        }
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
        if enabled {
            spiralVisible = false
            swirl.phase = .idle
            messageArrival = 1
            // Switching Reduce Motion on during a throw must never snap the email back.
            if emailDeparture > 0 { windowVisible = false }
        }
    }

    func stop() {
        sequence?.cancel()
        sequence = nil
        swirl.phase = .idle
        resetGesture()
    }

    #if DEBUG
    static func preview(sample: Sample = .email, completed: Bool = false,
                        departure: CGFloat = 0, arrival: CGFloat = 1) -> OnboardingDoubleTapDemo {
        let demo = OnboardingDoubleTapDemo()
        demo.sample = sample
        let finished = completed && sample == .message
        demo.phase = departure > 0 || arrival < 1 ? .switching : (completed ? (finished ? .complete : .emailReady) : .waiting)
        demo.windowVisible = true
        demo.emailDeparture = departure
        demo.messageArrival = arrival
        demo.controlsVisible = true
        demo.spiralAtCaret = true
        demo.replyVisible = completed
        demo.completionVisible = finished
        demo.continueVisible = finished
        return demo
    }
    #endif
}
