//
//  ClaudeSetup.swift
//  Sentient OS macOS
//
//  The Claude engine's setup flow — CodexSetup's sibling, two steps instead of three:
//    1. INSTALL — drop the Claude Code binary on disk (Anthropic's official installer).
//    2. AUTH    — `claude auth login` with the user's Claude account (Pro/Max/Team; there is
//                 no free tier, so logged-in IS the plan gate).
//  The computer-use driver is NOT a step here: the cua driver is engine-neutral and CodexSetup
//  owns its one install path (setupCuaDriver / ensureCuaDriver) for both engines.
//
//  Lazy by design (decision 2026-08-21): NOTHING installs at first launch anymore — this engine
//  (and codex alike) downloads only when the user actually picks it on the frontier-model
//  surface. A user who chooses Claude never downloads codex, and vice versa.
//
//  Key methods:
//   - refreshInstalled() / installClaude() / ensureInstalled() → step 1 (+ retries + give-up flag)
//   - startLogin() / refreshLoginStatus()                      → step 2 (browser OAuth, auto-noticed)
//   - updateIfDue(trigger:)                                    → the daily managed-binary update,
//                                                                only while Claude IS the engine
//
//  Doc: Cloud/Documentation - Cloud - Codex Setup.md (the reference flow; the Claude engine's
//  own doc lands once the feature is tested and confirmed).
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
    /// install-it-yourself panel. Reset when a fresh ensureInstalled run begins; any positive
    /// detection clears it.
    private(set) var installGaveUp = false

    /// Cheap re-detect of step 1 — call on appear and after an install. Off-main (locateBinary
    /// can spawn a login shell).
    func refreshInstalled() async {
        installed = await Task.detached { ClaudeCLI.locateBinary() != nil }.value
        if installed { installGaveUp = false }
        version = installed ? await ClaudeCLI.installedVersion() : nil
    }

    /// Step 1 — install OR update Claude Code via Anthropic's official installer (it updates in
    /// place over an existing install; login untouched). Streams progress into `installStatus`.
    func installClaude() async {
        guard !installing else { return }
        let updating = ClaudeCLI.locateBinary() != nil
        let before = version
        installing = true
        installStatus = updating ? "Updating Claude Code…" : "Installing Claude Code…"
        do {
            try await ClaudeCLI.install { [weak self] line in
                Log("[claude-install] \(line)")
                Task { @MainActor in self?.installStatus = line }
            }
            installed = true
            installStatus = updating ? "✓ Claude Code up to date" : "✓ Claude Code installed"
            Self.stampUpdateAttempt()
            version = await ClaudeCLI.installedVersion()
            if updating, let before, let after = version, before != after {
                Log("ClaudeSetup: Claude Code updated \(before) → \(after)")
                Analytics.signal("Claude.updated", parameters: ["from": before, "to": after])
            }
        } catch {
            installed = ClaudeCLI.locateBinary() != nil
            installStatus = installed
                ? "✓ Claude Code present (update skipped: \((error as? LocalizedError)?.errorDescription ?? "\(error)"))"
                : "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.install, error, binaryFound: installed)
        }
        installing = false
    }

    /// Install with retries; flip `installGaveUp` when the budget is spent. The ONE retry policy
    /// (the frontier pickers drive this on the user's engine choice). No-op when already
    /// installed or installing.
    func ensureInstalled(attempts: Int = 3) async {
        guard !installed, !installing else { return }
        installGaveUp = false
        for attempt in 1...attempts {
            await installClaude()
            if installed { return }
            if attempt < attempts {
                Log("ClaudeSetup: install attempt \(attempt) failed — retrying in 10s")
                try? await Task.sleep(for: .seconds(10))
            }
        }
        installGaveUp = !installed
        if installGaveUp { Log("ClaudeSetup: install gave up after \(attempts) attempts — surfacing the manual-install panel") }
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
    /// 24 h, and only when a newer release actually exists (a tiny version-feed read). Rides the
    /// same idle tick as codex's updater (CodexSetup.startKeepingCurrent calls both).
    func updateIfDue(trigger: String) async {
        guard ModelBackend.current == .claude else { return }
        guard installed, !installing else { return }
        guard ClaudeCLI.usingManagedBinary else { return }   // brew/npm claude is the user's to update
        guard Self.sinceLastUpdateAttempt >= 86_400 else { return }
        Self.stampUpdateAttempt()
        let current = await ClaudeCLI.installedVersion()
        version = current
        let latest = await ClaudeCLI.latestReleasedVersion()
        if let current, let latest, !CodexCLI.isNewer(latest, than: current) {
            Log("ClaudeSetup: update (\(trigger)) — Claude Code \(current) is already the newest release")
            return
        }
        Log("ClaudeSetup: update (\(trigger)) — \(current ?? "?") → \(latest ?? "latest"), running the installer")
        await installClaude()
    }

    // MARK: Step 2 — auth (claude auth login)

    /// Is Claude Code logged in? Ground truth = `claude auth status` (via ClaudeAuth, which also
    /// caches the plan for the model choke point).
    private(set) var loggedIn = false
    /// The plan's display name ("Max", "Pro"…), refreshed with the login status.
    private(set) var plan: String?
    /// A login flow is in progress — the browser opened, awaiting the user to finish.
    private(set) var loggingIn = false
    /// Latest status line for step 2.
    private(set) var loginStatusLine: String?
    /// The running `claude auth login` process — kept so we can terminate it on restart/cleanup.
    private var loginProcess: Process?

    /// Re-check login + plan — call on appear, on foreground, and while a login is out.
    func refreshLoginStatus() async {
        let status = await ClaudeAuth.refresh()
        loggedIn = status.loggedIn
        plan = ClaudeAuth.planDisplayName
        if loggedIn { loggingIn = false }
    }

    /// Step 2a — start the interactive login. Spawns `claude auth login` (opens the browser) and
    /// flips into the awaiting-browser state; the panels notice the finished sign-in on their own.
    func startLogin(force: Bool = false) {
        guard installed else { loginStatusLine = "✗ Install Claude Code first"; return }
        if !force, loggedIn { loginStatusLine = "✓ Already signed in"; return }
        loginProcess?.terminate()
        loginProcess = nil
        do {
            // URLs elided from the stream: the flow prints the OAuth URL (PKCE/state params),
            // and every Log() line ships as a Release breadcrumb.
            loginProcess = try ClaudeCLI.startLogin { line in
                Log("[claude-signin] \(line.contains("://") ? "<url elided>" : line)")
            }
            loggingIn = true
            loginStatusLine = "A browser window opened; finish signing in there. Sentient notices on its own when you're done."
        } catch {
            loggingIn = false
            loginStatusLine = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.login, error)
        }
    }

    /// Stop a login attempt that's still out (tab switched away, restart) — the process is the
    /// localhost OAuth callback server; it self-exits after a finished sign-in anyway.
    func cancelLogin() {
        loginProcess?.terminate()
        loginProcess = nil
        loggingIn = false
    }

    // MARK: Diagnostics

    enum Step: String, Sendable { case install, login }

    /// Structure-only failure signal — error TYPE only, never the streamed installer/login lines.
    private func stepFailed(_ step: Step, _ error: Error, binaryFound: Bool? = nil) {
        var extra: [String: String] = [:]
        if let binaryFound { extra["binary_found"] = String(binaryFound) }
        CrashReporting.captureEvent("claude_setup.step_failed", level: .warning,
            tags: ["step": step.rawValue, "error": String(describing: type(of: error))],
            extra: extra, fingerprint: ["claude_setup", "step_failed", step.rawValue])
    }
}
