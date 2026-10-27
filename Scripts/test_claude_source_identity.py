#!/usr/bin/env python3
"""Exercise production Claude identity cache using inert auth-status replies and memory prefs.
No real authentication, CLI, model, network, keychain, account or TCC access occurs.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
source = (APP / 'Cloud/ClaudeAuth.swift').read_text()
registry = (APP / 'Cloud/ConnectorRegistry.swift').read_text()
def member(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
source += '\nenum ConnectorRegistry {\n' + '\n'.join(member(registry, signature) for signature in
    ['static func readOrigin(', 'static func readGenerationKey(']) + '\n}\n'
fixture = r'''
import Foundation
enum ModelBackend: String { case chatgpt, claude, custom }
enum CodexRuntime { static let sessionScope = "fixture", accountIdentity: String? = "codex-fixture" }
enum DirectMCPStore {
    struct Connection { let id: String; let generation: Int }
    static func connection(_ slug: String) -> Connection? { nil }
}
final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
    func bool(forKey key: String) -> Bool { lock.withLock { values[key] as? Bool ?? false } }
    func integer(forKey key: String) -> Int { lock.withLock { values[key] as? Int ?? 0 } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func removeObject(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
    var strings: [String] { lock.withLock { values.values.compactMap { $0 as? String } } }
}
enum ClaudeCLI {
    static func locateBinary() -> String? { "inert-claude" }
    static let baseEnv: [String: String] = [:]
    static let rateLimitResetsAtKey = "limit", rateLimitTypeKey = "limit-type"
}
enum CodexCLI {
    struct Output: Sendable { let stdout: String }
    static func executeAsync(binary: String, args: [String], stdinText: String?, cwd: String?,
                             timeout: Double, extraEnv: [String: String]) async throws -> Output {
        precondition(binary == "inert-claude" && args == ["auth", "status"])
        return try await NativeStatus.shared.read()
    }
}
actor NativeStatus {
    static let shared = NativeStatus()
    var text = ""
    var fail = false
    var blocked = false
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    enum Failure: Error { case unavailable }
    func configure(_ text: String, fail: Bool = false, blocked: Bool = false) {
        self.text = text; self.fail = fail; self.blocked = blocked; entered = false
    }
    func read() async throws -> CodexCLI.Output {
        let result = text, shouldFail = fail
        if blocked {
            entered = true
            await withCheckedContinuation { waiter = $0 }
        }
        if shouldFail { throw Failure.unavailable }
        return .init(stdout: result)
    }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
}
@main struct Test {
    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1; print("PASS " + name)
        }
        let a = #"{"loggedIn":true,"email":"Alice@EXAMPLE.invalid","orgId":"org-a","subscriptionType":"PRO"}"#
        let normalizedA = #"{"loggedIn":true,"email":" alice@example.invalid ","orgId":"org-a","subscriptionType":"pro"}"#
        let b = #"{"loggedIn":true,"email":"bob@example.invalid","orgId":"org-b","subscriptionType":"max"}"#
        UserDefaults.standard.set(true, forKey: ClaudeAuth.loggedInKey)
        UserDefaults.standard.set("old-process-proof", forKey: ClaudeAuth.accountIdentityKey)
        check(ClaudeAuth.readinessScope == nil, "persisted identity cannot prove readiness before this process observes auth")
        await NativeStatus.shared.configure(a)
        let first = await ClaudeAuth.refresh()
        let scopeA = ClaudeAuth.readinessScope!
        let originA = ConnectorRegistry.readOrigin(slug: "gmail", backend: .claude)
        check(first.accountIdentity == scopeA.accountIdentity && scopeA.accountIdentity.count == 64,
              "native status produces a local account fingerprint")
        check(ClaudeAuth.legacyConnectorAccountIdentity == scopeA.accountIdentity,
              "first observed account owns existing unmarked connector records")
        check(!UserDefaults.standard.strings.contains { $0.localizedCaseInsensitiveContains("alice") || $0.contains("org-a") },
              "raw email and organization are not persisted")
        await NativeStatus.shared.configure(normalizedA)
        _ = await ClaudeAuth.refresh()
        check(ClaudeAuth.readinessScope == scopeA, "normalization and harmless auth refresh preserve account scope")
        await NativeStatus.shared.configure("", fail: true)
        let failed = await ClaudeAuth.refresh()
        check(failed.accountIdentity == nil && ClaudeAuth.readinessScope == scopeA,
              "failed status cannot certify a new proof or erase the last known working account")
        ClaudeAuth.beginAccountChange()
        check(ClaudeAuth.readinessScope == nil, "explicit login invalidates proof before auth changes")
        await NativeStatus.shared.configure(a)
        _ = await ClaudeAuth.refresh()
        check(ClaudeAuth.readinessScope?.accountIdentity == scopeA.accountIdentity && ClaudeAuth.readinessScope != scopeA,
              "same-account relogin changes the in-flight proof revision")
        await NativeStatus.shared.configure(a, blocked: true)
        let obsolete = Task { await ClaudeAuth.refresh() }
        while !(await NativeStatus.shared.entered) { await Task.yield() }
        ClaudeAuth.beginAccountChange()
        await NativeStatus.shared.configure(b)
        _ = await ClaudeAuth.refresh()
        let scopeB = ClaudeAuth.readinessScope!
        check(ConnectorRegistry.readOrigin(slug: "gmail", backend: .claude) != originA,
              "Claude account changes invalidate source checkpoints and writing-style origins")
        await NativeStatus.shared.release()
        _ = await obsolete.value
        check(ClaudeAuth.readinessScope == scopeB && scopeB.accountIdentity != scopeA.accountIdentity,
              "old delayed auth result cannot restore account A after login to B")
        check(ClaudeAuth.legacyConnectorAccountIdentity == scopeA.accountIdentity,
              "switching accounts never transfers legacy connector ownership")
        await NativeStatus.shared.configure(#"{"loggedIn":true,"email":"bob@example.invalid","orgId":"another-org"}"#)
        _ = await ClaudeAuth.refresh()
        check(ClaudeAuth.cachedAccountIdentity != scopeB.accountIdentity,
              "organization changes invalidate the connector account scope")
        await NativeStatus.shared.configure(#"{"loggedIn":true,"subscriptionType":"pro"}"#)
        _ = await ClaudeAuth.refresh()
        check(ClaudeAuth.cachedLoggedIn && ClaudeAuth.readinessScope == nil,
              "missing account identity cannot certify connectors despite a logged-in plan")
        ClaudeAuth.destroy()
        check(ClaudeAuth.readinessScope == nil && ClaudeAuth.legacyConnectorAccountIdentity == nil,
              "teardown clears only local account proof state")
        ClaudeAuth.beginAccountChange()
        await NativeStatus.shared.configure(b)
        _ = await ClaudeAuth.refresh()
        check(ClaudeAuth.legacyConnectorAccountIdentity == nil,
              "a deliberate login before observing the old account cannot adopt unknown legacy connectors")
        print("Claude source identity: \(checks) checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-claude-identity-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(source + '\n' + fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True, timeout=20)
