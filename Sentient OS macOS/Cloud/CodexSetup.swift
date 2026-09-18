//
//  CodexSetup.swift
//  Sentient OS macOS
//
//  The unified Codex SETUP engine — the SINGLE code path that onboarding AND the dev tools both
//  drive, so there's never a second, divergent copy. Getting Sentient's cloud spine plus computer
//  use working on the user's Mac is three steps:
//    1. INSTALL   — drop the Codex CLI binary on disk.
//    2. AUTH      — `codex login` with the user's OpenAI account.
//    3. DRIVER    — download + verify the pinned cua-driver, the hands of computer use
//                   (Driver/CuaDriverSetup; needs neither the binary nor the login).
//  Observable + a shared instance, so both UIs render the same live status off one source of truth.
//  The actual binary install runs through CodexCLI (its Process plumbing); the driver install runs
//  through CuaDriverSetup; this file owns the flow.
//
//  Key methods:
//   - refreshInstalled()   → re-detect whether the codex binary is present (async, off-main)
//   - installCodex()       → step 1: run OpenAI's installer (ALWAYS runs — it doubles as the
//                            updater over an existing install; streams progress)
//   - startLogin/confirmLogin → step 2: interactive `codex login` (browser) + confirm
//   - setupCuaDriver()     → step 3: fetch + verify + install the pinned driver (streams progress)
//   - ensureCuaDriver()    → the fire-time self-heal: driver on disk before a computer-use run
//   - whatsNeeded()        → fresh check of all three; returns the pending steps (smart-flow driver)
//   - updateIfDue(trigger:) → keep the managed CLI current: at most one update attempt a day,
//                            skipped when already the newest release (a 1 KB version check)
//   - startKeepingCurrent(isBusy:) → the periodic trigger: every 15 min, when the user is away
//                            and nothing is running codex, call updateIfDue
//   - repairStaleClient()  → a run just failed on the stale-client signature: update now, flag
//                            `outdated` for the health rung until the update lands
//   - noteStaleSignal()    → the signature on a run that still succeeded: pull the next daily
//                            update forward (hourly at most), no banner
//
//  Doc: Cloud/Documentation - Cloud - Codex Setup.md
//

import Foundation

@MainActor
@Observable
final class CodexSetup {

    /// One shared instance so onboarding and the dev tools observe the same setup state.
    static let shared = CodexSetup()

    private init() {
        // Warm up `installed` off the main thread. Kicking a Task here is safe: it's enqueued, so
        // this initializer returns and the singleton's `dispatch_once` completes before the probe
        // ever runs — and the probe does its disk/shell work off the main actor. Detection must
        // NEVER run synchronously inside this initializer (see `installed`).
        Task { await refreshInstalled() }
    }

    // MARK: Step 1 — install

    /// Is the Codex CLI binary present on disk? (NOT whether it's logged in — that's step 2.)
    /// Starts `false`; warmed up asynchronously OFF the main thread by `init`. This must NEVER be
    /// computed inside this singleton's lazy initializer: `locateBinary()`'s last-resort fallback
    /// spawns a login shell (a blocking `Process`), and inside the `@MainActor` `dispatch_once`
    /// that lets `waitUntilExit` pump the main runloop and re-enter the same once-block — a
    /// recursive-lock trap. Detection stays off the initializer, always.
    private(set) var installed: Bool = false
    /// The installed CLI's version ("0.147.0"), refreshed with `installed`; nil until probed.
    private(set) var version: String?
    /// An install is currently running (drives the spinner + disables the button).
    private(set) var installing = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var installStatus: String?
    /// True once install RETRIES are exhausted and codex still isn't on disk — drives onboarding's
    /// "install it yourself" panel. Reset when a fresh `ensureInstalled` run begins; any positive
    /// detection (`refreshInstalled`) clears it.
    private(set) var installGaveUp = false

    /// Cheap re-detect of step 1's status — call on appear and after an install. Runs the probe
    /// off the main thread (`locateBinary()` can spawn a login shell), so it never blocks the UI.
    func refreshInstalled() async {
        installed = await Task.detached { CodexCLI.locateBinary() != nil }.value
        if installed { installGaveUp = false }
        version = installed ? await CodexCLI.installedVersion() : nil
    }

    /// One successful installer run already happened this launch — the once-per-launch guard for
    /// the onboarding screen's update kick (a second run would just re-resolve the same release).
    private(set) var ranInstallerThisLaunch = false

    /// Step 1 — install OR update the Codex CLI via OpenAI's official installer. Always runs the
    /// script, even over an existing install: it updates in place (auth/config untouched), so the
    /// setup flow always drops the latest computer use into the latest CLI. Streams the
    /// installer's output into `installStatus` (and the console). Both onboarding and the dev
    /// button call THIS — no duplicated logic.
    func installCodex() async {
        guard !installing else { return }
        let updating = CodexCLI.locateBinary() != nil
        let before = version
        installing = true
        installStatus = updating ? "Updating Codex CLI…" : "Installing Codex CLI…"
        do {
            try await CodexCLI.install { [weak self] line in
                Log("[codex-install] \(line)")
                Task { @MainActor in self?.installStatus = line }
            }
            installed = true
            ranInstallerThisLaunch = true
            installStatus = updating ? "✓ Codex CLI up to date" : "✓ Codex CLI installed"
            // The installer resolves and lays down the newest release, so a run counts as today's
            // update: stamp the daily cap, clear the stale-client flag, and learn the new version.
            Self.stampUpdateAttempt()
            outdated = false
            version = await CodexCLI.installedVersion()
            if updating, let before, let after = version, before != after {
                Log("CodexSetup: Codex CLI updated \(before) → \(after)")
                Analytics.signal("Codex.updated", parameters: ["from": before, "to": after])
            }
        } catch {
            installed = CodexCLI.locateBinary() != nil
            // A failed UPDATE still leaves a working codex — don't wave a ✗ at a healthy setup.
            installStatus = installed
                ? "✓ Codex CLI present (update skipped: \((error as? LocalizedError)?.errorDescription ?? "\(error)"))"
                : "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.install, error, binaryFound: installed)   // "installer ran, binary missing" if false
        }
        installing = false
    }

    /// Install with retries; flip `installGaveUp` when the budget is spent and codex still isn't
    /// here. The ONE place the install RETRY policy lives — both the launch kick (AppState) and the
    /// onboarding screen drive this, so there's no second, divergent loop. A no-op if codex is
    /// already present or an install is already running. Each attempt is patient (900s + curl
    /// speed-limits in CodexCLI.install), so a slow download finishes on the first try; fast-failing
    /// causes (no network, connection reset, region block) exhaust the retries in a couple minutes
    /// and surface the "install it yourself" panel.
    func ensureInstalled(attempts: Int = 3) async {
        guard !installed, !installing else { return }
        installGaveUp = false
        for attempt in 1...attempts {
            await installCodex()
            if installed { return }
            if attempt < attempts {
                Log("CodexSetup: install attempt \(attempt) failed — retrying in 10s")
                try? await Task.sleep(for: .seconds(10))
            }
        }
        installGaveUp = !installed
        if installGaveUp { Log("CodexSetup: install gave up after \(attempts) attempts — surfacing the manual-install panel") }
    }

    // MARK: Keeping the CLI current (the daily update)
    //
    // Sentient's managed CLI shares `~/.codex` with every other codex on the Mac, and the ChatGPT
    // desktop app updates itself: when its newer CLI rewrites a shared cache in a schema ours can't
    // read, our runs start logging errors and can fail (the 1.3 field report: `failed to renew
    // cache TTL: missing field \`base_instructions\``). So the CLI we install is also the CLI we
    // keep current — silently, at most once a day, only when the user is away and nothing is
    // running codex, and only for the managed copy (a brew/npm codex is the user's package
    // manager's job).

    private static let lastUpdateAttemptKey = "codex.lastUpdateAttempt"

    /// The most recent daily update attempt (success or not) — the 24 h cap.
    private static var lastUpdateAttempt: Date? {
        UserDefaults.standard.object(forKey: lastUpdateAttemptKey) as? Date
    }

    private static func stampUpdateAttempt() {
        UserDefaults.standard.set(Date(), forKey: lastUpdateAttemptKey)
    }

    /// A run failed on the stale-client signature and the fix hasn't landed yet. Drives the home's
    /// red health rung and the Health row's "needs an update"; cleared by any successful install.
    /// Session-only: the next run re-flags it if the CLI is still stale after a relaunch.
    private(set) var outdated = false

    /// The signature showed up in a run that still SUCCEEDED (an older CLI logs the cache error and
    /// refetches). Drifting, not broken: the next idle tick may update ahead of the daily cap.
    private var staleSignalSeen = false

    func noteStaleSignal() {
        if !staleSignalSeen { Log("CodexSetup: stale-client signature on a successful run — the next idle tick may update early") }
        staleSignalSeen = true
    }

    private var keepCurrentTimer: Timer?
    /// "Is the one-task-at-a-time lock held?" — supplied by AppState, which owns the coordinator.
    private var runLockHeld: (@MainActor () -> Bool)?

    /// The daily update, self-guarding: only over the managed install, at most one attempt per
    /// 24 h (hourly at most when a run just showed the stale-client signature), and only when a
    /// newer release actually exists (a 1 KB feed read + `codex --version`;
    /// re-running the installer over the current version would re-download and re-stage the same
    /// release for nothing). If the version check itself can't decide (offline, feed shape drift),
    /// the installer runs and resolves on its own — the pre-1.4 behavior. `trigger` names the
    /// caller in the log ("idle" · "overnight").
    func updateIfDue(trigger: String) async {
        // An engine out of service earns no background downloads: while Claude is the backend,
        // codex sits idle (chatgpt AND custom both run through codex, so only .claude skips).
        guard ModelBackend.current != .claude else { return }
        guard installed, !installing else { return }
        guard CodexCLI.usingManagedBinary else { return }   // not ours to update
        // Once a day; a stale-client signal on a successful run pulls the next attempt forward,
        // but never more often than hourly (each attempt is at least a version check).
        guard Self.sinceLastUpdateAttempt >= 86_400
                || (staleSignalSeen && Self.sinceLastUpdateAttempt >= 3_600) else { return }
        staleSignalSeen = false
        Self.stampUpdateAttempt()
        await updateToLatest(trigger: trigger)
    }

    private static var sinceLastUpdateAttempt: TimeInterval {
        lastUpdateAttempt.map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// The version pre-check, then the installer only if a newer release exists.
    private func updateToLatest(trigger: String) async {
        let current = await CodexCLI.installedVersion()
        version = current
        let latest = await CodexCLI.latestReleasedVersion()
        if let current, let latest, !CodexCLI.isNewer(latest, than: current) {
            Log("CodexSetup: update (\(trigger)) — Codex CLI \(current) is already the newest release")
            return
        }
        Log("CodexSetup: update (\(trigger)) — \(current ?? "?") → \(latest ?? "latest"), running the installer")
        await installCodex()
    }

    /// Start the periodic trigger (call once from launch, after onboarding). Every 15 minutes it
    /// asks: is the user away from the app (UserPresence), is the pipeline idle, and is the
    /// Sidekick/card run lock free (`isBusy`, supplied by AppState which owns the coordinator)?
    /// Then `updateIfDue` applies its own daily cap. Fires the first check right away, so a Mac
    /// that has been asleep past its 24 h stamp catches up soon after login.
    func startKeepingCurrent(isBusy: @escaping @MainActor () -> Bool) {
        runLockHeld = isBusy
        keepCurrentTimer?.invalidate()
        keepCurrentTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in CodexSetup.shared.keepCurrentTick() }
        }
        Task {
            try? await Task.sleep(for: .seconds(90))   // let launch settle before spawning anything
            keepCurrentTick()
        }
    }

    private func keepCurrentTick() {
        guard !installing, UserPresence.isAwayFromApp, !PipelineActivity.shared.isRunning,
              runLockHeld?() != true else { return }
        Task { await updateIfDue(trigger: "idle") }
        // The one idle tick keeps EVERY managed engine CLI current — ClaudeSetup self-guards
        // (only while Claude is the backend, only the managed binary, once a day).
        Task { await ClaudeSetup.shared.updateIfDue(trigger: "idle") }
        // …and keeps the computer-use attach set classified (task 1.6): the chips + every
        // detected connector. Self-guards (Claude backend only) and cache hits are free, so
        // this is one-time work per CLI version, done while the user is away.
        Task { await ConnectorClassifier.sweepComputerUseAttachables() }
    }

    /// A codex run just failed on the stale-client signature (CodexCLI classified it). Flag it for
    /// the health rung, and if the binary is ours, update right now — outside the daily cap, but
    /// still behind the version pre-check and an hourly floor, so a Mac whose shared `~/.codex` is
    /// ahead of the newest RELEASE (the desktop app runs alphas) doesn't re-download the same CLI
    /// on every failed run. Not ours (brew/npm): the flag alone speaks, and the Health row's
    /// "Update…" lays down a managed copy if the user wants one. `outdated` clears only when an
    /// install actually lands, so an unfixable state keeps saying so.
    func repairStaleClient() async {
        outdated = true
        let managed = CodexCLI.usingManagedBinary
        Log("CodexSetup: a run failed on the stale-client signature (managed=\(managed)) — \(managed ? "updating now" : "not our binary; flagging only")")
        guard managed, !installing else { return }
        guard Self.sinceLastUpdateAttempt >= 3_600 else {
            Log("CodexSetup: an update was already attempted within the hour — not retrying")
            return
        }
        Self.stampUpdateAttempt()
        await updateToLatest(trigger: "stale-client")
    }

    // MARK: Step 2 — auth (codex login)

    /// Is codex logged in? Ground truth = `codex login status` (refreshed async — there's no cheap
    /// synchronous check). No subscription gate needed: codex is in every OpenAI plan, free included.
    private(set) var loggedIn = false
    /// A login flow is in progress — the browser opened, awaiting the user to finish + confirm.
    private(set) var loggingIn = false
    /// Latest status line for step 2.
    private(set) var loginStatusLine: String?
    /// The running `codex login` process (the localhost OAuth callback server) — kept so we can
    /// terminate it on restart/cleanup. It self-exits once auth.json is written.
    private var loginProcess: Process?

    /// Re-check login status via `codex login status` — call on appear and after a confirm.
    func refreshLoginStatus() async {
        loggedIn = await CodexCLI.loginStatus()
        if loggedIn { loggingIn = false }
    }

    /// Step 2a — start the interactive login. Spawns `codex login` (opens the browser) and flips into
    /// the "awaiting browser" state; the user finishes in the browser, then taps "Finished logging
    /// into codex" → `confirmLogin()`. Both onboarding and the dev button call THIS.
    func startLogin(force: Bool = false) {
        guard installed else { loginStatusLine = "✗ Install the Codex CLI first"; return }
        if !force, loggedIn { loginStatusLine = "✓ Already logged in"; return }   // self-guard; "Log in again" passes force
        loginProcess?.terminate()          // kill any stale attempt before re-opening
        loginProcess = nil
        do {
            // URLs elided from the stream: the login flow prints the OAuth auth URL (PKCE/state
            // params), and every Log() line ships as a Release breadcrumb.
            loginProcess = try CodexCLI.startLogin { line in
                Log("[codex-signin] \(line.contains("://") ? "<url elided>" : line)")
            }
            loggingIn = true
            // UI-neutral on purpose: onboarding and Settings → Health both auto-notice the
            // finished sign-in (no confirm button); only the dev sheet still has one.
            loginStatusLine = "A browser window opened; finish signing in there. Sentient notices on its own when you're done."
        } catch {
            loggingIn = false
            loginStatusLine = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.login, error)
        }
    }

    /// Step 2b — the "Finished logging into codex" button. Checks `codex login status`; on success
    /// cleans up the (by now finished) login process. On failure, leaves the flow open to retry.
    func confirmLogin() async {
        loginStatusLine = "Checking…"
        let ok = await CodexCLI.loginStatus()
        loggedIn = ok
        if ok {
            loggingIn = false
            loginProcess?.terminate()      // the OAuth callback server already did its job
            loginProcess = nil
            loginStatusLine = "✓ Logged in to Codex"
        } else {
            loginStatusLine = "✗ Not logged in yet; finish in the browser, then tap again."
        }
    }

    // MARK: Step 3 — the computer-use driver (cua-driver)
    //
    // The hands (see Driver/CuaDriver): one pinned ~40 MB binary that codex loads as an MCP server
    // and that acts inside a single window without stealing the cursor. Unlike steps 1 and 2 it
    // needs NO codex binary and no login — a self-contained download that can run before, during,
    // or after the rest of setup.

    /// Is the pinned cua-driver on disk?
    private(set) var cuaDriverReady = CuaDriver.isInstalled
    /// A cua-driver install is running (drives the spinner + disables the button).
    private(set) var settingUpCuaDriver = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var cuaDriverStatus: String?

    /// Cheap re-detect — call on appear and after a setup.
    func refreshCuaDriver() { cuaDriverReady = CuaDriver.isInstalled }

    /// Step 3 — download + verify + install the pinned cua-driver. Detection-first (a no-op when
    /// the pinned version is already there; `force` re-fetches). Onboarding, the dev tools, and
    /// the Health pane's fix all call THIS — no duplicated logic.
    func setupCuaDriver(force: Bool = false) async {
        guard !settingUpCuaDriver else { return }
        if !force, CuaDriver.isInstalled {
            cuaDriverReady = true
            cuaDriverStatus = "✓ Cua driver already installed"
            return
        }
        settingUpCuaDriver = true
        cuaDriverStatus = force ? "Re-installing…" : "Starting…"
        do {
            try await CuaDriverSetup.install(force: force) { [weak self] line in
                Log("[cua-driver] \(line)")
                Task { @MainActor in self?.cuaDriverStatus = line }
            }
            cuaDriverReady = true
            cuaDriverStatus = "✓ Cua driver ready"
        } catch {
            cuaDriverReady = CuaDriver.isInstalled
            cuaDriverStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.cuaDriver, error)
        }
        settingUpCuaDriver = false
    }

    /// The fire-time self-heal (CodexCLI.runAgentCommand): make sure the pinned driver is on disk
    /// before a computer-use run. Installed → immediate true. An install already in flight
    /// (onboarding's fetch, a Health fix) → wait for IT rather than racing a second download over
    /// the same staging. Otherwise run the normal setup (a measured 2–3 s on a good connection).
    /// Returns the final on-disk truth; the caller still guards on it.
    @discardableResult
    func ensureCuaDriver() async -> Bool {
        if CuaDriver.isInstalled { cuaDriverReady = true; return true }
        if settingUpCuaDriver {
            // Bounded wait — a stuck download must fail the fire, not hang it forever.
            for _ in 0..<480 where settingUpCuaDriver {   // ~2 min at 250 ms
                try? await Task.sleep(for: .milliseconds(250))
            }
        } else {
            await setupCuaDriver()
        }
        refreshCuaDriver()
        return cuaDriverReady
    }

    // MARK: Onboarding driver (one source of truth for BOTH a dumb-sequential and a smart flow)

    /// The three setup steps, in order.
    enum Step: String, Sendable { case install, login, cuaDriver }

    /// §7.24: a setup step failed — error TYPE only (never the streamed installer/login lines, which
    /// embed paths/account hints). `binary_found` on install is the specific "installer ran, binary
    /// missing" signal. Called from each step's catch.
    private func stepFailed(_ step: Step, _ error: Error, binaryFound: Bool? = nil) {
        var extra: [String: String] = [:]
        if let binaryFound { extra["binary_found"] = String(binaryFound) }
        CrashReporting.captureEvent("codex_setup.step_failed", level: .warning,
            tags: ["step": step.rawValue, "error": String(describing: type(of: error))],
            extra: extra, fingerprint: ["codex_setup", "step_failed", step.rawValue])
    }

    /// Authoritative, FRESH check of all three steps: re-detects the binary on disk, runs
    /// `codex login status`, and re-checks the driver install — then returns the steps still
    /// PENDING, in order. A smart onboarding calls this to decide what to render/run; a dumb
    /// "just run all three in order" driver can ignore it because every action (installCodex /
    /// startLogin / setupCuaDriver) already self-guards and no-ops when its step is done.
    func whatsNeeded() async -> [Step] {
        await refreshInstalled()
        await refreshLoginStatus()
        refreshCuaDriver()
        var pending: [Step] = []
        if !installed      { pending.append(.install) }
        if !loggedIn       { pending.append(.login) }
        if !cuaDriverReady { pending.append(.cuaDriver) }
        return pending
    }
}
