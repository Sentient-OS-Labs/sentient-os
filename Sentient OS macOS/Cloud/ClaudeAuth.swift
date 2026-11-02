//
//  ClaudeAuth.swift
//  Sentient OS macOS
//
//  Claude plan identity, read from the user's own Claude Code login via `claude auth status`
//  (clean JSON: loggedIn / subscriptionType / email — no JWT spelunking, unlike CodexAuth).
//  Claude Code has NO free tier: a login exists only on a paid plan (Pro / Max / Team /
//  Enterprise), so the Claude engine's gate is binary — logged in or not — and there is no
//  knowledge-base-only preview branch. Subscription plans share the same model policy.
//
//  Key methods:
//   - refresh()      → read local status without overriding a runtime rejection
//   - verifyLogin()  → confirm a repaired login with a tool-free request
//   - cachedLoggedIn / cachedPlan → cheap synchronous reads for login gating and plan display
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

    // Existing on-disk keys seed one in-memory snapshot. Runtime reads use that snapshot.
    static let loggedInKey = "claude.loggedIn"
    static let planKey = "claude.plan"
    static let accountIdentityKey = "claude.accountIdentity.v1"
    private static let legacyConnectorAccountKey = "claude.legacyConnectorAccount.v1"
    private static let readinessRevisionKey = "claude.readinessRevision.v1"
    static let changed = Notification.Name("ClaudeAuth.changed")

    struct ReadinessScope: Equatable, Sendable {
        let accountIdentity: String
        let revision: Int
    }
    static var cachedAccountIdentity: String? { readinessScope?.accountIdentity }
    static var legacyConnectorAccountIdentity: String? {
        state.withLock { current in
            current.legacyAccountIdentity?.isEmpty == false ? current.legacyAccountIdentity : nil
        }
    }
    static var readinessScope: ReadinessScope? {
        state.withLock { current in
            guard current.observedIdentity, !current.requiresVerification, current.loggedIn,
                  let value = current.accountIdentity,
                  !value.isEmpty else { return nil }
            return .init(accountIdentity: value, revision: current.readinessRevision)
        }
    }

    /// Explicit login can change the account before a status probe finishes. Retire its proof
    /// immediately; persisted source choices and knowledge remain intact.
    @MainActor static func beginAccountChange() {
        update { current in
            current.readinessRevision &+= 1
            current.accountIdentity = nil
            current.observedIdentity = false
            current.revision = UUID()
            // If no old account was observed yet, a deliberate new login must not adopt an
            // unidentified legacy connector cache for the account being signed into.
            if current.legacyAccountIdentity == nil { current.legacyAccountIdentity = "" }
            return true
        }
    }
    private static let repairKey = "claude.loginNeedsVerification"
    /// Synchronous readers only copy memory under this lock. Foundation notifications and
    /// SwiftUI can reenter them while the main actor publishes preferences.
    private struct AuthState: Sendable {
        var revision = UUID()
        var nextRefresh: UInt64 = 0
        var acceptedRefresh: UInt64 = 0
        var publication: UInt64 = 0
        var observedIdentity = false
        var loggedIn: Bool
        var requiresVerification: Bool
        var plan: String?
        var accountIdentity: String?
        var legacyAccountIdentity: String?
        var readinessRevision: Int

        init() {
            // The existing preference format also supports upgrades and process restarts.
            // Initialization reads it before the state lock exists.
            let d = UserDefaults.standard
            loggedIn = d.bool(forKey: loggedInKey)
            requiresVerification = d.bool(forKey: repairKey)
            plan = d.string(forKey: planKey)
            accountIdentity = d.string(forKey: accountIdentityKey)
            legacyAccountIdentity = d.string(forKey: legacyConnectorAccountKey)
            readinessRevision = d.integer(forKey: readinessRevisionKey)
        }

        var cachedStatus: Status {
            Status(loggedIn: loggedIn && !requiresVerification, plan: plan, email: nil)
        }
    }
    private static let state = OSAllocatedUnfairLock(initialState: AuthState())
    @MainActor private static var publishing = false

    /// All auth mutations are ordered by the main actor. Release the state lock before
    /// writing defaults, whose synchronous observers may read or update auth themselves.
    @MainActor @discardableResult
    private static func update(_ change: @Sendable (inout AuthState) -> Bool) -> Bool {
        let changed = state.withLock { current in
            guard change(&current) else { return false }
            current.publication &+= 1
            return true
        }
        if changed {
            publishLatest()
            // First observation after launch can change readiness while the saved values
            // stay identical. Notify consumers explicitly instead of rewriting preferences.
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        return changed
    }

    @MainActor private static func publishLatest() {
        guard !publishing else { return }
        publishing = true
        defer { publishing = false }
        while true {
            let snapshot = state.withLock { $0 }
            let d = UserDefaults.standard
            if d.integer(forKey: readinessRevisionKey) != snapshot.readinessRevision {
                d.set(snapshot.readinessRevision, forKey: readinessRevisionKey)
            }
            for (key, value) in [(accountIdentityKey, snapshot.accountIdentity),
                                 (legacyConnectorAccountKey, snapshot.legacyAccountIdentity),
                                 (planKey, snapshot.plan)] where d.string(forKey: key) != value {
                if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
            }
            for (key, value) in [(repairKey, snapshot.requiresVerification), (loggedInKey, snapshot.loggedIn)]
                where d.bool(forKey: key) != value {
                d.set(value, forKey: key)
            }
            // A synchronous observer may have performed a newer login/logout. Finish that
            // publication before returning, so the final disk cache matches the latest state.
            if state.withLock({ $0.publication == snapshot.publication }) { return }
        }
    }

    /// A locally present credential is not proof that Claude still accepts it. This latch
    /// survives relaunch and only a successful, tool-free model request can clear it.
    static var requiresVerification: Bool { state.withLock { $0.requiresVerification } }
    static var revision: UUID { state.withLock { $0.revision } }

    static func usableRevision() throws -> UUID {
        try state.withLock { current in
            guard !current.requiresVerification else { throw LoginRequired() }
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
    @MainActor static func rejected(_ error: Error, after revision: UUID) {
        guard error is LoginRequired, !Task.isCancelled else { return }
        let changed = update { current in
            guard current.revision == revision else { return false }
            current.revision = UUID()
            current.requiresVerification = true
            current.loggedIn = false
            return true
        }
        if changed { ClaudeSetup.shared.authenticationRejected() }
    }

    @discardableResult
    @MainActor static func beginLogin() -> UUID {
        let revision = UUID()
        update { current in
            current.revision = revision
            current.requiresVerification = true
            current.loggedIn = false
            return true
        }
        return revision
    }

    @MainActor static func cancelLogin(revision: UUID) {
        state.withLock { current in if current.revision == revision { current.revision = UUID() } }
    }

    static var cachedLoggedIn: Bool {
        state.withLock { $0.cachedStatus.loggedIn }
    }
    static var cachedPlan: String? {
        let v = state.withLock { $0.plan }
        return (v?.isEmpty == false) ? v : nil
    }

    /// For UI ("Max", "Pro"…). Unknown strings just get capitalized.
    static var planDisplayName: String? {
        cachedPlan.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// Read the local Claude Code login and plan. A runtime rejection remains authoritative
    /// until verifyLogin succeeds, even if this command reports loggedIn: true.
    static func refresh() async -> Status {
        let (revision, request) = state.withLock { current in
            current.nextRefresh &+= 1
            return (current.revision, current.nextRefresh)
        }
        guard let bin = ClaudeCLI.locateBinary() else {
            return state.withLock { $0.cachedStatus }
        }
        guard let out = try? await CodexCLI.executeAsync(binary: bin, args: ["auth", "status"],
                                                         stdinText: nil, cwd: nil, timeout: 20,
                                                         extraEnv: ClaudeCLI.baseEnv,
                                                         includeCustomProviderKey: false) else {
            // Couldn't even run the binary — keep the cache as-is (a transient spawn failure
            // must not flip a working setup to "logged out").
            return state.withLock { $0.cachedStatus }
        }
        guard !Task.isCancelled, let status = parse(out.stdout) else { return state.withLock { $0.cachedStatus } }
        return await acceptStatus(status, after: revision, request: request)
    }

    @MainActor private static func acceptStatus(_ status: Status, after revision: UUID, request: UInt64) -> Status {
        let accepted = update { current in
            // A failed/unknown newer probe cannot discard useful status from an older one.
            // A newer accepted status or explicit account change does supersede that result.
            guard !Task.isCancelled, current.revision == revision, request >= current.acceptedRefresh else { return false }
            current.acceptedRefresh = request
            let identity = status.accountIdentity
            current.observedIdentity = true
            if current.accountIdentity != identity { current.readinessRevision &+= 1 }
            current.accountIdentity = identity
            if let identity, current.legacyAccountIdentity == nil { current.legacyAccountIdentity = identity }
            current.loggedIn = status.loggedIn && !current.requiresVerification
            current.plan = status.plan
            return true
        }
        return state.withLock { current in
            guard accepted, current.revision == revision, current.acceptedRefresh == request else { return current.cachedStatus }
            return Status(loggedIn: current.cachedStatus.loggedIn, plan: current.plan,
                          email: status.email, organizationID: status.organizationID)
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
        let verifiedRevision = UUID()
        let accepted = await MainActor.run {
            update { current in
                guard !Task.isCancelled, current.revision == revision else { return false }
                current.requiresVerification = false
                current.loggedIn = true
                current.revision = verifiedRevision
                return true
            }
        }
        guard accepted, self.revision == verifiedRevision else { throw CancellationError() }
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

    /// Wipe the cached identity (FactoryReset / Uninstall). The login itself belongs to the
    /// user's Claude Code (shared ~/.claude + Keychain) — never touched from here.
    @MainActor static func destroy() {
        for key in [ClaudeCLI.rateLimitResetsAtKey, ClaudeCLI.rateLimitTypeKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        update { current in
            current.revision = UUID()
            current.observedIdentity = false
            current.readinessRevision &+= 1
            current.loggedIn = false
            current.requiresVerification = false
            current.plan = nil
            current.accountIdentity = nil
            current.legacyAccountIdentity = nil
            return true
        }
    }
}
