// Observable Codex CLI installation, login and update flow shared by onboarding and Settings.
// ComputerUseSetup independently prepares the selected native or CUA computer-use runtime.
// Key methods: ensureCurrent(), ensureInstalled(), startLogin(), updateIfDue(), whatsNeeded().
// Doc: Cloud/Documentation - Cloud - Codex Setup.md

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

    /// Preparation includes the release check and retry waits as well as the installer itself.
    private(set) var preparing = false
    private var preparationTask: Task<Bool, Never>?
    private var installTask: Task<Bool, Never>?
    private var installProgressID: UUID?
    /// Avoid repeating the release check between sign-in and Continue. A different binary
    /// version (including a downgrade outside Sentient) must pass preparation again.
    private var preparedVersion: String?

    /// Called only when the user commits to a Codex-backed engine, including Continue for an
    /// existing login. An old brew/npm install gets a standalone copy; its package is untouched.
    /// Concurrent callers await the same preparation, and failed preparation is always retryable.
    func ensureCurrent() async -> Bool {
        if let preparationTask { return await preparationTask.value }
        preparing = true
        let task = Task { await prepareCurrent() }
        preparationTask = task
        let ready = await task.value
        preparationTask = nil
        preparing = false
        return ready
    }

    private func prepareCurrent() async -> Bool {
        if let installTask { _ = await installTask.value }
        await refreshInstalled()
        if let version, version == preparedVersion, await CodexCLI.isRunnable() { return true }

        installStatus = "Checking Codex CLI…"
        let latest = await CodexCLI.latestReleasedVersion()
        if let version, let latest, !CodexCLI.isNewer(latest, than: version),
           await CodexCLI.isRunnable() {
            preparedVersion = version
            installStatus = "✓ Codex CLI up to date"
            return true
        }
        if let version, let latest, CodexCLI.isNewer(latest, than: version) { outdated = true }
        // An unavailable feed falls back to the installer's own release resolution. The
        // installer still has to succeed and produce a runnable managed binary.
        return await installWithRetries(expectedVersion: latest)
    }

    /// Step 1 — install OR update the Codex CLI via OpenAI's official installer. Always runs the
    /// script, even over an existing install. Only a verified installer result counts as success;
    /// preserving an old executable on failure does not mean it was updated.
    @discardableResult
    func installCodex(expectedVersion: String? = nil) async -> Bool {
        if let installTask {
            guard await installTask.value else { return false }
            // A caller may have learned of a newer release while another install was running.
            if let expectedVersion, let version, CodexCLI.isNewer(expectedVersion, than: version) {
                outdated = true
                preparedVersion = nil
                installStatus = "✗ Codex CLI still needs an update. Try again."
                return false
            }
            return true
        }
        installing = true
        let task = Task { await performInstall(expectedVersion: expectedVersion) }
        installTask = task
        let success = await task.value
        installTask = nil
        installing = false
        return success
    }

    private func performInstall(expectedVersion: String?) async -> Bool {
        await refreshInstalled()
        let updating = installed
        let before = version
        preparedVersion = nil
        installStatus = updating ? "Updating Codex CLI…" : "Installing Codex CLI…"
        let progressID = UUID()
        installProgressID = progressID
        do {
            let target: String?
            if let expectedVersion { target = expectedVersion }
            else { target = await CodexCLI.latestReleasedVersion() }
            let verifiedVersion = try await CodexCLI.install(expectedVersion: target) { [weak self] line in
                Log("[codex-install] \(line)")
                Task { @MainActor in
                    if self?.installProgressID == progressID { self?.installStatus = line }
                }
            }
            installProgressID = nil
            installed = true
            installGaveUp = false
            version = verifiedVersion
            preparedVersion = verifiedVersion
            installStatus = updating ? "✓ Codex CLI up to date" : "✓ Codex CLI installed"
            // The installer resolves and lays down the newest release, so a run counts as today's
            // update: stamp the daily cap, clear the stale-client flag, and learn the new version.
            Self.stampUpdateAttempt()
            outdated = false
            if updating, let before, let after = version, before != after {
                Log("CodexSetup: Codex CLI updated \(before) → \(after)")
                Analytics.signal("Codex.updated", parameters: ["from": before, "to": after])
            }
            return true
        } catch {
            installProgressID = nil
            await refreshInstalled()
            installStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.install, error, binaryFound: installed)   // "installer ran, binary missing" if false
            return false
        }
    }

    /// Presence-only setup for callers that do not need the engine commitment/version gate.
    func ensureInstalled(attempts: Int = 3) async {
        await refreshInstalled()
        guard !installed else { return }
        _ = await installWithRetries(attempts: attempts)
    }

    /// One retry policy for fresh installs and updates. A surviving old binary is never a
    /// successful attempt. Fresh-install exhaustion also exposes the manual-install guide.
    private func installWithRetries(attempts: Int = 3, expectedVersion: String? = nil) async -> Bool {
        installGaveUp = false
        guard attempts > 0 else { return false }
        for attempt in 1...attempts {
            guard !Task.isCancelled else { return false }
            if await installCodex(expectedVersion: expectedVersion) { return true }
            if attempt < attempts {
                Log("CodexSetup: install attempt \(attempt) failed — retrying in 10s")
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return false }
            }
        }
        installGaveUp = !installed
        if installGaveUp { Log("CodexSetup: install gave up after \(attempts) attempts — surfacing the manual-install panel") }
        return false
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

    /// A version check found an older CLI, or a run failed on the stale-client signature.
    /// Drives the health row's "needs an update" until a verified install succeeds. Session-only;
    /// the next version check or stale-client failure can flag it again after a relaunch.
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
        guard installed, !installing, !preparing else { return }
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
        if let current, let latest, CodexCLI.isNewer(latest, than: current) { outdated = true }
        await installCodex(expectedVersion: latest)
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

    // MARK: Onboarding driver (one source of truth for BOTH a dumb-sequential and a smart flow)

    /// The three setup steps, in order.
    enum Step: String, Sendable { case install, login, computerUse }

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
    /// startLogin / ComputerUseSetup.install) already self-guards and no-ops when its step is done.
    func whatsNeeded() async -> [Step] {
        await refreshInstalled()
        await refreshLoginStatus()
        ComputerUseSetup.current.refresh()
        var pending: [Step] = []
        if !installed      { pending.append(.install) }
        if !loggedIn       { pending.append(.login) }
        if !ComputerUseSetup.current.ready { pending.append(.computerUse) }
        return pending
    }
}
