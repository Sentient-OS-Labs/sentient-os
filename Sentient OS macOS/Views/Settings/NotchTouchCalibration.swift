import AppKit
import SwiftUI

@MainActor @Observable final class NotchTouchCalibration: NSObject, NSWindowDelegate {
    static let shared = NotchTouchCalibration()
    private(set) var isRunning = false
    private(set) var finished = false
    private(set) var passed = false
    private(set) var headline = "Fine-tune your touch"
    private(set) var instruction = "Touch already works with our default tuning. To personalize it, keep your Mac in its usual position for a quiet baseline, five taps and two finger passes."
    private(set) var stepLabel = "About a minute"
    private(set) var countdown: Int?
    private(set) var isTapCue = false
    @ObservationIgnored private var guidePanel: NSPanel?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sensor: PhysicalTapSensor?
    @ObservationIgnored private var sensorStatus: PhysicalTapSensor.Status = .stopped
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var runID = UUID()

    func show() {
        if window == nil {
            let panel = NSWindow(contentViewController: NSHostingController(
                rootView: NotchTouchCalibrationView(calibration: self).preferredColorScheme(.dark)))
            panel.title = "Calibrate notch touch"
            panel.identifier = NSUserInterfaceItemIdentifier("sentient.notchTouchCalibration")
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = NSColor(white: 0.045, alpha: 1)
            panel.delegate = self
            panel.setContentSize(NSSize(width: 560, height: 540))
            // Place instructions on the display being touched, even with an external display attached.
            if let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                             y: screen.visibleFrame.midY - panel.frame.height / 2))
            } else { panel.center() }
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        showGuide()
        observeInterruptions()
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        finished = false
        passed = false
        isTapCue = false
        showGuide()
        headline = "Let your lid settle"
        instruction = "Leave your Mac still while we connect to its sensors."
        stepLabel = "Getting ready"
        runID = UUID()
        let id = runID
        let defaults = UserDefaults.standard
        PhysicalNotchTap.shared.beginCalibration()
        observeInterruptions()
        let capture = PhysicalTapCalibrationCapture()
        sensorStatus = .starting
        let sensor = PhysicalTapSensor(onTap: { _, _ in }, onStatus: { [weak self] status, _ in
            Task { @MainActor in
                guard let self, self.runID == id, self.isRunning else { return }
                self.sensorStatus = status
            }
        }, onSample: { sample in capture.append(sample) })
        self.sensor = sensor
        sensor.configure(enabled: true, sensitivity: 1.1, generation: 1)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let deadline = PhysicalTapClock.now + 12
                while sensorStatus != .ready {
                    try Task.checkCancellation()
                    if sensorStatus == .unavailable || PhysicalTapClock.now >= deadline {
                        throw CalibrationError(message: "We couldn’t get steady sensor readings. Keep the built-in display open and try again.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                recording = true
                var trials: [PhysicalTapCalibrationEvaluation.Trial] = []
                var start = PhysicalTapClock.now
                try await step("Hold still", "Keep your hands off your Mac for the quiet baseline.",
                               label: "Quiet baseline", seconds: 5)
                trials.append(.init(kind: .quiet, start: start, end: PhysicalTapClock.now))
                for index in 1...5 {
                    try await step("Get ready to tap", "Touch the spot just left of the camera when “Tap once” appears.",
                                   label: "Tap \(index) of 5", seconds: 2)
                    start = PhysicalTapClock.now
                    try await step("Tap once", "Gently touch the marked spot on your real notch, then lift your finger.",
                                   label: "Tap \(index) of 5", seconds: 1, tapCue: true)
                    try await step("Hold still", "Let the light and motion settle before the next tap.",
                                   label: "Tap \(index) of 5", seconds: 3)
                    trials.append(.init(kind: .tap, start: start, end: PhysicalTapClock.now))
                }
                for index in 1...2 {
                    try await step("Get ready for a finger pass", "Move a finger across the same spot, about 1 cm away, without touching the screen.",
                                   label: "Finger pass \(index) of 2", seconds: 3)
                    start = PhysicalTapClock.now
                    try await step("Pass your finger", "Move across the tap spot once without touching, then withdraw your hand.",
                                   label: "Finger pass \(index) of 2", seconds: 2)
                    try await step("Hold still", "Keep your hand away while the light settles.",
                                   label: "Finger pass \(index) of 2", seconds: 3)
                    trials.append(.init(kind: .fingerPass, start: start, end: PhysicalTapClock.now))
                }
                recording = false
                headline = "Checking your touch"
                instruction = "Finding a sensitivity that separates your taps from the other movements."
                countdown = nil
                sensor.drainForTermination()
                guard let samples = capture.take() else {
                    throw CalibrationError(message: "The recording ran too long. Start a fresh calibration.")
                }
                let recordedTrials = trials
                let result = await Task.detached(priority: .userInitiated) {
                    PhysicalTapCalibrationEvaluation.evaluate(samples: samples, trials: recordedTrials)
                }.value
                try Task.checkCancellation()
                guard runID == id else { return }
                if let profile = result.profile, let sensitivity = profile.sensitivities.last {
                    defaults.set(try JSONEncoder().encode(profile), forKey: NotchPreferences.physicalTapCalibrationKey)
                    defaults.set(sensitivity, forKey: NotchPreferences.physicalTapSensitivityKey)
                    passed = true
                }
                finish(message: result.message)
            } catch is CancellationError {
                if runID == id { finish(message: "Calibration stopped. Start again when you’re ready.") }
            } catch {
                if runID == id { finish(message: (error as? CalibrationError)?.message ?? "Calibration couldn’t finish. Please try again.") }
            }
        }
    }

    private func step(_ title: String, _ detail: String, label: String,
                      seconds: Int, tapCue: Bool = false) async throws {
        headline = title
        instruction = detail
        stepLabel = label
        isTapCue = tapCue
        let end = PhysicalTapClock.now + Double(seconds)
        while PhysicalTapClock.now < end {
            try Task.checkCancellation()
            if recording && sensorStatus != .ready {
                throw CalibrationError(message: "The lid moved or a sensor paused. Let your Mac settle, then try again.")
            }
            let remaining = max(1, Int(ceil(end - PhysicalTapClock.now)))
            if countdown != remaining { countdown = remaining }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func showGuide() {
        if let guidePanel { guidePanel.orderFrontRegardless(); return }
        guard let screen = NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
              let notch = screen.notchSize else { return }
        let metrics = NotchMetrics(hardwareNotch: notch)
        let panel = CalibrationGuidePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .mainMenu + 4
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .canJoinAllApplications, .ignoresCycle]
        panel.title = "Notch calibration tap guide"
        panel.setAccessibilityElement(false)
        panel.contentView = NSHostingView(rootView: NotchCalibrationGuide(calibration: self))
        let top = screen.frame.maxY - notch.height - metrics.notchBottomCover + 1
        panel.setFrame(NSRect(x: screen.cameraCenterX + metrics.lightSensorOffset - 42,
                              y: top - 48, width: 84, height: 56), display: true)
        guidePanel = panel
        panel.orderFrontRegardless()
    }

    private final class CalibrationGuidePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func hideGuide() {
        guidePanel?.orderOut(nil)
        guidePanel?.close()
        guidePanel = nil
    }

    private func finish(message: String) {
        sensor?.drainForTermination()
        sensor = nil
        recording = false
        isRunning = false
        finished = true
        countdown = nil
        isTapCue = false
        if window?.isVisible != true { hideGuide() }
        headline = passed ? "Your touch is tuned" : "Let’s try that again"
        instruction = message
        stepLabel = passed ? "Personal tuning saved" : "Current tuning kept"
        if window?.isVisible != true { removeObservers() }
        PhysicalNotchTap.shared.endCalibration()
        NotificationCenter.default.post(name: .physicalNotchTapChanged, object: nil)
        task = nil
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        runID = UUID() // Invalidate queued statuses and an evaluation that is finishing.
        finish(message: "Calibration stopped. Start again when you’re ready.")
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) {
        cancel()
        hideGuide()
        removeObservers()
        window = nil
    }
    func windowDidBecomeKey(_ notification: Notification) { showGuide() }

    private func observeInterruptions() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        observe(.default, NSApplication.willTerminateNotification)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
                self?.hideGuide()
            }
        }
        observers.append((center, token))
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private struct CalibrationError: Error { let message: String }
}

struct NotchTouchCalibrationView: View {
    let calibration: NotchTouchCalibration

    var body: some View {
        VStack(spacing: 20) {
            NotchCalibrationIllustration()
                .frame(height: 152)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tap the glowing sensor region just left of the camera in your MacBook’s notch")

            Text(calibration.stepLabel).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.72, green: 0.91, blue: 0.91))
            Text(calibration.headline).font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("calibration.instruction")
            Text(calibration.instruction).font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 440, minHeight: 56, alignment: .top)
            if let countdown = calibration.countdown {
                Text("\(countdown)").font(.system(size: 32, weight: .light, design: .rounded))
                    .monospacedDigit().frame(height: 38)
            } else {
                Text(calibration.finished ? "" : "Successful calibration saves a personalized sensitivity.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 38)
            }
            Spacer(minLength: 0)
            HStack {
                Button(calibration.isRunning ? "Cancel" : "Close") {
                    if calibration.isRunning { calibration.cancel() } else { calibration.close() }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if !calibration.isRunning {
                    Button(calibration.passed ? "Calibrate again" : calibration.finished ? "Try again" : "Start calibration") {
                        calibration.start()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("calibration.start")
                }
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .padding(32).frame(width: 560, height: 540)
        .background(Color(white: 0.045))
    }
}

/// Uses the same Opal line and fingertip as the notch, positioned by the real display geometry.
private struct NotchCalibrationGuide: View {
    let calibration: NotchTouchCalibration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NotchTapLocationGuide(expanded: true, visible: true)
            .frame(width: 38, height: 26)
            .scaleEffect(1.4, anchor: .top)
            .opacity(calibration.isTapCue ? 1 : 0.85)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(.top, 8)
            .frame(width: 84, height: 56, alignment: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: calibration.isTapCue)
            .allowsHitTesting(false)
            .preferredColorScheme(.dark)
    }
}

/// A static close-up makes the touch target visible within the black camera housing.
struct NotchCalibrationIllustration: View {
    private let sensorX: CGFloat = -320 * 54 / 370
    private let notch = UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.065)],
                                     startPoint: .top, endPoint: .bottom))
            ZStack(alignment: .top) {
                notch.fill(.black)
                SensorGlow().frame(width: 50, height: 50).offset(x: sensorX, y: 2)
                Circle().fill(Color(white: 0.045))
                    .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                    .overlay(Circle().fill(.white.opacity(0.24)).frame(width: 3, height: 3))
                    .frame(width: 10, height: 10).offset(y: 22)
            }
            .frame(width: 320, height: 54).clipShape(notch)
            NotchTapLocationGuide(expanded: true, visible: true)
                .frame(width: 38, height: 26).offset(x: sensorX, y: 60)
            Text("Touch the glow, just left of the camera")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.64)).offset(y: 120)
        }
    }
}

private struct SensorGlow: View {
    var body: some View {
        // Display the centered 720 px square from the user's 1320 × 2868 reference.
        // The source stays intact; clipping excludes the phone UI and preserves the exact glow.
        GeometryReader { geometry in
            Image("NotchCalibrationLuma")
                .resizable()
                .frame(width: geometry.size.width * 1320 / 720,
                       height: geometry.size.height * 2868 / 720)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    // Cover the reference's central star with a solid round touch target.
                    Circle().fill(.white)
                        .frame(width: geometry.size.width * 0.38, height: geometry.size.height * 0.38)
                }
        }
        .allowsHitTesting(false)
    }
}
