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
//  Analyze Now do byte-for-byte the same work. Every night races a STALL WATCHDOG (`runNight`):
//  a run that is alive and heartbeating but silently wedged — no error, no timeout — is ended
//  after `stallSeconds` without progress, sleep restored, and the morning caution recorded.
//  Everything lands in ~/Library/Logs/SentientOS/scheduler.log.
//

import Foundation
import ServiceManagement

@MainActor
@Observable
final class OvernightScheduler {

    /// One-line status for the dev UI ("off" / "armed for 4:00 PM" / "running…").
    var statusLine = "off"

    /// Set true when the 14h auto-enable wants to arm but a prerequisite is missing: the root
    /// helper isn't installed (onboarding's permissions step and Settings → Health own the
    /// install), or launch-at-login is off. The setup UX reads this to prompt the user; it
    /// clears itself once auto-enable succeeds.
    var needsSchedulerSetup = false

    // The DEV toggle (testing) and the PRODUCTION flag are separate keys but either one runs the
    // scheduler. The dev toggle is hand-flipped in DevToolsView; the production flag is what the 14h
    // auto-enable (and a future Settings switch) writes. Keeping them apart means a dev testing the
    // toggle never trips the production auto-enable latch, and vice-versa.
    static let enabledKey = "dbg.scheduler.enabled"        // DEV toggle
    static let prodEnabledKey = "scheduler.enabled"         // PRODUCTION flag (auto-enable / Settings)
    static let minutesKey = "dbg.scheduler.minutes"        // minutes since midnight
    static let allowBatteryKey = "scheduler.allowBattery"  // opt-in: battery nights above the charge floor
                                                          // (the home's Analysis dropdown owns the toggle)

    /// The stall watchdog's silence budget: 70 minutes deliberately sits just past the longest
    /// single CLI timeout (1 h, the structured vault runs), so the watchdog can never kill a
    /// healthy call that is about to finish or time out cleanly on its own.
    static let stallSeconds: TimeInterval = 4200
    static let defaultMinutes = 3 * 60                     // 3:00 AM — the production overnight time (the dev
                                                          // UI can override `minutesKey` for testing)

    // 14h auto-enable state (all UserDefaults; survive restarts).
    static let firstCycleAtKey = "scheduler.firstCycleCompletedAt"   // Double epoch — set ONCE
    static let autoEnableFiredKey = "scheduler.autoEnableFired"      // latch — flip prod ON at most once
    static let autoEnableDelayKey = "scheduler.autoEnableDelaySeconds"  // dev override of the 14h wait
    static let defaultAutoEnableDelay: TimeInterval = 14 * 3600      // 14 hours after initial finishes

    /// The configured time-of-day in minutes since midnight (shared default so the UI and the loop agree).
    nonisolated static var configuredMinutes: Int { (UserDefaults.standard.object(forKey: minutesKey) as? Int) ?? defaultMinutes }

    /// The auto-enable wait (default 14h; a dev key shortens it for testing). (Pure UserDefaults read.)
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
    /// from the cycle actor. Later calls are ignored, so the 14h clock starts at the TRUE first finish.
    nonisolated static func noteFirstCycleCompleted() {
        let d = UserDefaults.standard
        guard d.double(forKey: firstCycleAtKey) == 0 else { return }
        d.set(Date().timeIntervalSince1970, forKey: firstCycleAtKey)
        Log("Scheduler: first full cycle done — 14h auto-enable clock started (fires \(Date().addingTimeInterval(autoEnableDelay)))")
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

    // MARK: - 14h auto-enable

    /// Decide whether to auto-enable the production scheduler. Idempotent + safe to call repeatedly —
    /// from launch (AppState.init), right after any cycle finishes, and from the one-shot timer it arms.
    /// Fires at most once (a latch), never fights a user who toggled the scheduler off, and only arms
    /// when the prerequisites (installed root helper + launch-at-login) are in place — otherwise it
    /// flags `needsSchedulerSetup` for the setup UX and retries on the next tick.
    func maybeAutoEnable() {
        // Free/go knowledge-base-only mode: no quota for nightly runs — auto-enable never fires.
        // Deliberately NOT latched, so an upgrade (+ reset) later starts the 14h clock fresh.
        guard !CodexAuth.knowledgeBaseOnly else { return }
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.autoEnableFiredKey) else { return }      // already handled once

        // The production scheduler is already on — latch and never auto-touch it. ONLY the prod
        // flag latches: the DEV toggle is a test arm, and burning the one-shot on it would kill
        // auto-enable for the install (the exact drift the two-keys design exists to prevent).
        if d.bool(forKey: Self.prodEnabledKey) {
            d.set(true, forKey: Self.autoEnableFiredKey); return
        }

        guard let fireAt = Self.autoEnableFireDate else { return }          // initial not finished yet
        if Date() < fireAt { armAutoEnableTimer(at: fireAt); return }       // not time yet — wait

        // Time's up. Only enable if the overnight run can actually happen: an installed helper.
        // The PRODUCTION install (WakeHelperInstaller — onboarding + Settings → Health) lives at
        // /Library/LaunchDaemons and is INVISIBLE to SMAppService, so the plist check comes first;
        // `isReady` is the dev cockpit's SMAppService approval path.
        guard WakeHelperInstaller.isInstalledAndCurrent() || WakeHelperClient.shared.isReady else {
            needsSchedulerSetup = true                                      // surface setup; retry next tick
            Log("Scheduler: 14h elapsed but root helper not installed — awaiting setup")
            return
        }
        // The app must be alive at 3am to host the run — enable launch-at-login, and treat a
        // refusal (the user revoked it in System Settings; macOS won't let us silently re-enable)
        // as a missing prerequisite. Enabling anyway would mean silent empty mornings with no
        // caution banner: the run never starts, so nothing ever classifies as failed.
        LoginItem.enable()
        guard LoginItem.isEnabled else {
            needsSchedulerSetup = true
            Log("Scheduler: 14h elapsed but launch-at-login is off (revoked?) — awaiting setup")
            return
        }
        d.set(true, forKey: Self.prodEnabledKey)
        d.set(true, forKey: Self.autoEnableFiredKey)
        needsSchedulerSetup = false
        Log("Scheduler: 14h elapsed + prerequisites met — auto-enabled overnight processing")
        Analytics.signal("Scheduler.autoEnabled")
        reevaluate()
    }

    /// Arm a one-shot wake-up for the auto-enable moment (so it fires even if the app just sits open
    /// past the 14h mark). Replaces any pending timer; the timer just re-invokes maybeAutoEnable().
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

    /// Ensure the root daemon is ALIVE before arming — WakeHelperClient.healthProbe's XPC ground
    /// truth, which covers both install paths (the admin-password plist AND the dev cockpit's
    /// SMAppService daemon) and can't be fooled by the System Settings background toggle.
    /// Toggled off → surface setup and stop (a reinstall can't override the switch). Not set up →
    /// DEBUG self-installs (the proven admin fallback, so a clean dev slate still works); Release
    /// flags `needsSchedulerSetup` for the setup UX — it never registers or prompts on its own (a
    /// `register()` here would park a stray "Sentient OS" approval in System Settings > Login Items).
    private func ensureHelperReady(log: SchedulerLog) async -> Bool {
        // WakeHelperClient.healthProbe is the ground truth: the daemon must ANSWER over XPC —
        // one probe covers BOTH install paths (the production plist and the dev cockpit's
        // SMAppService daemon share the mach service), and it's the only check the System
        // Settings background toggle can't fool (the toggle boots the daemon out of launchd
        // while leaving every file check green — field-found 2026-07-11).
        switch await WakeHelperClient.shared.healthProbe() {
        case .ready:
            needsSchedulerSetup = false
            return true
        case .disabled:
            // Launchd honors the toggle over any bootstrap, so a reinstall can't help — only
            // the user flipping it back on can (Health's row and the home's banner say so).
            needsSchedulerSetup = true
            statusLine = "background item turned off"
            log.line("helper installed but unreachable — background item toggled off in System Settings")
            return false
        case .notSetUp:
            break   // fall through to the install path below
        }
        #if DEBUG
        log.line("helper not installed — DEBUG fallback to the admin-password installer")
        statusLine = "installing helper…"
        let ok = await WakeHelperInstaller.installAsync()
        log.line("helper install (admin): \(ok ? "OK" : "declined/failed")")
        guard ok else { statusLine = "needs your password; toggle off then on to retry"; return false }
        try? await Task.sleep(for: .seconds(1))   // let launchd settle before the first connection
        needsSchedulerSetup = false
        return true
        #else
        needsSchedulerSetup = true
        statusLine = "helper not set up"
        log.line("helper not installed — awaiting setup (onboarding / Settings → Health)")
        return false
        #endif
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
            await runNight(log: log)
            statusLine = "armed (next \(Self.clock(Self.nextOccurrence(minutesSinceMidnight: minutes))))"
        }
    }

    /// One night, raced against the stall watchdog. The run rides its own Task so a silent wedge
    /// (the app alive and heartbeating, no error thrown, no timeout fired — just nothing moving)
    /// can't pin the loop: after `stallSeconds` without a progress pulse we cancel the run, restore
    /// sleep ourselves, and record the morning caution; the loop then re-arms tomorrow's wake as
    /// usual. A healthy night wins the race and none of this is visible.
    private func runNight(log: SchedulerLog) async {
        let pulse = NightPulse()
        // A task group would await every child at scope exit, including a child awaiting the
        // wedged run. A one-shot stream lets the watchdog report without waiting for that run.
        let (outcomes, result) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let run = Task {
            await self.runProcessing(log: log, pulse: pulse)
            result.yield(false)
            result.finish()
        }
        let watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
                if pulse.secondsSinceProgress > Self.stallSeconds {
                    result.yield(true)
                    result.finish()
                    return
                }
            }
        }
        let stalled = await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next() ?? false
        } onCancel: {
            run.cancel()
            result.finish()
        }
        watchdog.cancel()
        guard stalled, !Task.isCancelled else { return }

        // The silent-wedge net. Latch FIRST so every exit path the cancelled run might later thaw
        // into knows sleep is already handled and leaves the helper alone (by then a NEXT night
        // could legitimately be holding the Mac awake).
        pulse.markSleepRestored()
        run.cancel()
        log.line("STALLED — no progress for \(Int(Self.stallSeconds / 60)) min; ending the night, restoring sleep.")
        OvernightCaution.record(.stalled)
        // A stall is defect-shaped (unlike the weather kinds), so Sentry hears about it too — structure only.
        CrashReporting.captureEvent("overnight.stalled", level: .warning,
                                    tags: ["trigger": "overnight"],
                                    extra: ["stall_minutes": String(Int(Self.stallSeconds / 60))],
                                    fingerprint: ["overnight", "stalled"])
        let ended = await WakeHelperClient.shared.endAwake()
        log.line("watchdog endAwake: \(ended ? "OK" : "FAILED — the helper's deadman/ceiling still net it")")
    }

    /// The actual run: keep awake → read the selected connectors with `.auto` (+ Gmail/Calendar) →
    /// run the shared `ProactiveCycle` tail (knowledge base → mirror → proactive → wipe) → release.
    private func runProcessing(log: SchedulerLog, pulse: NightPulse) async {
        // Every codex call under this run reports trigger=overnight (task-local, inherited by the
        // child tasks the legs spawn) — the 3 AM failure population gets its own fingerprint.
        await CodexTrigger.$current.withValue(.overnight) { await runProcessingBody(log: log, pulse: pulse) }
    }

    private func runProcessingBody(log: SchedulerLog, pulse: NightPulse) async {
        let woke = Date()
        log.line("WOKE at \(woke) — beginning the run.")
        Analytics.signal("Scheduler.overnightStarted")   // the 3am wake fired and we're processing

        // DETECT — identical to the dev UI / Analyze Now (the shared SourceSelection reader).
        // Custom roots are persistent now (CustomRoots), so the 3am run sees them too — the old
        // "session-only customRoots" caveat is gone.
        let fda = Permissions.hasFullDiskAccess()
        let sources = SourceSelection.current(fdaGranted: fda)
        let connectors = RunSource.connectors(from: sources)
        // Connectors ride ChatGPT auth inside codex — a custom frontier backend has none.
        let runGmail = ModelBackend.connectorsAvailable && ud("dbg.run.gmail")
        let runCalendar = ModelBackend.connectorsAvailable && ud("dbg.run.calendar")
        // KB-toggled connectors (the generic nightly reads) — backend-scoped like the chips.
        let mcpSlugs = MCPSource.kbSlugs()
        log.line("FDA=\(fda) · detected: \(sources.isEmpty ? "none" : sources.map(\.label).joined(separator: ", ")) · gmail=\(runGmail) calendar=\(runCalendar) · connectors=\(mcpSlugs.count)")
        guard !connectors.isEmpty || runGmail || runCalendar || !mcpSlugs.isEmpty else { log.line("nothing enabled — skipping run."); return }
        let modelPath = ModelLocator.resolve()
        if !connectors.isEmpty && modelPath == nil { log.line("model not found — skipping run."); return }

        // B6: go/no-go gate — a lid-shut 3am run holds the Mac fully awake + hammers the GPU, so only
        // when it's safe: on AC (not Low Power, not thermally critical), or on battery above the
        // charge floor when the user opted in (the home's Analysis dropdown). Skip otherwise; the
        // wake is already re-armed for tomorrow by the loop, so we just try again next night.
        let allowBattery = ud(Self.allowBatteryKey)
        let battery = PowerState.batteryPercent().map { "\($0)%" } ?? "n/a"
        log.line("power: ac=\(PowerState.onACPower()) battery=\(battery) allowBattery=\(allowBattery) lowPower=\(PowerState.lowPowerMode) thermal=\(PowerState.thermalLabel)")
        if let blocked = PowerState.overnightBlockReason(allowBattery: allowBattery) {
            log.line("GATED — \(blocked); skipping this run (retry next night).")
            // Telemetry, not a defect — TelemetryDeck counts it; Sentry stays quiet (2026-07-12).
            Analytics.signal("Scheduler.gated", parameters: ["reason": blocked])
            return
        }

        guard !Task.isCancelled else { return }
        let began = await WakeHelperClient.shared.beginAwake(timeout: 1800)
        log.line("beginAwake (disablesleep 1): \(began ? "OK" : "FAILED")")
        // The night's diagnostics baseline: what the network and codex's login look like BEFORE
        // any cloud call — so a dead cloud stage can be read against them in the morning
        // (structure only; see CodexDiagnostics.swift).
        await CodexCLI.shared.beginDiagnosticsRun()
        let netAtStart = NetworkSnapshot.shared.current
        log.line("network: \(netAtStart.status)/\(netAtStart.interface) \(Int(Date().timeIntervalSince(woke)))s since wake")
        let signin = CodexAuthSnapshot.read()
        log.line(signin.logLine)
        var legs: [String: String] = ["gmail": "skipped", "calendar": "skipped", "mcp": "skipped", "vault": "ok", "proactive": "skipped"]
        var unavailableConnectors: Set<String> = []
        var firstCloudCallAt: Date?
        var deviceItems = 0, deviceKept = 0, deviceFailed = 0, deviceSeconds = 0
        let heart = Task {
            while !Task.isCancelled && !pulse.sleepWasRestored {
                _ = await WakeHelperClient.shared.heartbeat()
                try? await Task.sleep(for: .seconds(60))
            }
        }

        // The night's cloud legs deserve a current Codex CLI: the daily update runs here first
        // (self-capped to once a day, a no-op when already newest; a failed update never blocks
        // the run — the legs go on with the CLI they have).
        await CodexSetup.shared.updateIfDue(trigger: "overnight")
        if let v = CodexSetup.shared.version { log.line("codex CLI \(v)") }
        await ClaudeSetup.shared.updateIfDue(trigger: "overnight")   // self-guards: Claude backend only
        if ModelBackend.current == .claude, let v = ClaudeSetup.shared.version { log.line("claude CLI \(v)") }

        /// Let the Mac sleep again — the one exit every path takes (normal end, the disk-full stop,
        /// or a cancellation bail). If the stall watchdog already restored sleep, leave the helper
        /// alone: by the time a wedged run thaws, a NEXT night could be legitimately holding awake.
        func releaseAwake() async {
            heart.cancel()
            if pulse.sleepWasRestored {
                log.line("night was ended by the watchdog — sleep already restored; leaving the helper alone.")
                return
            }
            let ended = await WakeHelperClient.shared.endAwake()
            log.line("endAwake (disablesleep 0): \(ended ? "OK" : "FAILED") — run complete, Mac will sleep.")
        }

        if Task.isCancelled { await releaseAwake(); return }
        if !connectors.isEmpty, let modelPath {
            log.line("IterativeRun .auto over \(connectors.count) connector(s)…")
            let throttle = LogThrottle()
            let p = await IterativeRun(modelPath: modelPath).run(connectors, mode: .auto) { pr in
                pulse.touch()
                throttle.maybe { log.line("  … \(pr.done)/\(pr.total)  kept=\(pr.survivors) junk=\(pr.junk) failed=\(pr.failed)") }
            }
            log.line("device DONE: \(p.survivors) kept · \(p.junk) junk · \(p.failed) failed of \(p.total)")
            deviceItems = p.total; deviceKept = p.survivors; deviceFailed = p.failed
            deviceSeconds = Int(Date().timeIntervalSince(woke))
            // A full disk stopped the read (see IterativeRun): nothing more can be saved tonight, and
            // the cloud legs write too (marks, the knowledge-base staging copy). Record the morning
            // caution and end the night here; the marks are per-item atomic, so tomorrow resumes.
            if p.diskFull {
                log.line("disk full — stopping the night here; the morning caution says so.")
                OvernightCaution.record(.diskFull)
                await releaseAwake()
                return
            }
        }
        // Leg boundaries double as cancellation bails: a run the watchdog (or a mid-run stop)
        // cancelled must not thaw hours later and start fresh cloud legs into someone's morning.
        if Task.isCancelled { await releaseAwake(); return }
        if runGmail {
            firstCloudCallAt = firstCloudCallAt ?? Date()
            legs["gmail"] = await cloudLeg("Gmail", log: log, pulse: pulse) { try await GmailConnect.runIterative { _ in pulse.touch() } }
        }
        if Task.isCancelled { await releaseAwake(); return }
        if runCalendar {
            firstCloudCallAt = firstCloudCallAt ?? Date()
            legs["calendar"] = await cloudLeg("Calendar", log: log, pulse: pulse) { try await CalendarConnect.runIterative { _ in pulse.touch() } }
        }
        if legs["gmail"] == "connector_auth" { unavailableConnectors.insert("gmail") }
        if legs["calendar"] == "connector_auth" { unavailableConnectors.insert("google-calendar") }
        if Task.isCancelled { await releaseAwake(); return }
        if !mcpSlugs.isEmpty {
            firstCloudCallAt = firstCloudCallAt ?? Date()
            log.line("Connector KB legs (\(mcpSlugs.count))…")
            pulse.touch()
            let (outcomes, limited) = await MCPSource.runAll { _, _, _, _ in pulse.touch() }
            pulse.touch()
            if Task.isCancelled { await releaseAwake(); return }
            for o in outcomes { log.line("  \(o.slug): \(o.result)") }
            legs["mcp"] = outcomes.first(where: { $0.result != "ok" })?.result ?? "ok"
            unavailableConnectors.formUnion(outcomes.filter { $0.result == "connector_auth" }.map(\.slug))
            if limited {
                // The reads run the light tier, so their limit can trip while the heavier tail
                // still succeeds — record the morning caution here rather than hoping the tail
                // fails too. Marks didn't advance, so next night's iterative covers the gap.
                log.line("usage limit during connector reads — remaining skipped, caution recorded")
                OvernightCaution.record(.usageLimit)
            }
        }
        if Task.isCancelled { await releaseAwake(); return }
        firstCloudCallAt = firstCloudCallAt ?? Date()   // the ProactiveCycle tail is a cloud call too
        if CodexAuth.knowledgeBaseOnly == false { legs["proactive"] = "ok" }   // provisional; a failure below overrides

        // The shared post-read tail — knowledge base (create/update) → mirror push → proactive
        // (decide → research → prepare) → wipe summaries. This is the EXACT chain the home's Analyze
        // Now runs (ProcessingView → ProactiveCycle), so a scheduled run produces the morning's
        // For-You cards too — there is no scheduler-specific knowledge-base path. Still held awake +
        // heartbeating throughout (proactive uses codex, same as the KB step already does).
        if let failure = await ProactiveCycle.shared.run(scheduled: true, unavailableConnectors: unavailableConnectors, progress: { phase in
            pulse.touch()
            Task { @MainActor in
                switch phase {
                case .knowledgeBase(let s): log.line("proactive: \(s)")
                case .deciding:             log.line("proactive: deciding what's worth doing…")
                case .researching(let n):   log.line("proactive: researching + preparing \(n) item(s)…")
                case .done(let ready):      log.line("proactive: ✅ cycle done — \(ready) card(s) ready.")
                case .failed:               log.line("proactive: FAILED")   // reason withheld — it can embed codex output, and every log line is a Release breadcrumb
                }
            }
        }) {
            // Detail withheld (can embed codex output); the morning caution + codex.failure carry the kind.
            log.line("proactive cycle ended with a failure (summaries kept for retry)")
            switch failure.stage {
            case .vault:      legs["vault"] = failure.reason.rawValue; legs["proactive"] = "skipped"
            case .deciding, .preparing: legs["proactive"] = failure.reason.rawValue
            }
        }

        if Task.isCancelled { await releaseAwake(); return }
        await releaseAwake()
        Analytics.signal("Scheduler.overnightCompleted", tier: .core)   // always-on usage ping: an overnight run finished cleanly

        // ONE row per user-night: did the cloud stage work, and if not, which leg failed why —
        // read against the network + login baseline taken at wake. Replaces reading three
        // scattered warnings per night. Structure only.
        let diag = await CodexCLI.shared.diagnosticsRunSummary()
        let failed = legs.values.filter { $0 != "ok" && $0 != "skipped" }
        let ran = legs.values.filter { $0 != "skipped" }
        let offlineReasons: Set<String> = ["dns", "connect_timeout", "tls"]
        let outcome: String
        if failed.isEmpty { outcome = "ok" }
        else if netAtStart.status != "satisfied" || failed.allSatisfy({ offlineReasons.contains($0) }) { outcome = "offline" }
        else if failed.count < ran.count { outcome = "partial" }
        else { outcome = "failed" }
        var tags: [String: String] = [
            "trigger": "overnight", "outcome": outcome,
            "gmail": legs["gmail"]!, "calendar": legs["calendar"]!, "mcp": legs["mcp"]!,
            "vault": legs["vault"]!, "proactive": legs["proactive"]!,
            "network_at_start": netAtStart.status, "interface_at_start": netAtStart.interface,
            "codex_version": diag.version ?? "unknown",
        ]
        tags.merge(signin.tags) { cur, _ in cur }
        var extra: [String: String] = [
            "device_items": String(deviceItems), "device_kept": String(deviceKept),
            "device_failed": String(deviceFailed), "secs_device_stage": String(deviceSeconds),
            "mcp_connectors": String(mcpSlugs.count),
            "pings": String(diag.pings), "ping_ms_first": diag.firstPingMS.map(String.init) ?? "n/a",
            "secs_wake_to_first_cloud_call": String(Int((firstCloudCallAt ?? Date()).timeIntervalSince(woke))),
        ]
        extra.merge(signin.extras) { cur, _ in cur }
        CrashReporting.captureEvent("overnight.cloud_stage", level: outcome == "ok" ? .info : .warning,
                                    tags: tags, extra: extra,
                                    fingerprint: ["overnight", "cloud_stage", outcome])
    }

    /// Runs one cloud leg and returns "ok" or the closed-vocabulary reason it failed with.
    /// Leg start and end both count as progress for the stall watchdog (so a night of several
    /// quick legs never reads as silence between them).
    private func cloudLeg(_ name: String, log: SchedulerLog, pulse: NightPulse, _ body: () async throws -> Void) async -> String {
        pulse.touch()
        log.line("\(name) leg…")
        do { try await body(); pulse.touch(); log.line("\(name) DONE"); return "ok" }
        catch {
            pulse.touch()
            if Task.isCancelled || error is CancellationError { return "cancelled" }
            if ConnectorReadFailure.isConnectionFailure(error) { return "connector_auth" }
            let reason = CodexFailureReason.classify(error)
            log.line("\(name) FAILED: \(ErrorLabel(error)) — \(reason.rawValue)")
            return reason.rawValue
        }
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

/// The night's progress pulse — shared between the run body (which touches it on every sign of
/// life: device items, leg starts/ends, proactive phases) and the loop's stall watchdog (which
/// reads it once a minute). Lock-guarded: touches arrive from whatever context the legs run in.
/// Also carries the one-way "sleep already restored" latch the watchdog sets before cancelling a
/// stalled run, so any exit path the wedged run later thaws into leaves the helper alone.
private final class NightPulse: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var restored = false
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    var secondsSinceProgress: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    func markSleepRestored() { lock.lock(); restored = true; lock.unlock() }
    var sleepWasRestored: Bool { lock.lock(); defer { lock.unlock() }; return restored }
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
