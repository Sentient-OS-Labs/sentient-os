//
//  CodexSetup.swift
//  Sentient OS macOS
//
//  The unified Codex SETUP engine — the SINGLE code path that onboarding AND the dev tools both
//  drive, so there's never a second, divergent copy. Getting Codex computer use working on the
//  user's Mac is three steps:
//    1. INSTALL       — drop the Codex CLI binary on disk.
//    2. AUTH          — `codex login` with the user's OpenAI account.
//    3. COMPUTER USE  — patch ~/.codex so computer use works via the CLI (ComputerUseSetup).
//  Observable + a shared instance, so both UIs render the same live status off one source of truth.
//  The actual binary install runs through CodexCLI (its Process plumbing); the computer-use
//  bootstrap runs through ComputerUseSetup; this file owns the flow.
//
//  Key methods:
//   - refreshInstalled()   → re-detect whether the codex binary is present
//   - installCodex()       → step 1: run OpenAI's installer (detection-first; streams progress)
//   - startLogin/confirmLogin → step 2: interactive `codex login` (browser) + confirm
//   - setupComputerUse()   → step 3: bootstrap computer use from OpenAI's DMG (streams progress)
//   - whatsNeeded()        → fresh check of all three; returns the pending steps (smart-flow driver)
//
//  Doc: Documentation/Codex Setup Handoff (Onboarding).md  ·  step 3 deep-dive:
//       Documentation/Computer-Use Bootstrap (Codex Reverse-Engineering).md
//

import Foundation

@MainActor
@Observable
final class CodexSetup {

    /// One shared instance so onboarding and the dev tools observe the same setup state.
    static let shared = CodexSetup()

    private init() {}

    // MARK: Step 1 — install

    /// Is the Codex CLI binary present on disk? (NOT whether it's logged in — that's step 2.)
    private(set) var installed: Bool = CodexCLI.locateBinary() != nil
    /// An install is currently running (drives the spinner + disables the button).
    private(set) var installing = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var installStatus: String?

    /// Cheap re-detect of step 1's status — call on appear and after an install.
    func refreshInstalled() { installed = CodexCLI.locateBinary() != nil }

    /// Step 1 — install the Codex CLI via OpenAI's official installer. Detection-first: a no-op if
    /// codex is already present. Streams the installer's output into `installStatus` (and the
    /// console). Both onboarding and the dev button call THIS — no duplicated logic.
    func installCodex() async {
        guard !installing else { return }
        if CodexCLI.locateBinary() != nil {
            installed = true
            installStatus = "✓ Codex CLI already installed"
            return
        }
        installing = true
        installStatus = "Installing Codex CLI…"
        do {
            try await CodexCLI.install { [weak self] line in
                Log("[codex-install] \(line)")
                Task { @MainActor in self?.installStatus = line }
            }
            installed = true
            installStatus = "✓ Codex CLI installed"
        } catch {
            installed = CodexCLI.locateBinary() != nil
            installStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.install, error, binaryFound: installed)   // "installer ran, binary missing" if false
        }
        installing = false
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
        guard installed else { loginStatusLine = "✗ Install Codex first (step 1)"; return }
        if !force, loggedIn { loginStatusLine = "✓ Already logged in"; return }   // self-guard; "Log in again" passes force
        loginProcess?.terminate()          // kill any stale attempt before re-opening
        loginProcess = nil
        do {
            loginProcess = try CodexCLI.startLogin { line in Log("[codex-login] \(line)") }
            loggingIn = true
            loginStatusLine = "A browser window opened; finish signing in, then tap “Finished logging into codex”."
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

    // MARK: Step 3 — computer use

    /// Is computer use bootstrapped into ~/.codex? (the plugin + native helper are on disk)
    private(set) var computerUseReady = ComputerUseSetup.isInstalled
    /// A computer-use setup is running (drives the spinner + disables the button).
    private(set) var settingUpComputerUse = false
    /// Latest streamed progress line, or the final ✓/✗ result.
    private(set) var computerUseStatus: String?

    /// Cheap re-detect of step 3's status — call on appear and after a setup.
    func refreshComputerUse() { computerUseReady = ComputerUseSetup.isInstalled }

    /// Step 3 — make computer use work on the plain Codex CLI (no desktop app). Detection-first:
    /// a no-op if already set up. Downloads OpenAI's official Codex.dmg, lifts out the bundled
    /// computer-use payload, lays it into ~/.codex, and patches config.toml — streaming progress.
    /// Both onboarding and the dev button call THIS — no duplicated logic.
    func setupComputerUse(force: Bool = false) async {
        guard !settingUpComputerUse else { return }
        if !force, ComputerUseSetup.isInstalled {
            computerUseReady = true
            computerUseStatus = "✓ Computer use already set up"
            return
        }
        guard installed else { computerUseStatus = "✗ Install Codex first (step 1)"; return }
        settingUpComputerUse = true
        computerUseStatus = force ? "Re-installing…" : "Starting…"
        do {
            try await ComputerUseSetup.install(force: force) { [weak self] line in
                Log("[codex-cu] \(line)")
                Task { @MainActor in self?.computerUseStatus = line }
            }
            computerUseReady = true
            computerUseStatus = "✓ Computer use ready"
        } catch {
            computerUseReady = ComputerUseSetup.isInstalled
            computerUseStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            stepFailed(.computerUse, error)
        }
        settingUpComputerUse = false
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
    /// `codex login status`, and re-checks the computer-use bootstrap — then returns the steps
    /// still PENDING, in order. A smart onboarding calls this to decide what to render/run; a dumb
    /// "just run all three in order" driver can ignore it because every action (installCodex /
    /// startLogin / setupComputerUse) already self-guards and no-ops when its step is done.
    func whatsNeeded() async -> [Step] {
        refreshInstalled()
        await refreshLoginStatus()
        refreshComputerUse()
        var pending: [Step] = []
        if !installed        { pending.append(.install) }
        if !loggedIn         { pending.append(.login) }
        if !computerUseReady { pending.append(.computerUse) }
        return pending
    }
}
