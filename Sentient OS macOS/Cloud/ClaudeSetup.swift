//
//  ClaudeSetup.swift
//  Sentient OS macOS
//
//  The Claude engine's setup flow — CodexSetup's sibling, two steps instead of three:
//    1. INSTALL — drop the Claude Code binary on disk (Anthropic's official installer).
//    2. AUTH    — `claude auth login` with the user's Claude account (Pro/Max/Team; there is
//                 no free tier, so logged-in IS the plan gate).
//  ComputerUseSetup prepares Codex CLI and the native helper at launch for every engine.
//
//  Claude Code installs only when the user commits to Claude on the frontier-model surface.
//  Its subscription login remains separate from the shared computer-use dependencies.
//
//  Key methods:
//   - refreshInstalled() / installClaude() / ensureCurrent()   → verified setup (+ retries)
//   - startLogin() / refreshLoginStatus()                      → step 2 (browser OAuth, auto-noticed)
//   - updateIfDue(trigger:)                                    → the daily managed-binary update,
//                                                                only while Claude IS the engine
//
//  Doc: Cloud/Documentation - Cloud - ClaudeCLI (the claude -p engine).md
//

import Foundation

@MainActor
@Observable
final class ClaudeSetup {

    /// One shared instance so onboarding, Settings, and the dev tools observe the same state.
    static let shared = ClaudeSetup()

    private init() {
        // Warm up `installed` off the main thread (the same recursive-lock law as CodexSetup:
        // locateBinary's login-shell fallback must never run inside this initializer).
        Task { await refreshInstalled() }
    }

    // MARK: Step 1 — install

    /// Is the Claude Code binary present on disk? (NOT whether it's logged in — that's step 2.)
    private(set) var installed = false
    /// The installed version ("2.1.233"), refreshed with `installed`; nil until probed.
    private(set) var version: String?
    /// An install is currently running (drives the spinner + disables the button).
    private(set) var installing = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var installStatus: String?
    /// True once install retries are exhausted and claude still isn't on disk — drives the
    /// install-it-yourself panel. Reset when a fresh ensureCurrent run begins; any positive
    /// detection clears it.
    private(set) var installGaveUp = false
    /// Includes retry waits as well as the update command itself.
    private(set) var preparing = false
    private var preparationTask: Task<Bool, Never>?
    private var installTask: Task<Bool, Never>?
    private var installProgressID: UUID?
    /// Share successful preparation between Use Claude/sign-in and Continue this launch.
    private var preparedVersion: String?

    /// Cheap re-detect of step 1 — call on appear and after an install. Off-main (locateBinary
    /// can spawn a login shell).
    func refreshInstalled() async {
        installed = await Task.detached { ClaudeCLI.locateBinary() != nil }.value
        if installed { installGaveUp = false }
        version = installed ? await ClaudeCLI.installedVersion() : nil
    }

    /// Existing CLI: `claude update`. Missing CLI: the official installer, then the same update
    /// verification. A surviving old executable is not evidence that an update succeeded.
    @discardableResult
    func installClaude() async -> Bool {
        if let installTask { return await installTask.value }
        installing = true
        let task = Task { await performInstall() }
        installTask = task
        let success = await task.value
        installTask = nil
        installing = false
        return success
    }

    private func performInstall() async -> Bool {
        await refreshInstalled()
        let updating = installed
        let before = version
        preparedVersion = nil
        installStatus = updating ? "Updating Claude Code…" : "Installing Claude Code…"
        let progressID = UUID()
        installProgressID = progressID
        let progress: @Sendable (String) -> Void = { [weak self] line in
            Log("[claude-install] \(line)")
            Task { @MainActor in
                if self?.installProgressID == progressID { self?.installStatus = line }
            }
        }
        do {
            if !installed { _ = try await ClaudeCLI.install(onLine: progress) }
            let verifiedVersion = try await ClaudeCLI.update(onLine: progress)
            installProgressID = nil
            installed = true
            installGaveUp = false
            version = verifiedVersion
            preparedVersion = verifiedVersion
            installStatus = updating ? "✓ Claude Code up to date" : "✓ Claude Code installed"
            Self.stampUpdateAttempt()
            if updating, let before, let after = version, before != after {
                Log("ClaudeSetup: Claude Code updated \(before) → \(after)")
                Analytics.signal("Claude.updated", parameters: ["from": before, "to": after])
            }
            return true
        } catch {
            installProgressID = nil
            await refreshInstalled()
            let detail = (error as? ClaudeCLI.SetupError)?.errorDescription
                ?? "Claude Code couldn't be prepared. Try again, or run claude update in Terminal."
            installStatus = "✗ \(detail)"
            stepFailed(.install, error, binaryFound: installed)
            return false
        }
    }

    /// Commitment-only preparation: sign-in, Use Claude, or Continue with an existing login.
    /// Concurrent callers share the same update; failed attempts remain retryable.
    func ensureCurrent(attempts: Int = 3) async -> Bool {
        if let preparationTask { return await preparationTask.value }
        preparing = true
        let task = Task { await prepareCurrent(attempts: attempts) }
        preparationTask = task
        let ready = await task.value
        preparationTask = nil
        preparing = false
        return ready
    }

    private func prepareCurrent(attempts: Int) async -> Bool {
        if let installTask { _ = await installTask.value }
        await refreshInstalled()
        if let version, version == preparedVersion, await ClaudeCLI.isRunnable() { return true }
        installGaveUp = false
        guard attempts > 0 else { return false }
        for attempt in 1...attempts {
            guard !Task.isCancelled else { return false }
            if await installClaude() { return true }
            if attempt < attempts {
                Log("ClaudeSetup: install attempt \(attempt) failed — retrying in 10s")
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return false }
            }
        }
        installGaveUp = !installed
        if installGaveUp { Log("ClaudeSetup: install gave up after \(attempts) attempts — surfacing the manual-install panel") }
        return false
    }

    // MARK: Keeping the CLI current (the daily update)

    private static let lastUpdateAttemptKey = "claude.lastUpdateAttempt"

    private static var sinceLastUpdateAttempt: TimeInterval {
        (UserDefaults.standard.object(forKey: lastUpdateAttemptKey) as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
    }

    private static func stampUpdateAttempt() {
        UserDefaults.standard.set(Date(), forKey: lastUpdateAttemptKey)
    }

    /// The daily update, self-guarding: only while Claude IS the active engine (an engine out of
    /// service earns no background downloads), only over the managed install, at most once per
    /// 24 h. `claude update` resolves the user's release channel and skips downloads when current.
    /// Rides the same idle tick as codex's updater (CodexSetup.startKeepingCurrent calls both).
    func updateIfDue(trigger: String) async {
        guard ModelBackend.hasClaudeRuntime else { return }
        guard installed, !installing, !preparing else { return }
        guard ClaudeCLI.usingManagedBinary else { return }   // brew/npm claude is the user's to update
        guard Self.sinceLastUpdateAttempt >= 86_400 else { return }
        Self.stampUpdateAttempt()
        Log("ClaudeSetup: update (\(trigger)) — checking with claude update")
        await installClaude()
    }

    // MARK: Step 2 — auth (claude auth login)

    /// Runtime rejection overrides an earlier local status, including while a view is open.
    private var statusLoggedIn = false
    var loggedIn: Bool { statusLoggedIn && !ClaudeAuth.requiresVerification }
    /// The plan's display name ("Max", "Pro"…), refreshed with the login status.
    private(set) var plan: String?
    /// A login flow is in progress — the browser opened, awaiting the user to finish.
    private(set) var loggingIn = false
    private(set) var verifyingLogin = false
    private(set) var verificationPending = false
    var loginActionTitle: String { verificationPending ? "Check Claude sign-in" : "Sign in to Claude" }
    /// Exact automatic browser URL for this attempt, never persisted or logged.
    private(set) var loginURL: URL?
    /// Latest status line for step 2.
    private(set) var loginStatusLine: String?
    /// The running `claude auth login` process — kept so we can terminate it on restart/cleanup.
    private var loginProcess: Process?
    private var loginGeneration = UUID()
    private var loginStatusProbe = UUID()
    private var authRevision: UUID?
    private var verificationTask: Task<Void, Never>?

    /// Refresh observable UI state without spawning a status poll that could race OAuth.
    func authenticationRejected() {
        if ClaudeAuth.requiresVerification { statusLoggedIn = false }
    }

    /// Re-check login + plan — call on appear, on foreground, and while a login is out.
    func refreshLoginStatus() async {
        // The old credential can still look logged in while OAuth is unfinished. Only the
        // owned process's successful exit starts verification; polling never completes login.
        guard !Task.isCancelled, !loggingIn else { return }
        let generation = loginGeneration
        let probe = UUID()
        loginStatusProbe = probe
        let status = await ClaudeAuth.refresh()
        guard !Task.isCancelled, !loggingIn, generation == loginGeneration, probe == loginStatusProbe else { return }
        statusLoggedIn = status.loggedIn
        plan = ClaudeAuth.planDisplayName
        if loggedIn {
            verificationPending = false
        }
    }

    /// Step 2a — start the interactive login. Spawns `claude auth login` (opens the browser) and
    /// flips into the awaiting-browser state; the panels notice the finished sign-in on their own.
    func startLogin(force: Bool = false) {
        guard installed else { loginStatusLine = "✗ Install Claude Code first"; return }
        guard !loggingIn else { return }
        if !force, loggedIn { loginStatusLine = "✓ Already signed in"; return }
        if verificationPending {
            startVerification(generation: loginGeneration)
            return
        }
        cancelLogin()
        ClaudeAuth.beginAccountChange()
        let generation = loginGeneration
        authRevision = ClaudeAuth.beginLogin()
        statusLoggedIn = false
        loggingIn = true
        loginStatusLine = "A browser window opened; finish signing in there. Sentient will then check your sign-in."
        do {
            loginProcess = try ClaudeCLI.startLogin(onURL: { [weak self] url in
                guard let self else { return }
                Task { @MainActor in
                    guard self.loginGeneration == generation, self.loggingIn,
                          self.loginProcess?.isRunning == true else { return }
                    self.loginURL = url
                }
            }, onExit: { [weak self] status in
                guard let self else { return }
                Task { @MainActor in
                    guard self.loginGeneration == generation else { return }
                    self.loginURL = nil
                    self.loginProcess = nil
                    if status == 0 {
                        self.startVerification(generation: generation)
                    } else {
                        self.loggingIn = false
                        self.loginStatusLine = "✗ Sign-in didn't finish. Please try again."
                    }
                }
            })
        } catch {
            loggingIn = false
            loginURL = nil
            loginStatusLine = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.login, error)
        }
    }

    private func startVerification(generation: UUID) {
        let revision = ClaudeAuth.revision
        authRevision = revision
        loggingIn = true
        verifyingLogin = true
        verificationPending = true
        loginStatusLine = "Checking that Claude accepts your sign-in…"
        verificationTask = Task { [weak self] in
            do {
                try await ClaudeAuth.verifyLogin(revision: revision)
                guard let self, !Task.isCancelled, self.loginGeneration == generation else { return }
                self.statusLoggedIn = ClaudeAuth.cachedLoggedIn
                self.plan = ClaudeAuth.planDisplayName
                self.verificationPending = false
                self.loginStatusLine = self.loggedIn ? "✓ Signed in to Claude"
                    : "✗ Claude rejected the sign-in again. Please sign in to continue."
                self.finishVerification()
            } catch {
                guard let self, !Task.isCancelled, self.loginGeneration == generation else { return }
                ClaudeAuth.rejected(error, after: revision)
                self.statusLoggedIn = false
                if error is ClaudeAuth.LoginRequired {
                    self.verificationPending = false
                    self.loginStatusLine = "✗ Claude still rejected this sign-in. Please sign in again."
                } else if CodexFailureReason.classify(error) == .usageLimit {
                    self.loginStatusLine = "✗ Claude's usage limit prevented the check. Wait for it to reset, then check your sign-in again."
                } else {
                    self.loginStatusLine = "✗ Couldn't verify Claude's sign-in. Check your connection, then try Check Claude sign-in."
                }
                self.finishVerification()
                if !(error is CancellationError) { self.stepFailed(.verify, error) }
            }
        }
    }

    private func finishVerification() {
        verificationTask = nil
        verifyingLogin = false
        loggingIn = false
        loginURL = nil
    }

    /// Stop a login attempt that's still out (tab switched away, restart) — the process is the
    /// localhost OAuth callback server; it self-exits after a finished sign-in anyway.
    func cancelLogin() {
        loginGeneration = UUID()
        loginStatusProbe = UUID()
        verificationTask?.cancel()
        verificationTask = nil
        if let authRevision { ClaudeAuth.cancelLogin(revision: authRevision) }
        authRevision = nil
        if let process = loginProcess, process.isRunning { process.terminate() }
        loginProcess = nil
        loggingIn = false
        verifyingLogin = false
        verificationPending = false
        loginURL = nil
        loginStatusLine = nil
    }

    // MARK: Diagnostics

    enum Step: String, Sendable { case install, login, verify }

    /// Structure-only failure signal — error TYPE only, never the streamed installer/login lines.
    private func stepFailed(_ step: Step, _ error: Error, binaryFound: Bool? = nil) {
        var extra: [String: String] = [:]
        if let binaryFound { extra["binary_found"] = String(binaryFound) }
        CrashReporting.captureEvent("claude_setup.step_failed", level: .warning,
            tags: ["step": step.rawValue, "error": String(describing: type(of: error))],
            extra: extra, fingerprint: ["claude_setup", "step_failed", step.rawValue])
    }
}
