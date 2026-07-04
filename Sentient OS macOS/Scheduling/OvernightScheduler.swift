//
//  OvernightScheduler.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  The in-app scheduler. Lives inside the running app (owned by AppState), so scheduled processing
//  only ever happens while Sentient is open — force-quit it and nothing runs (and the root helper
//  cancels the pending wake when the app's connection drops, so the Mac won't even wake).
//
//  Driven today by the DEV TOOLS "Scheduled run" control (a time + on/off — for testing); the same
//  engine will back the production auto-3am trigger. When enabled it: arms a wake for the chosen
//  time → waits (the Task freezes with the Mac, thaws on the scheduled wake) → on wake keeps the Mac
//  awake (root) + heartbeats → runs IterativeRun `.auto` (initial-if-fresh, iterative-if-caught-up,
//  PER source) over the connectors selected in the app, plus the Gmail/Calendar legs → then runs the
//  SAME shared tail the home's Analyze Now runs (`ProactiveCycle`: knowledge base create/update →
//  MCP mirror push → proactive decide → research → prepare → wipe summaries) → releases → the Mac
//  sleeps → re-arms for the next day. There is NO scheduler-specific processing path: source
//  detection goes through the SAME `SourceSelection.current(...)`, the read leg is the SAME
//  `IterativeRun`, and the tail is the SAME `ProactiveCycle` — so a 3am run and a hand-pressed
//  Analyze Now do byte-for-byte the same work. Everything lands in ~/Library/Logs/SentientOS/scheduler.log.
//

import Foundation
import ServiceManagement

@MainActor
@Observable
final class OvernightScheduler {

    /// One-line status for the dev UI ("off" / "armed for 4:00 PM" / "running…").
    var statusLine = "off"

    /// Set true when the 18h auto-enable wants to arm but the prerequisites (approved root helper +
    /// launch-at-login) aren't in place yet. The setup UX (dev section today, onboarding later) reads
    /// this to prompt the user; it clears itself once auto-enable succeeds.
    var needsSchedulerSetup = false

    // The DEV toggle (testing) and the PRODUCTION flag are separate keys but either one runs the
    // scheduler. The dev toggle is hand-flipped in DevToolsView; the production flag is what the 18h
    // auto-enable (and a future Settings switch) writes. Keeping them apart means a dev testing the
    // toggle never trips the production auto-enable latch, and vice-versa.
    static let enabledKey = "dbg.scheduler.enabled"        // DEV toggle
    static let prodEnabledKey = "scheduler.enabled"         // PRODUCTION flag (auto-enable / Settings)
    static let minutesKey = "dbg.scheduler.minutes"        // minutes since midnight
    static let defaultMinutes = 3 * 60                     // 3:00 AM — the production overnight time (the dev
                                                          // UI can override `minutesKey` for testing)

    // 18h auto-enable state (all UserDefaults; survive restarts).
    static let firstCycleAtKey = "scheduler.firstCycleCompletedAt"   // Double epoch — set ONCE
    static let autoEnableFiredKey = "scheduler.autoEnableFired"      // latch — flip prod ON at most once
    static let autoEnableDelayKey = "scheduler.autoEnableDelaySeconds"  // dev override of the 18h wait
    static let defaultAutoEnableDelay: TimeInterval = 18 * 3600      // 18 hours after initial finishes

    /// The configured time-of-day in minutes since midnight (shared default so the UI and the loop agree).
    nonisolated static var configuredMinutes: Int { (UserDefaults.standard.object(forKey: minutesKey) as? Int) ?? defaultMinutes }

    /// The auto-enable wait (default 18h; a dev key shortens it for testing). (Pure UserDefaults read.)
    nonisolated static var autoEnableDelay: TimeInterval {
        let v = UserDefaults.standard.double(forKey: autoEnableDelayKey)
        return v > 0 ? v : defaultAutoEnableDelay
    }

    /// When the first full ProactiveCycle finished (nil until it has). Set once via `noteFirstCycleCompleted`.
    nonisolated static var firstCycleCompletedAt: Date? {
        let t = UserDefaults.standard.double(forKey: firstCycleAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The instant the scheduler should auto-enable (first-cycle-completion + the wait). Nil until initial done.
    nonisolated static var autoEnableFireDate: Date? { firstCycleCompletedAt.map { $0.addingTimeInterval(autoEnableDelay) } }

    /// Stamp "initial processing finished" exactly once — called from ProactiveCycle on the first full,
    /// successful cycle (knowledge base now exists). Nonisolated: it's a single UserDefaults write, safe
    /// from the cycle actor. Later calls are ignored, so the 18h clock starts at the TRUE first finish.
    nonisolated static func noteFirstCycleCompleted() {
        let d = UserDefaults.standard
        guard d.double(forKey: firstCycleAtKey) == 0 else { return }
        d.set(Date().timeIntervalSince1970, forKey: firstCycleAtKey)
        Log("Scheduler: first full cycle done — 18h auto-enable clock started (fires \(Date().addingTimeInterval(autoEnableDelay)))")
    }

    private var loopTask: Task<Void, Never>?
    private var autoEnableTask: Task<Void, Never>?
    private var everArmed = false

    /// Run if EITHER the dev toggle or the production flag is on. Call on launch and on any toggle.
    func reevaluate() {
        let on = UserDefaults.standard.bool(forKey: Self.enabledKey) || UserDefaults.standard.bool(forKey: Self.prodEnabledKey)
        if on { start() } else { stop() }
    }

    /// "Done" — finalize the chosen time: restart the loop, which wipes EVERY scheduled wake (clears
    /// duplicates / stale times) then arms exactly this one. No-op while the feature is off.
    func commit() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        start()
    }

    private func start() {
        loopTask?.cancel()
        loopTask = Task { await loop() }
    }

    private func stop() {
        loopTask?.cancel(); loopTask = nil
        statusLine = "off"
        if everArmed {   // only reach out to the helper if we actually scheduled something
            everArmed = false
            Task { _ = await WakeHelperClient.shared.cancelWake() }
        }
        // NB: the auto-enable timer is deliberately NOT cancelled here — it must keep waiting to flip
        // the scheduler ON even while it's currently off (that's the whole point of auto-enable).
    }

    // MARK: - 18h auto-enable

    /// Decide whether to auto-enable the production scheduler. Idempotent + safe to call repeatedly —
    /// from launch (AppState.init), right after any cycle finishes, and from the one-shot timer it arms.
    /// Fires at most once (a latch), never fights a user who toggled the scheduler off, and only arms
    /// when the prerequisites (approved root helper + launch-at-login) are in place — otherwise it flags
    /// `needsSchedulerSetup` for the setup UX and retries on the next tick.
    func maybeAutoEnable() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.autoEnableFiredKey) else { return }      // already handled once

        // The user already turned the scheduler on (dev or prod) — latch and never auto-touch it.
        if d.bool(forKey: Self.enabledKey) || d.bool(forKey: Self.prodEnabledKey) {
            d.set(true, forKey: Self.autoEnableFiredKey); return
        }

        guard let fireAt = Self.autoEnableFireDate else { return }          // initial not finished yet
        if Date() < fireAt { armAutoEnableTimer(at: fireAt); return }       // not time yet — wait

        // Time's up. Only enable if the overnight run can actually happen: approved helper + login item.
        guard WakeHelperClient.shared.isReady else {
            needsSchedulerSetup = true                                      // surface setup; retry next tick
            Log("Scheduler: 18h elapsed but root helper not approved — awaiting setup")
            return
        }
        LoginItem.enable()                                                  // ensure the app relaunches to host 3am
        d.set(true, forKey: Self.prodEnabledKey)
        d.set(true, forKey: Self.autoEnableFiredKey)
        needsSchedulerSetup = false
        Log("Scheduler: 18h elapsed + prerequisites met — auto-enabled overnight processing")
        Analytics.signal("Scheduler.autoEnabled")
        reevaluate()
    }

    /// Arm a one-shot wake-up for the auto-enable moment (so it fires even if the app just sits open
    /// past the 18h mark). Replaces any pending timer; the timer just re-invokes maybeAutoEnable().
    private func armAutoEnableTimer(at fireAt: Date) {
        autoEnableTask?.cancel()
        let delay = max(1, fireAt.timeIntervalSinceNow)
        autoEnableTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.maybeAutoEnable()
        }
    }

    // MARK: - Helper readiness

    /// Ensure the root daemon is registered & approved before arming. Returns true when it's ready to
    /// accept XPC. PRODUCTION path: SMAppService (one-click System Settings approval, no password) —
    /// `.enabled` means go, `.requiresApproval` bails and lets the setup UX walk the user through it.
    /// DEBUG dev builds (unsigned, or the plist not bundled → `.notFound`) fall back to the proven
    /// admin-password installer so testing keeps working without a signed distribution build.
    private func ensureHelperReady(log: SchedulerLog) async -> Bool {
        let client = WakeHelperClient.shared
        if client.isReady { return true }

        let status = client.register()   // may surface the System Settings approval prompt
        log.line("helper SMAppService status after register: \(status.rawValue)")
        switch status {
        case .enabled:
            try? await Task.sleep(for: .seconds(1))   // let launchd settle before the first connection
            needsSchedulerSetup = false
            return true
        case .requiresApproval:
            needsSchedulerSetup = true
            statusLine = "approve in System Settings"
            log.line("helper needs approval in System Settings > Login Items — awaiting user")
            return false
        default:   // .notRegistered / .notFound — plist not bundled or build not signed for SMAppService
            #if DEBUG
            log.line("SMAppService unavailable (\(status.rawValue)) — DEBUG fallback to admin-password installer")
            if !WakeHelperInstaller.isInstalledAndCurrent() {
                statusLine = "installing helper…"
                let ok = await WakeHelperInstaller.installAsync()
                log.line("helper install (admin): \(ok ? "OK" : "declined/failed")")
                guard ok else { statusLine = "needs your password — toggle off then on to retry"; return false }
                try? await Task.sleep(for: .seconds(1))
            }
            return true
            #else
            needsSchedulerSetup = true
            statusLine = "helper unavailable"
            log.line("helper unavailable in Release (status \(status.rawValue)) — awaiting setup")
            return false
            #endif
        }
    }

    private func loop() async {
        let log = SchedulerLog()

        // Make sure the root wake helper is installed & approved before arming any wake.
        guard await ensureHelperReady(log: log) else { return }

        // Clean slate: wipe every existing scheduled wake (duplicates / stale), then arm exactly one.
        everArmed = true
        _ = await WakeHelperClient.shared.cancelAllWakes()

        while !Task.isCancelled {
            let minutes = Self.configuredMinutes
            let target = Self.nextOccurrence(minutesSinceMidnight: minutes)
            statusLine = "armed for \(Self.clock(target))"
            log.line("arming wake for \(target)")
            _ = await WakeHelperClient.shared.armWake(at: target)

            // Wait for the target. Re-arm every ~5 min while awake (idempotent — keeps the helper's
            // record fresh so its force-quit auto-cancel always knows what to cancel).
            while Date() < target && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if !Task.isCancelled && Date() < target { _ = await WakeHelperClient.shared.armWake(at: target) }
            }
            if Task.isCancelled { break }

            statusLine = "running…"
            await runProcessing(log: log)
            statusLine = "armed (next \(Self.clock(Self.nextOccurrence(minutesSinceMidnight: minutes))))"
        }
    }

    /// The actual run: keep awake → read the selected connectors with `.auto` (+ Gmail/Calendar) →
    /// run the shared `ProactiveCycle` tail (knowledge base → mirror → proactive → wipe) → release.
    private func runProcessing(log: SchedulerLog) async {
        log.line("WOKE at \(Date()) — beginning the run.")
        Analytics.signal("Scheduler.overnightStarted")   // the 3am wake fired and we're processing

        // DETECT — identical to the dev UI / Analyze Now (the shared SourceSelection reader).
        // Custom roots are persistent now (CustomRoots), so the 3am run sees them too — the old
        // "session-only customRoots" caveat is gone.
        let fda = Permissions.hasFullDiskAccess()
        let sources = SourceSelection.current(fdaGranted: fda)
        let connectors = RunSource.connectors(from: sources)
        let runGmail = ud("dbg.gmail.connected") && ud("dbg.run.gmail")
        let runCalendar = ud("dbg.calendar.connected") && ud("dbg.run.calendar")
        log.line("FDA=\(fda) · detected: \(sources.isEmpty ? "none" : sources.map(\.label).joined(separator: ", ")) · gmail=\(runGmail) calendar=\(runCalendar)")
        guard !connectors.isEmpty || runGmail || runCalendar else { log.line("nothing enabled — skipping run."); return }
        let modelPath = ModelLocator.resolve()
        if !connectors.isEmpty && modelPath == nil { log.line("model not found — skipping run."); return }

        // B6: go/no-go gate — a lid-shut 3am run holds the Mac fully awake + hammers the GPU, so only
        // when it's safe (on AC, not Low Power, not thermally critical). Skip otherwise; the wake is
        // already re-armed for tomorrow by the loop, so we just try again next night.
        log.line("power: ac=\(PowerState.onACPower()) lowPower=\(PowerState.lowPowerMode) thermal=\(PowerState.thermalLabel)")
        if let blocked = PowerState.overnightBlockReason() {
            log.line("GATED — \(blocked); skipping this run (retry next night).")
            Analytics.signal("Scheduler.gated", parameters: ["reason": blocked])
            CrashReporting.captureEvent("overnight.gated", level: .info,
                tags: ["reason": blocked],
                extra: ["thermal": PowerState.thermalLabel],
                fingerprint: ["overnight", "gated", blocked])
            return
        }

        let began = await WakeHelperClient.shared.beginAwake(timeout: 1800)
        log.line("beginAwake (disablesleep 1): \(began ? "OK" : "FAILED")")
        let heart = Task {
            while !Task.isCancelled { _ = await WakeHelperClient.shared.heartbeat(); try? await Task.sleep(for: .seconds(60)) }
        }

        if !connectors.isEmpty, let modelPath {
            log.line("IterativeRun .auto over \(connectors.count) connector(s)…")
            let throttle = LogThrottle()
            let p = await IterativeRun(modelPath: modelPath).run(connectors, mode: .auto) { pr in
                throttle.maybe { log.line("  … \(pr.done)/\(pr.total)  kept=\(pr.survivors) junk=\(pr.junk) failed=\(pr.failed)") }
            }
            log.line("device DONE: \(p.survivors) kept · \(p.junk) junk · \(p.failed) failed of \(p.total)")
        }
        if runGmail    { await cloudLeg("Gmail",    log: log) { try await GmailConnect.runIterative    { _ in } } }
        if runCalendar { await cloudLeg("Calendar", log: log) { try await CalendarConnect.runIterative { _ in } } }

        // The shared post-read tail — knowledge base (create/update) → mirror push → proactive
        // (decide → research → prepare) → wipe summaries. This is the EXACT chain the home's Analyze
        // Now runs (ProcessingView → ProactiveCycle), so a scheduled run produces the morning's
        // For-You cards too — there is no scheduler-specific knowledge-base path. Still held awake +
        // heartbeating throughout (proactive uses codex, same as the KB step already does).
        if let failure = await ProactiveCycle.shared.run(progress: { phase in
            Task { @MainActor in
                switch phase {
                case .knowledgeBase(let s): log.line("proactive: \(s)")
                case .deciding:             log.line("proactive: deciding what's worth doing…")
                case .researching(let n):   log.line("proactive: researching + preparing \(n) item(s)…")
                case .done(let ready):      log.line("proactive: ✅ cycle done — \(ready) card(s) ready.")
                case .failed(let m):        log.line("proactive: FAILED — \(m)")
                }
            }
        }) {
            log.line("proactive cycle ended with a failure (summaries kept for retry): \(failure)")
        }

        heart.cancel()
        let ended = await WakeHelperClient.shared.endAwake()
        log.line("endAwake (disablesleep 0): \(ended ? "OK" : "FAILED") — run complete, Mac will sleep.")
        Analytics.signal("Scheduler.overnightCompleted")   // the nightly run finished cleanly
    }

    private func cloudLeg(_ name: String, log: SchedulerLog, _ body: () async throws -> Void) async {
        log.line("\(name) leg…")
        do { try await body(); log.line("\(name) DONE") }
        catch { log.line("\(name) FAILED: \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
    }

    // MARK: - Time helpers

    static func nextOccurrence(minutesSinceMidnight m: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = m / 60; c.minute = m % 60; c.second = 0
        var t = Calendar.current.date(from: c) ?? Date().addingTimeInterval(60)
        if t <= Date() { t = Calendar.current.date(byAdding: .day, value: 1, to: t) ?? t }
        return t
    }

    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d) }

    private func ud(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Throttles progress logging to ~once every 20s so a long run leaves a readable trail without spam.
private final class LogThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func maybe(_ body: () -> Void) {
        lock.lock(); let go = Date().timeIntervalSince(last) > 20; if go { last = Date() }; lock.unlock()
        if go { body() }
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
