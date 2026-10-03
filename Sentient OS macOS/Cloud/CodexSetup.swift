// Observable Codex CLI installation, login and update flow shared by onboarding and Settings.
// ComputerUseSetup prepares native computer use and requests Codex without a ChatGPT login for Claude.
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

    /// Presence in Sentient's private runtime, independently of sign-in.
    private(set) var installed: Bool = false
    /// The installed CLI's version ("0.160.0"), refreshed with `installed`; nil until probed.
    private(set) var version: String?
    /// An install is currently running (drives the spinner + disables the button).
    private(set) var installing = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var installStatus: String?
    /// True once install RETRIES are exhausted and codex still isn't on disk — drives onboarding's
    /// download retry panel. Reset when a fresh `ensureInstalled` run begins; any positive
    /// detection (`refreshInstalled`) clears it.
    private(set) var installGaveUp = false

    /// Cheap re-detect of step 1's status — call on appear and after an install. Runs the probe
    /// off the main thread (package validation may touch disk), so it never blocks the UI.
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
    private var computerPreparation: Task<Void, Never>?
    private var computerPreparationSucceeded = false
    static let computerUseMinimumVersion = "0.160.0"
    var computerUseReady: Bool {
        installed && version.map { !CodexCLI.isNewer(Self.computerUseMinimumVersion, than: $0) } == true
    }

    /// Every computer-use engine needs Codex, but only ChatGPT needs a Codex login.
    /// Callers can stop waiting while the shared background installation finishes.
    func ensureComputerUseCLI() async -> Bool {
        if let version = await CodexCLI.installedVersion(),
           !CodexCLI.isNewer(Self.computerUseMinimumVersion, than: version), await CodexCLI.isRunnable() {
            self.version = version; installed = true
            return !Task.isCancelled
        }
        if computerPreparation == nil {
            computerPreparationSucceeded = false
            computerPreparation = Task {
                let prepared = await ensureCurrent()
                computerPreparationSucceeded = prepared && computerUseReady
                computerPreparation = nil
            }
        }
        while computerPreparation != nil {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return false }
        }
        return computerPreparationSucceeded && !Task.isCancelled
    }

    /// Used by engine commitment and by startup when computer use needs a compatible CLI.
    /// Downloads the approved private runtime; a user-managed CLI is untouched.
    /// Concurrent callers await the same preparation, and failed preparation is always retryable.
    func ensureCurrent() async -> Bool {
        guard !shuttingDown else { return false }
        CodexRuntimeMigration.start(existingUser: true)
        if CodexRuntimeMigration.isPending { return await CodexRuntimeMigration.finishCurrentAttempt() }
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
        let latest = await CodexCLI.approvedVersion()
        if let version, let latest, latest == version,
           await CodexCLI.isRunnable() {
            preparedVersion = version
            installStatus = "✓ Codex CLI up to date"
            return true
        }
        if let version, let latest, latest != version { outdated = true }
        return await installWithRetries(expectedVersion: latest)
    }

    /// Install or repair the approved private CLI. Only a fully verified package counts as success.
    @discardableResult
    func installCodex(expectedVersion: String? = nil) async -> Bool {
        guard !shuttingDown else { return false }
        if let installTask {
            guard await installTask.value else { return false }
            // A caller may have learned of a newer release while another install was running.
            if let expectedVersion, let version, expectedVersion != version {
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
            else { target = await CodexCLI.approvedVersion() }
            let verifiedVersion = try await CodexCLI.install(expectedVersion: target) { [self] line in
                Task { @MainActor [self] in
                    Log("[codex-install] \(line)")
                    if installProgressID == progressID { installStatus = line }
                }
            }
            installProgressID = nil
            installed = true
            installGaveUp = false
            version = verifiedVersion
            preparedVersion = verifiedVersion
            installStatus = updating ? "✓ Codex CLI up to date" : "✓ Codex CLI installed"
            // A verified repair satisfies today’s check and clears the stale-client flag.
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
    /// successful attempt. Fresh-install exhaustion also exposes the download retry panel.
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
        if installGaveUp { Log("CodexSetup: install gave up after \(attempts) attempts — surfacing the download retry panel") }
        return false
    }

    // MARK: Approved runtime health
    // The daily idle check repairs only this app's pinned version. It never reads an upstream
    // release channel, adopts another Codex, or changes versions while a task holds the runtime.

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
    private var shuttingDown = false
    /// "Is the one-task-at-a-time lock held?" — supplied by AppState, which owns the coordinator.
    private var runLockHeld: (@MainActor () -> Bool)?

    /// Verify the pinned runtime at most daily, while idle. Repair a missing or modified package.
    func updateIfDue(trigger: String) async {
        // Every engine uses the private Codex runtime for computer tasks.
        guard !shuttingDown, !CodexRuntimeMigration.isPending else { return }
        guard !installing, !preparing, !PipelineActivity.shared.isRunning, runLockHeld?() != true else { return }
        guard FileManager.default.fileExists(atPath: CodexRuntime.root.path) else { return }
        // Once a day; a stale-client signal on a successful run pulls the next attempt forward,
        // but never more often than hourly (each attempt is at least a version check).
        guard Self.sinceLastUpdateAttempt >= 86_400
                || (staleSignalSeen && Self.sinceLastUpdateAttempt >= 3_600) else { return }
        staleSignalSeen = false
        Self.stampUpdateAttempt()
        await repairApprovedRuntime(trigger: trigger)
    }

    private static var sinceLastUpdateAttempt: TimeInterval {
        lastUpdateAttempt.map { Date().timeIntervalSince($0) } ?? .infinity
    }

    /// Keep the signed app’s approved version; a version change requires a Sentient release.
    private func repairApprovedRuntime(trigger: String) async {
        let current = await CodexCLI.installedVersion()
        version = current
        let latest = await CodexCLI.approvedVersion()
        if let current, let latest, latest == current, await CodexCLI.isRunnable() {
            Log("CodexSetup: update (\(trigger)) — Codex CLI \(current) matches the approved release")
            return
        }
        Log("CodexSetup: update (\(trigger)) — \(current ?? "?") → \(latest ?? "latest"), running the installer")
        if let current, let latest, latest != current { outdated = true }
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
        guard !shuttingDown, !installing, UserPresence.isAwayFromApp, !PipelineActivity.shared.isRunning,
              runLockHeld?() != true else { return }
        Task { await updateIfDue(trigger: "idle") }
        // The one idle tick keeps EVERY managed engine CLI current — ClaudeSetup self-guards
        // (only while Claude is the backend, only the managed binary, once a day).
        Task { await ClaudeSetup.shared.updateIfDue(trigger: "idle") }
        // Keep the dedicated connector action policies classified: the chips + every
        // detected connector. Self-guards (Claude backend only) and cache hits are free, so
        // this is one-time work per CLI version, done while the user is away.
        Task { await ConnectorClassifier.sweepActionConnectors() }
    }

    /// A compatibility failure remains visible until a repair succeeds. An intact pinned release
    /// cannot be upgraded here; a newer CLI must come with a newer Sentient release.
    func repairStaleClient() async {
        outdated = true
        let managed = FileManager.default.fileExists(atPath: CodexRuntime.root.path)
        Log("CodexSetup: a run failed on the stale-client signature (managed=\(managed)) — \(managed ? "checking the approved release" : "not our binary; flagging only")")
        guard managed, !installing, !PipelineActivity.shared.isRunning, runLockHeld?() != true else { return }
        guard Self.sinceLastUpdateAttempt >= 3_600 else {
            Log("CodexSetup: an update was already attempted within the hour — not retrying")
            return
        }
        Self.stampUpdateAttempt()
        await repairApprovedRuntime(trigger: "stale-client")
    }

    /// Uninstall drains all CLI setup work before removing the private home.
    func cancelInstallation() async {
        shuttingDown = true
        keepCurrentTimer?.invalidate()
        loginGeneration = UUID()
        connectorRefreshTask?.cancel()
        _ = await connectorRefreshTask?.value
        if let process = loginProcess, process.isRunning {
            process.terminate()
            await Task.detached { process.waitUntilExit() }.value
        }
        loginProcess = nil
        preparationTask?.cancel()
        installTask?.cancel()
        _ = await preparationTask?.value
        _ = await installTask?.value
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
    private var startingLogin = false
    private var loginGeneration = UUID()
    private var connectorRefreshTask: Task<Void, Never>?
    private var refreshedAccount: String?
    private var lastConnectorRefresh: Date?

    /// Re-check login status via `codex login status` — call on appear and after a confirm.
    func refreshLoginStatus() async {
        loggedIn = await CodexCLI.loginStatus()
        if loggedIn {
            loggingIn = false
            refreshConnectorsAfterLogin()
        }
    }

    /// Step 2a — start the interactive login. Spawns `codex login` (opens the browser) and flips into
    /// the "awaiting browser" state; the user finishes in the browser, then taps "Finished logging
    /// into codex" → `confirmLogin()`. Both onboarding and the dev button call THIS.
    func startLogin(force: Bool = false) async {
        guard !shuttingDown, !startingLogin else { return }
        startingLogin = true
        defer { startingLogin = false }
        let generation = loginGeneration
        guard installed else { loginStatusLine = "✗ Install the Codex CLI first"; return }
        if !force, loggedIn { loginStatusLine = "✓ Already logged in"; return }   // self-guard; "Log in again" passes force
        if let process = loginProcess, process.isRunning {
            process.terminate()
            await Task.detached { process.waitUntilExit() }.value
        }
        guard !Task.isCancelled, generation == loginGeneration else { return }
        loginProcess = nil
        do {
            loginProcess = try CodexCLI.startLogin()
            loggedIn = false
            refreshedAccount = nil
            lastConnectorRefresh = nil
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
            refreshConnectorsAfterLogin()
        } else {
            loginStatusLine = "✗ Not logged in yet; finish in the browser, then tap again."
        }
    }

    private func refreshConnectorsAfterLogin() {
        guard !shuttingDown, !CodexRuntimeMigration.isPending, let account = CodexRuntime.accountIdentity, account != refreshedAccount,
              connectorRefreshTask == nil, loginProcess?.isRunning != true,
              lastConnectorRefresh.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastConnectorRefresh = Date()
        connectorRefreshTask = Task {
            defer { connectorRefreshTask = nil }
            do {
                let changed = try CodexRuntime.prepareAccountCache()
                if changed || !FileManager.default.fileExists(atPath: CodexRuntime.plugins.path) {
                    await ConnectorCensus.refreshCodexCache()
                }
                guard !Task.isCancelled, CodexRuntime.accountIdentity == account else { return }
                _ = ConnectorCensus.persist(ConnectorCensus.listCodex(), for: .chatgpt)
                // A network failure leaves the empty cache retryable on the next status refresh.
                if FileManager.default.fileExists(atPath: CodexRuntime.plugins.path) { refreshedAccount = account }
            } catch { Log("CodexSetup: connector refresh deferred (\(ErrorLabel(error)))") }
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
