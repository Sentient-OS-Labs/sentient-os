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
//  PER source) over the connectors selected in the app → releases → the Mac sleeps → re-arms for the
//  next day. Connector detection goes through the SAME `SourceSelection.current(...)` the dev UI and
//  Analyze Now use. Everything lands in ~/Library/Logs/SentientOS/scheduler.log.
//

import Foundation

@MainActor
@Observable
final class OvernightScheduler {

    /// One-line status for the dev UI ("off" / "armed for 4:00 PM" / "running…").
    var statusLine = "off"

    static let enabledKey = "dbg.scheduler.enabled"
    static let minutesKey = "dbg.scheduler.minutes"   // minutes since midnight
    static let defaultMinutes = 16 * 60               // 4:00 PM — shared by the UI default and the reader

    /// The configured time-of-day in minutes since midnight (shared default so the UI and the loop agree).
    static var configuredMinutes: Int { (UserDefaults.standard.object(forKey: minutesKey) as? Int) ?? defaultMinutes }

    private var loopTask: Task<Void, Never>?
    private var everArmed = false

    /// Re-read the dev settings and (re)start or stop. Call on launch and on any settings change.
    func reevaluate() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() } else { stop() }
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
    }

    private func loop() async {
        let log = SchedulerLog()

        // Make sure the root helper is installed — one-time native password prompt, no Terminal.
        if !WakeHelperInstaller.isInstalledAndCurrent() {
            statusLine = "installing helper…"
            log.line("helper not installed/current — requesting install (admin prompt)")
            let ok = await WakeHelperInstaller.installAsync()
            log.line("helper install: \(ok ? "OK" : "declined/failed")")
            guard ok else { statusLine = "needs your password — toggle off then on to retry"; return }
            try? await Task.sleep(for: .seconds(1))   // let launchd settle before the first connection
        }

        while !Task.isCancelled {
            let minutes = Self.configuredMinutes
            let target = Self.nextOccurrence(minutesSinceMidnight: minutes)
            statusLine = "armed for \(Self.clock(target))"
            log.line("arming wake for \(target)")
            everArmed = true
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

    /// The actual run: keep awake → process the selected connectors with `.auto` → release.
    private func runProcessing(log: SchedulerLog) async {
        log.line("WOKE at \(Date()) — beginning the run.")

        // DETECT — identical to the dev UI / Analyze Now (the shared SourceSelection reader).
        let fda = Permissions.hasFullDiskAccess()
        let sources = SourceSelection.current(customRoots: [], fdaGranted: fda)
        let connectors = RunSource.connectors(from: sources)
        let runGmail = ud("dbg.gmail.connected") && ud("dbg.run.gmail")
        let runCalendar = ud("dbg.calendar.connected") && ud("dbg.run.calendar")
        log.line("FDA=\(fda) · detected: \(sources.isEmpty ? "none" : sources.map(\.label).joined(separator: ", ")) · gmail=\(runGmail) calendar=\(runCalendar)")
        guard !connectors.isEmpty || runGmail || runCalendar else { log.line("nothing enabled — skipping run."); return }
        let modelPath = ModelLocator.resolve()
        if !connectors.isEmpty && modelPath == nil { log.line("model not found — skipping run."); return }

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

        heart.cancel()
        let ended = await WakeHelperClient.shared.endAwake()
        log.line("endAwake (disablesleep 0): \(ended ? "OK" : "FAILED") — run complete, Mac will sleep.")
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
/// sleep loses nothing. The "black box" for diagnosing an empty morning.
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
