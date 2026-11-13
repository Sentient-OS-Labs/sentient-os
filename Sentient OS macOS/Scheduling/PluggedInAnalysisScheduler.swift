// Starts eligible analysis on AC after 270 seconds of session inactivity, and suspends it on
// activity or sleep. Owns only observation; ProcessingCoordinator owns every worker and hold.
// Doc: Documentation - Overnight Scheduler & Wake Helper.md

import AppKit

@MainActor
final class PluggedInAnalysisScheduler {
    static let interval: TimeInterval = 4 * 60 * 60
    static let idleSeconds: TimeInterval = 270

    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var awake = false

    /// No wake is armed here, and no activity assertion is held while waiting. The short
    /// polling interval also notices AC changes without relying on Low Power Mode notifications.
    func start(processing: ProcessingCoordinator, enabled: @escaping @MainActor () -> Bool,
               interactionBusy: @escaping @MainActor () -> Bool) {
        guard timer == nil else { return }
        awake = true
        processing.pluggedInEnvironmentAllowsRun = { [weak self] in
            self?.awake == true && enabled() && !interactionBusy()
                && UserPresence.systemIdleSeconds >= Self.idleSeconds
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self, weak processing] _ in
            MainActor.assumeIsolated {
                self?.awake = false
                processing?.checkPluggedInWork()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.awake = true }
        })
        timer = Task { [weak self, weak processing] in
            while !Task.isCancelled {
                guard self != nil, let processing else { return }
                processing.checkPluggedInWork()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        awake = false
    }

    static func isDue(_ cadence: ProcessingPlan.Cadence, now: Date) -> Bool {
        if let retry = cadence.retryAfter, retry > now { return false }
        return cadence.lastStartedAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}
