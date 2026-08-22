//
//  ClaudeAuth.swift
//  Sentient OS macOS
//
//  Claude plan identity, read from the user's own Claude Code login via `claude auth status`
//  (clean JSON: loggedIn / subscriptionType / email — no JWT spelunking, unlike CodexAuth).
//  Claude Code has NO free tier: a login exists only on a paid plan (Pro / Max / Team /
//  Enterprise), so the Claude engine's gate is binary — logged in or not — and there is no
//  knowledge-base-only preview branch. The one policy decision here: a Pro plan's Opus window
//  is tiny, so ClaudeCLI downshifts opus → sonnet when `isPro` (the terra-downshift twin).
//
//  Key methods:
//   - refresh()      → run `claude auth status`, parse, cache → the fresh Status
//   - cachedLoggedIn / cachedPlan / isPro → cheap synchronous reads for the model choke point
//   - destroy()      → clear the cache (FactoryReset / Uninstall)
//
//  Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md (the reference engine;
//  the Claude engine's own doc lands once the feature is tested and confirmed).
//

import Foundation

nonisolated enum ClaudeAuth {

    /// One `claude auth status` read: `{loggedIn, authMethod, email, orgName, subscriptionType}`.
    /// `plan` is the raw `subscriptionType` ("max", "pro", "team", "enterprise", …), lowercased.
    struct Status: Sendable, Equatable {
        let loggedIn: Bool
        let plan: String?
        let email: String?

        static let loggedOut = Status(loggedIn: false, plan: nil, email: nil)
    }

    // UserDefaults cache — written by refresh(), read synchronously by ClaudeCLI's model choke
    // point (a subprocess per model pick would be absurd). Production keys (the dbg.* law).
    static let loggedInKey = "claude.loggedIn"
    static let planKey = "claude.plan"

    static var cachedLoggedIn: Bool { UserDefaults.standard.bool(forKey: loggedInKey) }
    static var cachedPlan: String? {
        let v = UserDefaults.standard.string(forKey: planKey)
        return (v?.isEmpty == false) ? v : nil
    }

    /// The opus → sonnet downshift trigger: Pro's Opus allowance is a fraction of Max's, and a
    /// 3 AM vault build on Opus would burn the whole window. Unknown plans are NOT downshifted
    /// (fail open, the CodexAuth policy) — worst case is a usage-limit error every caller
    /// already survives with a resume handle.
    static var isPro: Bool { cachedPlan == "pro" }

    /// For UI ("Max", "Pro"…). Unknown strings just get capitalized.
    static var planDisplayName: String? {
        cachedPlan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// Ground truth: run `claude auth status` (exit 0 = logged in, 1 = not; JSON on stdout
    /// either way) and cache the verdict. Called from Settings/health refreshes and after a
    /// login — never per run (validate() caches availability the same way codex does).
    static func refresh() async -> Status {
        guard let bin = ClaudeCLI.locateBinary() else {
            cache(.loggedOut)
            return .loggedOut
        }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["auth", "status"],
                                                         stdinText: nil, cwd: nil, timeout: 20,
                                                         extraEnv: ClaudeCLI.baseEnv) else {
            // Couldn't even run the binary — keep the cache as-is (a transient spawn failure
            // must not flip a working setup to "logged out").
            return Status(loggedIn: cachedLoggedIn, plan: cachedPlan, email: nil)
        }
        let status = parse(out.stdout) ?? .loggedOut
        cache(status)
        return status
    }

    /// Parse the `auth status` JSON. Tolerant: only `loggedIn` is required.
    private static func parse(_ stdout: String) -> Status? {
        guard let data = stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        let plan = (obj["subscriptionType"] as? String)?.lowercased()
        return Status(loggedIn: loggedIn,
                      plan: (plan?.isEmpty == false) ? plan : nil,
                      email: obj["email"] as? String)
    }

    private static func cache(_ status: Status) {
        let d = UserDefaults.standard
        d.set(status.loggedIn, forKey: loggedInKey)
        if let plan = status.plan { d.set(plan, forKey: planKey) }
        else { d.removeObject(forKey: planKey) }
    }

    /// Wipe the cached identity (FactoryReset / Uninstall). The login itself belongs to the
    /// user's Claude Code (shared ~/.claude + Keychain) — never touched from here.
    static func destroy() {
        let d = UserDefaults.standard
        [loggedInKey, planKey, ClaudeCLI.rateLimitResetsAtKey,
         ClaudeCLI.rateLimitTypeKey].forEach { d.removeObject(forKey: $0) }
    }
}
