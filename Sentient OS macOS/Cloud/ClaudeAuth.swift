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
//   - refresh()      → read local status without overriding a runtime rejection
//   - verifyLogin()  → confirm a repaired login with a tool-free request
//   - cachedLoggedIn / cachedPlan / isPro → cheap synchronous reads for the model choke point
//   - destroy()      → clear the cache (FactoryReset / Uninstall)
//
//  Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md (the reference engine;
//  the Claude engine's own doc lands once the feature is tested and confirmed).
//

import Foundation
import CryptoKit
import os

nonisolated enum ClaudeAuth {

    /// One `claude auth status` read: `{loggedIn, authMethod, email, orgName, subscriptionType}`.
    /// `plan` is the raw `subscriptionType` ("max", "pro", "team", "enterprise", …), lowercased.
    struct Status: Sendable, Equatable {
        let loggedIn: Bool
        let plan: String?
        let email: String?
        var organizationID: String? = nil

        /// Local-only fingerprint. The email and organization returned by auth status are
        /// never persisted in connector state or diagnostics.
        var accountIdentity: String? {
            guard loggedIn, let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !email.isEmpty else { return nil }
            let organization = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let identity = "v1:\(email.utf8.count):\(email):\(organization)"
            return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        static let loggedOut = Status(loggedIn: false, plan: nil, email: nil)
    }

    // UserDefaults cache — written by refresh(), read synchronously by ClaudeCLI's model choke
    // point (a subprocess per model pick would be absurd). Production keys (the dbg.* law).
    static let loggedInKey = "claude.loggedIn"
    static let planKey = "claude.plan"
    static let accountIdentityKey = "claude.accountIdentity.v1"
    private static let legacyConnectorAccountKey = "claude.legacyConnectorAccount.v1"
    private static let readinessRevisionKey = "claude.readinessRevision.v1"

    struct ReadinessScope: Equatable, Sendable {
        let accountIdentity: String
        let revision: Int
    }
    static var cachedAccountIdentity: String? { readinessScope?.accountIdentity }
    static var legacyConnectorAccountIdentity: String? {
        state.withLock { _ in
            let value = UserDefaults.standard.string(forKey: legacyConnectorAccountKey)
            return value?.isEmpty == false ? value : nil
        }
    }
    static var readinessScope: ReadinessScope? {
        state.withLock { current in
            guard current.observedIdentity, !UserDefaults.standard.bool(forKey: repairKey),
                  UserDefaults.standard.bool(forKey: loggedInKey),
                  let value = UserDefaults.standard.string(forKey: accountIdentityKey),
                  !value.isEmpty else { return nil }
            return .init(accountIdentity: value,
                revision: UserDefaults.standard.integer(forKey: readinessRevisionKey))
        }
    }

    /// Explicit login can change the account before a status probe finishes. Retire its proof
    /// immediately; persisted source choices and knowledge remain intact.
    static func beginAccountChange() {
        state.withLock { current in
            let d = UserDefaults.standard
            d.set(d.integer(forKey: readinessRevisionKey) &+ 1, forKey: readinessRevisionKey)
            d.removeObject(forKey: accountIdentityKey)
            current.observedIdentity = false
            current.revision = UUID()
            // If no old account was observed yet, a deliberate new login must not adopt an
            // unidentified legacy connector cache for the account being signed into.
            if d.object(forKey: legacyConnectorAccountKey) == nil {
                d.set("", forKey: legacyConnectorAccountKey)
            }
        }
    }
    private static let repairKey = "claude.loginNeedsVerification"
    // One lock keeps authentication and account ownership consistent without nested locks.
    private struct AuthState {
        var revision = UUID()
        var observedIdentity = false
    }
    private static let state = OSAllocatedUnfairLock(initialState: AuthState())

    /// A locally present credential is not proof that Claude still accepts it. This latch
    /// survives relaunch and only a successful, tool-free model request can clear it.
    static var requiresVerification: Bool { state.withLock { _ in UserDefaults.standard.bool(forKey: repairKey) } }
    static var revision: UUID { state.withLock { $0.revision } }

    static func usableRevision() throws -> UUID {
        try state.withLock { current in
            guard !UserDefaults.standard.bool(forKey: repairKey) else { throw LoginRequired() }
            return current.revision
        }
    }

    struct LoginRequired: LocalizedError, Sendable {
        var reason: CodexFailureReason = .notLoggedIn
        var errorDescription: String? {
            "Your Claude Code sign-in needs to be renewed. Sign in to Claude again; your analysis progress is saved."
        }
    }

    /// Match Claude CLI's fatal diagnostics, not a bare 401 or a tool's OAuth error.
    /// The caller must additionally establish that this is an unsuccessful CLI result.
    static func authenticationFailure(_ detail: String) -> LoginRequired? {
        var text = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["failed to authenticate. ", "failed to authenticate: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text == "not logged in" || (text.hasPrefix("not logged in") && text.contains("/login"))
            || text.hasPrefix("please run /login") {
            return LoginRequired()
        }
        let apiRejection = text.hasPrefix("api error: 401")
        let refreshRejection = text.hasPrefix("oauth token refresh failed")
            && (text.contains("invalid_grant") || text.contains("revoked") || text.contains("expired"))
        guard (apiRejection && (text.contains("oauth") || text.contains("authentication_error")))
                || refreshRejection else { return nil }
        if refreshRejection { return LoginRequired(reason: .refreshFailed) }
        return LoginRequired(reason: text.contains("expired") ? .tokenExpired : .notLoggedIn)
    }

    /// Called only for Claude's own terminal authentication error, never connector output.
    /// An older request finishing after a repaired login cannot invalidate the new identity.
    static func rejected(_ error: Error, after revision: UUID) {
        guard error is LoginRequired, !Task.isCancelled else { return }
        let changed = state.withLock { current in
            guard current.revision == revision else { return false }
            current.revision = UUID()
            UserDefaults.standard.set(true, forKey: repairKey)
            UserDefaults.standard.set(false, forKey: loggedInKey)
            return true
        }
        if changed { Task { @MainActor in ClaudeSetup.shared.authenticationRejected() } }
    }

    @discardableResult
    static func beginLogin() -> UUID {
        state.withLock { current in
            current.revision = UUID()
            UserDefaults.standard.set(true, forKey: repairKey)
            UserDefaults.standard.set(false, forKey: loggedInKey)
            return current.revision
        }
    }

    static func cancelLogin(revision: UUID) {
        state.withLock { current in if current.revision == revision { current.revision = UUID() } }
    }

    static var cachedLoggedIn: Bool {
        state.withLock { _ in
            !UserDefaults.standard.bool(forKey: repairKey) && UserDefaults.standard.bool(forKey: loggedInKey)
        }
    }
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

    /// Read the local Claude Code login and plan. A runtime rejection remains authoritative
    /// until verifyLogin succeeds, even if this command reports loggedIn: true.
    static func refresh() async -> Status {
        let snapshot = state.withLock { ($0.revision, UserDefaults.standard.integer(forKey: readinessRevisionKey)) }
        guard let bin = ClaudeCLI.locateBinary() else {
            return acceptStatus(.loggedOut, after: snapshot.0, readinessRevision: snapshot.1)
        }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["auth", "status"],
                                                         stdinText: nil, cwd: nil, timeout: 20,
                                                         extraEnv: ClaudeCLI.baseEnv,
                                                         includeCustomProviderKey: false) else {
            // Couldn't even run the binary — keep the cache as-is (a transient spawn failure
            // must not flip a working setup to "logged out").
            return Status(loggedIn: cachedLoggedIn, plan: cachedPlan, email: nil)
        }
        guard !Task.isCancelled else { return Status(loggedIn: cachedLoggedIn, plan: cachedPlan, email: nil) }
        let status = parse(out.stdout) ?? .loggedOut
        return acceptStatus(status, after: snapshot.0, readinessRevision: snapshot.1)
    }

    private static func acceptStatus(_ status: Status, after revision: UUID, readinessRevision: Int) -> Status {
        state.withLock { current in
            let d = UserDefaults.standard
            guard current.revision == revision, d.integer(forKey: readinessRevisionKey) == readinessRevision else {
                return Status(loggedIn: !d.bool(forKey: repairKey) && d.bool(forKey: loggedInKey),
                              plan: d.string(forKey: planKey), email: nil)
            }
            let effective = Status(loggedIn: status.loggedIn && !d.bool(forKey: repairKey),
                                   plan: status.plan, email: status.email, organizationID: status.organizationID)
            cacheLocked(status, loggedIn: effective.loggedIn, state: &current)
            return effective
        }
    }

    /// Verify the subscription with a bounded request containing no user data, tools,
    /// connectors, hooks, or saved session. Status alone can still report a rejected token.
    static func verifyLogin(revision: UUID) async throws {
        guard self.revision == revision else { throw CancellationError() }
        guard let bin = ClaudeCLI.locateBinary() else { throw CodexCLI.CLIError.notAvailable(.notInstalled) }
        _ = await refresh() // refresh the plan; this cannot clear the verification latch
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-claude-login-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = try await CodexCLI.executeAsync(binary: bin,
            args: ["-p", "--model", ClaudeCLI.Model.sonnet.rawValue, "--effort", "low",
                   "--output-format", "stream-json", "--verbose",
                   "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                   "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
                   "--settings", "{\"disableAllHooks\":true,\"claudeMdExcludes\":[\"**\"]}",
                   "--permission-mode", "dontAsk", "--max-turns", "1",
                   "--system-prompt", "Reply with OK."],
            stdinText: "Reply with OK.", cwd: directory.path, timeout: 45,
            extraEnv: ClaudeCLI.baseEnv.merging(["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                                                "CLAUDE_CODE_SAFE_MODE": "1"]) { _, new in new },
            includeCustomProviderKey: false)
        _ = try ClaudeCLI.parseEnvelope(out, durationMS: 0)
        try Task.checkCancellation()
        let accepted = state.withLock { current in
            guard current.revision == revision else { return false }
            UserDefaults.standard.set(false, forKey: repairKey)
            UserDefaults.standard.set(true, forKey: loggedInKey)
            current.revision = UUID()
            return true
        }
        guard accepted else { throw CancellationError() }
    }

    /// Parse the `auth status` JSON. Tolerant: only `loggedIn` is required.
    private static func parse(_ stdout: String) -> Status? {
        guard let data = stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        let plan = (obj["subscriptionType"] as? String)?.lowercased()
        return Status(loggedIn: loggedIn,
                      plan: (plan?.isEmpty == false) ? plan : nil,
                      email: obj["email"] as? String,
                      organizationID: obj["orgId"] as? String)
    }

    /// The caller holds state, so identity, login and plan are committed as one snapshot.
    /// A local credential can identify the account while runtime verification remains pending.
    private static func cacheLocked(_ status: Status, loggedIn: Bool, state: inout AuthState) {
        let d = UserDefaults.standard
        state.observedIdentity = true
        let identity = status.accountIdentity
        if d.string(forKey: accountIdentityKey) != identity {
            d.set(d.integer(forKey: readinessRevisionKey) &+ 1, forKey: readinessRevisionKey)
        }
        if let identity { d.set(identity, forKey: accountIdentityKey) }
        else { d.removeObject(forKey: accountIdentityKey) }
        if let identity, d.object(forKey: legacyConnectorAccountKey) == nil {
            d.set(identity, forKey: legacyConnectorAccountKey)
        }
        d.set(loggedIn, forKey: loggedInKey)
        if let plan = status.plan { d.set(plan, forKey: planKey) }
        else { d.removeObject(forKey: planKey) }
    }

    /// Wipe the cached identity (FactoryReset / Uninstall). The login itself belongs to the
    /// user's Claude Code (shared ~/.claude + Keychain) — never touched from here.
    static func destroy() {
        state.withLock { current in
            current.revision = UUID()
            current.observedIdentity = false
            let d = UserDefaults.standard
            d.set(d.integer(forKey: readinessRevisionKey) &+ 1, forKey: readinessRevisionKey)
            [loggedInKey, planKey, repairKey, accountIdentityKey, legacyConnectorAccountKey,
             ClaudeCLI.rateLimitResetsAtKey, ClaudeCLI.rateLimitTypeKey].forEach { d.removeObject(forKey: $0) }
        }
    }
}
