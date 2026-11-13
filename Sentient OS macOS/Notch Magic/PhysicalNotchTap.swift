import AppKit
import Observation

/// App-lifetime owner. Sensor samples remain on one background thread; only a tap/status
/// crosses to the main actor. Wake, display sleep and locking invalidate queued events.
@MainActor @Observable final class PhysicalNotchTap {
    static let shared = PhysicalNotchTap()
    private(set) var status: PhysicalTapSensor.Status = .stopped
    private(set) var detectedTaps = 0
    private(set) var isEnabled = false
    private(set) var isCalibrating = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var warmupOwners: Set<UUID> = []
    @ObservationIgnored private var configuredSensitivity: Double?
    @ObservationIgnored private var acceptingTaps = false
    @ObservationIgnored private var acceptingTapsSince = Double.infinity
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var screenSleeping = false
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var allowed: () -> Bool = { false }
    @ObservationIgnored private var onTap: () -> Void = {}
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private lazy var sensor: PhysicalTapSensor = PhysicalTapSensor(onTap: { [weak self] time, generation in
        Task { @MainActor in
            guard let self, self.generation == generation, self.isEnabled,
                  self.acceptingTaps, time >= self.acceptingTapsSince,
                  PhysicalTapClock.now - time < 0.4, self.sensor.acceptsDelivery(at: time, generation: generation),
                  self.allowed(), !Self.screenLocked else { return }
            self.detectedTaps += 1
            self.onTap()
        }
    }, onStatus: { [weak self] status, generation in
        Task { @MainActor in
            guard let self, self.generation == generation else { return }
            if self.isEnabled { self.status = status }
        }
    })

    var statusText: String {
        if isCalibrating { return "Calibration is in progress. Follow the calibration window." }
        if !NotchPreferences.physicalTapEnabled() { return "Physical taps are off." }
        if sleeping || screenSleeping || locked { return "Paused while your Mac is asleep or locked." }
        switch status {
        case .ready: return "Ready. Tap the light-sensor area of the notch, then lift your finger."
        case .starting: return "Checking your Mac’s light, motion and lid sensors…"
        case .settling: return "Touch detection resumes when the lid has settled."
        case .unavailable: return "Physical taps aren’t available on this Mac or its sensors couldn’t be opened."
        case .stalled: return "A sensor stream paused. Sentient will reconnect automatically."
        case .stopped: return "Available on supported MacBooks with the built-in display open."
        }
    }

    func start(allowed: @escaping () -> Bool, onTap: @escaping () -> Void) {
        guard !started else { return }
        started = true; self.allowed = allowed; self.onTap = onTap; locked = Self.screenLocked
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sleeping = true; $0.refresh() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.sleeping = false; $0.refresh() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screenSleeping = true; $0.refresh() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screenSleeping = false; $0.refresh() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.locked = true; $0.refresh() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.locked = Self.screenLocked; $0.refresh() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.locked = true; $0.refresh() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false; $0.refresh() }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSApplication.didResignActiveNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSWindow.didBecomeKeyNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSWindow.didResignKeyNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSWindow.didMiniaturizeNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSWindow.didDeminiaturizeNotification) { $0.refreshIfAdmissionChanged() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
        observe(.default, .physicalNotchTapChanged) { $0.refresh() }
        observe(.default, NSApplication.willTerminateNotification) { $0.stop(); $0.sensor.drainForTermination() }
        refresh()
    }

    /// The film can warm the hardware before its lesson accepts gestures.
    /// Each visible owner releases only its own request when it leaves.
    func setWarmup(_ enabled: Bool, owner: UUID) {
        if enabled {
            guard warmupOwners.insert(owner).inserted else { return }
        } else {
            guard warmupOwners.remove(owner) != nil else { return }
        }
        refresh()
    }

    private var shouldRunSensor: Bool {
        let builtIn = NSScreen.screens.contains { CGDisplayIsBuiltin($0.displayID) != 0 }
        let warming = !warmupOwners.isEmpty && NSApp?.isActive == true
        return !isCalibrating && (allowed() || warming) && NotchPreferences.physicalTapEnabled() && builtIn
            && !sleeping && !screenSleeping && !locked && !Self.screenLocked
    }

    private func refreshIfAdmissionChanged() {
        let enabled = shouldRunSensor
        if isEnabled != enabled || acceptingTaps != (enabled && allowed()) { refresh() }
    }

    func refresh() {
        guard started else { return }
        let enabled = shouldRunSensor
        acceptingTaps = enabled && allowed()
        // Explicit lesson changes invalidate queued gestures even when the same warm
        // sensor keeps running. A touch from the intro must never answer the lesson.
        acceptingTapsSince = acceptingTaps ? PhysicalTapClock.now : .infinity
        let sensitivity = NotchPreferences.physicalTapThreshold()
        guard enabled != isEnabled || (enabled && configuredSensitivity != sensitivity) else { return }
        generation &+= 1
        isEnabled = enabled
        configuredSensitivity = sensitivity
        status = enabled ? .starting : .stopped
        sensor.configure(enabled: enabled, sensitivity: sensitivity, generation: generation)
    }
    func beginCalibration() {
        isCalibrating = true
        refresh()
        sensor.drainForTermination()
    }

    func endCalibration() {
        isCalibrating = false
        refresh()
    }

    func stop() {
        generation &+= 1; isEnabled = false; status = .stopped; started = false
        acceptingTaps = false
        acceptingTapsSince = .infinity
        warmupOwners.removeAll()
        configuredSensitivity = nil
        sensor.configure(enabled: false, sensitivity: 1.1, generation: generation)
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (PhysicalNotchTap) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }
    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
