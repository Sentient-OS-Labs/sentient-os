#!/usr/bin/env python3
"""Compile production hosted Claude isolation and backend capabilities with inert run credentials.
No real account, Keychain, provider API or app-support directory is accessed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'
model = (APP / 'Cloud/ModelBackend.swift').read_text()
model = 'import Foundation\n' + model[model.index('nonisolated enum ModelBackend:'):model.index('/// The saved custom endpoint.')]
runtime = (APP / 'Cloud/HostedClaudeRuntime.swift').read_text()
fixture = r'''
import Foundation
extension URL {
    static var sentientSupport: URL { fatalError("Tests must provide a temporary profile explicitly") }
}
nonisolated enum HostedInference {
    struct Run: Sendable { let model: String; let token: String; let gatewayURL: URL; var maximumOutputTokens = 8_192 }
    @TaskLocal static var currentRun: Run?
}
@main struct Test {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-claude-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("private-profile")
        let model = "claude-sonnet-5-5"
        let gateway = URL(string: "https://gateway.example.invalid/anthropic")!
        let token = "synthetic-run-capability"
        let env = try HostedClaudeRuntime.environment(gatewayURL: gateway, token: token, model: model, profile: profile)
        check(env["ANTHROPIC_API_KEY"] == token && env["ANTHROPIC_AUTH_TOKEN"] == "", "bare API auth contains only the scoped gateway token")
        check(env["ANTHROPIC_BASE_URL"] == gateway.absoluteString, "base URL is explicit")
        check(env["CLAUDE_CODE_OAUTH_TOKEN"] == "", "subscription OAuth is disabled")
        check(env["CLAUDE_CONFIG_DIR"] == profile.path, "profile is isolated")
        check(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "8192", "default output bound is explicit")
        let bounded = try HostedClaudeRuntime.environment(gatewayURL: gateway, token: token, model: model, profile: profile, maxOutputTokens: 4096)
        check(bounded["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "4096", "server output bound wins")
        check(rejects { _ = try HostedClaudeRuntime.environment(gatewayURL: gateway, token: token, model: model, profile: profile, maxOutputTokens: 0) }, "invalid output bound rejected")
        for key in ["ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"] {
            check(env[key] == model, "implicit model calls stay on the admitted model")
        }
        for key in ["DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] {
            check(env[key] == "1", "nonessential network traffic is disabled")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: profile.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "private profile permissions")
        check(try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty, "no credentials written to disk")
        check(!env.keys.contains("CODEX_HOME") && !env.keys.contains("SENTIENT_MODEL_API_KEY"), "does not borrow another provider's credentials")
        for invalid in ["http://gateway.example.invalid", "https://user:pass@gateway.example.invalid", "https://gateway.example.invalid/?secret=x", "https://gateway.example.invalid/#fragment"] {
            check(rejects { _ = try HostedClaudeRuntime.environment(gatewayURL: URL(string: invalid)!, token: token, model: model, profile: profile) }, "unsafe gateway URL rejected")
        }
        for invalid in ["", "x\ny", String(repeating: "x", count: 16_385)] {
            check(rejects { _ = try HostedClaudeRuntime.environment(gatewayURL: gateway, token: invalid, model: model, profile: profile) }, "invalid credential rejected")
        }
        for invalid in ["", "claude;other", "claude\nsonnet", String(repeating: "x", count: 129)] {
            check(!HostedClaudeRuntime.validModel(invalid), "invalid model rejected")
        }
        let local = try HostedClaudeRuntime.environment(gatewayURL: URL(string: "http://127.0.0.1:8080/anthropic")!, token: token, model: model, profile: profile)
        check(local["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:8080/anthropic", "loopback supports a local gateway fixture")
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        check(rejects { _ = try HostedClaudeRuntime.environment(gatewayURL: gateway, token: token, model: model, profile: file) }, "regular file cannot replace profile")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: profile)
        check(rejects { _ = try HostedClaudeRuntime.environment(gatewayURL: gateway, token: token, model: model, profile: link) }, "profile symlink rejected")
        check(rejects { _ = try HostedClaudeRuntime.model() }, "inference requires an admitted run")
        let run = HostedInference.Run(model: model, token: token, gatewayURL: gateway)
        let chosen = try HostedInference.$currentRun.withValue(run) { try HostedClaudeRuntime.model() }
        check(chosen == model, "server model wins over subscription and speed preferences")
        check(ModelBackend.sentient.hasClaudeRuntime && ModelBackend.claude.hasClaudeRuntime, "funding choices share the Claude runtime")
        check(!ModelBackend.sentient.hasSubscriptionConnectors && !ModelBackend.custom.hasSubscriptionConnectors, "hosted mode cannot borrow subscription accounts")
        check(ModelBackend.chatgpt.hasSubscriptionConnectors && ModelBackend.claude.hasSubscriptionConnectors, "existing account capabilities preserved")
        await ModelBackend.$runOverride.withValue(.sentient) {
            check(ModelBackend.current == .sentient && ModelBackend.hasClaudeRuntime && !ModelBackend.connectorsAvailable, "task-local hosted selection controls capabilities")
            await Task.yield()
            check(ModelBackend.current == .sentient, "selection survives suspension")
        }
        print("\(checks) hosted Claude isolation checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-hosted-claude-test-') as directory:
    directory = Path(directory)
    paths = []
    for name, content in [('ModelBackend.swift', model), ('HostedClaudeRuntime.swift', runtime), ('Fixture.swift', fixture)]:
        path = directory / name
        path.write_text(content)
        paths.append(str(path))
    binary = directory / 'fixture'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', *paths, '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
