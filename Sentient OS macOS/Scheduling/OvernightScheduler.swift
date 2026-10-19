// Arms the next local overnight wake and asks the shared analysis owner to run.
// Scheduling never depends on first-analysis completion and never owns a second pipeline.
// Doc: Documentation - Overnight Scheduler & Wake Helper.md

import Foundation
import AppKit

@MainActor @Observable
final class OvernightScheduler {
    var statusLine = "off"
    private(set) var nextWakeAt: Date?
    var needsSchedulerSetup = false

    static let enabledKey = "dbg.scheduler.enabled"
    static let prodEnabledKey = "scheduler.enabled"
    static let minutesKey = "dbg.scheduler.minutes"
    static let allowBatteryKey = "scheduler.allowBattery"
    static let setupEnabledKey = "scheduler.enabledAfterSetup"
    // Read the old latch during migration to respect an existing user's explicit off choice.
    static let autoEnableFiredKey = "scheduler.autoEnableFired"
    static let firstCycleAtKey = ProcessingPlan.initialCompletedKey
    static let stallSeconds: TimeInterval = 4200
    static let defaultMinutes = 180
    static var configuredMinutes: Int {
        validatedMinutes((UserDefaults.standard.object(forKey: minutesKey) as? Int) ?? defaultMinutes)
    }
    static func validatedMinutes(_ minutes: Int) -> Int {
        (0..<1440).contains(minutes) ? minutes : defaultMinutes
    }
    static var firstCycleCompletedAt: Date? { ProcessingPlan.initialCompletedAt() }

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var loopEnabled = false
    @ObservationIgnored private var clockObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = UUID()
    private var processing: ProcessingCoordinator { .shared }

    var isEnabled: Bool {
        guard !processing.isSuspended, UserDefaults.standard.bool(forKey: AppState.onboardingKey) else { return false }
        return UserDefaults.standard.bool(forKey: Self.enabledKey)
            || (UserDefaults.standard.bool(forKey: Self.prodEnabledKey) && !CodexAuth.knowledgeBaseOnly)
            || processing.hasPendingFirstNight
    }

    /// Called at setup completion and launch. No delay, implicit helper install, or login prompt.
    /// Existing deliberately disabled schedulers stay disabled; first-night intent is separate.
    func enableAfterSetup() {
        let d = UserDefaults.standard
        guard d.bool(forKey: AppState.onboardingKey) else { return }
        if !d.bool(forKey: Self.setupEnabledKey) {
            if !d.bool(forKey: Self.autoEnableFiredKey),
               d.object(forKey: Self.prodEnabledKey) == nil, !CodexAuth.knowledgeBaseOnly {
                d.set(true, forKey: Self.prodEnabledKey)
            }
            d.set(true, forKey: Self.setupEnabledKey)
            d.removeObject(forKey: "scheduler.autoEnableDelaySeconds")
        }
        reevaluate()
    }

    func reevaluate() {
        if clockObservers.isEmpty {
            for name in [Notification.Name.NSSystemTimeZoneDidChange, Notification.Name.NSSystemClockDidChange] {
                clockObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        if self.processing.record.status == .scheduled {
                            self.processing.deferNight(notice: self.processing.record.notice ?? "")
                        }
                        self.restart()
                    }
                })
            }
        }
        if isEnabled {
            if loopTask == nil || !loopEnabled { restart() }
        } else { restart() }
    }

    /// Saving a new clock time updates durable first-night/deferred intent too. It does
    /// not enable an otherwise-disabled schedule or cancel app-owned analysis.
    func commit() {
        if processing.record.status == .scheduled && !processing.isSuspended {
            processing.deferNight(notice: processing.record.notice ?? "")
        }
        if isEnabled { restart() }
    }

    private func restart() {
        generation = UUID()
        let id = generation, previous = loopTask
        let enabled = isEnabled
        loopEnabled = enabled
        previous?.cancel()
        nextWakeAt = nil
        if !enabled { statusLine = "off" }
        loopTask = Task {
            // XPC wake requests cannot be recalled by Task cancellation. Drain the old
            // scheduling owner before replacing its wake, so stale arms/cancels cannot
            // overtake the latest choice. Analysis is a separate ProcessingCoordinator
            // task; awaiting this cancelled scheduler never cancels that owned work.
            await previous?.value
            guard !Task.isCancelled, generation == id else { return }
            if enabled && isEnabled { await loop(id: id) }
            else if !isEnabled {
                statusLine = "off"
                _ = await WakeHelperClient.shared.cancelWake()
            }
            if generation == id { loopTask = nil }
        }
    }

    private func loop(id: UUID) async {
        let log = SchedulerLog()
        while !Task.isCancelled && generation == id && isEnabled {
            if processing.paused {
                nextWakeAt = nil; statusLine = "Analysis paused"
                _ = await WakeHelperClient.shared.cancelWake()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                continue
            }
            let health = await WakeHelperClient.shared.healthProbe()
            guard !Task.isCancelled, generation == id else { return }
            guard health == .ready && LoginItem.isEnabled else {
                needsSchedulerSetup = true
                statusLine = health == .ready ? "enable launch at login" : "overnight wake needs setup"
                nextWakeAt = nil
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                continue
            }
            needsSchedulerSetup = false
            var target = processing.record.status == .scheduled ? processing.record.due : nil
            if let missed = target, missed <= Date() {
                // Setup/health checks can straddle 3 AM by seconds. Honor that choice instead of
                // postponing a whole day; an app relaunched much later gets the next night.
                if Date().timeIntervalSince(missed) < 60 {
                    await processing.runScheduled()
                    continue
                }
                processing.deferNight(notice: "The scheduled analysis was missed. Keep Sentient open in the menu bar, or run it now.")
                target = processing.record.due
            }
            let due = target ?? Self.nextOccurrence(minutesSinceMidnight: Self.configuredMinutes)
            // armWake is idempotent at the SAME timestamp; it does not remove an older
            // timestamp. Cancel only our previously owned wake before a new daily arm.
            _ = await WakeHelperClient.shared.cancelWake()
            guard !Task.isCancelled, generation == id, isEnabled else { return }
            let armed = await WakeHelperClient.shared.armWake(at: due)
            guard !Task.isCancelled, generation == id else { return }
            guard armed else {
                needsSchedulerSetup = true; statusLine = "couldn't schedule overnight wake"; nextWakeAt = nil
                log.line("wake arm failed; retrying setup check")
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                continue
            }
            nextWakeAt = due
            statusLine = "Scheduled for \(ProcessingCoordinator.scheduleLabel(due))"
            log.line("armed for \(due)")
            var lastArm = Date()
            while Date() < due {
                do { try await Task.sleep(for: .seconds(min(60, max(0.05, due.timeIntervalSinceNow)))) } catch { return }
                guard generation == id, !Task.isCancelled else { return }
                if !isEnabled || processing.paused {
                    nextWakeAt = nil
                    _ = await WakeHelperClient.shared.cancelWake()
                    break
                }
                if Date() < due && Date().timeIntervalSince(lastArm) >= 300 {
                    _ = await WakeHelperClient.shared.armWake(at: due)
                    lastArm = Date()
                }
            }
            guard generation == id, !Task.isCancelled else { return }
            nextWakeAt = nil
            guard isEnabled else { statusLine = "off"; return }
            if processing.paused { continue }
            if Date().timeIntervalSince(due) > Double(WakeHelperConfig.maxAwakeSeconds) {
                processing.deferNight(notice: "Your Mac missed the overnight run. Your next analysis is scheduled; you can also run it now.")
                log.line("missed overnight window; retained pending work")
                continue
            }
            statusLine = "Analyzing in the background"
            // The owner holds exclusivity through cancellation draining. A manual run already in
            // progress satisfies this trigger; a user pause is never silently undone at 3 AM.
            await processing.runScheduled()
            guard generation == id, !Task.isCancelled else { return }
            log.line("overnight result: \(processing.record.status.rawValue)")
            if !isEnabled { statusLine = "off" }
        }
    }

    /// Calendar matching handles DST and local-time changes without adding fixed 24-hour spans.
    static func nextOccurrence(minutesSinceMidnight minutes: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let valid = validatedMinutes(minutes)
        return calendar.nextDate(after: now, matching: DateComponents(hour: valid / 60, minute: valid % 60, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? now.addingTimeInterval(86400)
    }
}

/// Persistent scheduler log — ~/Library/Logs/SentientOS/scheduler.log, flushed per line so a sudden
/// sleep loses nothing. The "black box" for diagnosing an empty morning. MainActor-isolated (like the
/// scheduler that owns it); off-main callers — e.g. ProactiveCycle's progress closure — hop to the
/// main actor before logging, the same pattern ProcessingView uses.
final class SchedulerLog {
    private let handle: FileHandle?
    private let fmt: DateFormatter
    init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SentientOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scheduler.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    func line(_ s: String) {
        let stamped = "[\(fmt.string(from: Date()))] \(s)"
        Log(stamped)
        handle?.write(Data((stamped + "\n").utf8)); try? handle?.synchronize()
    }
}
