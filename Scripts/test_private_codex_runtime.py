#!/usr/bin/env python3
"""Run real private-runtime/install/auth/process code against synthetic local packages.

Compiles complete CodexRuntime and CodexRuntimeInstall plus exact CLI discovery,
probe, process, and auth-read/write methods. Only app support resolution, custom
provider data, watchdog/UI hooks, and native helper validation are inert fixtures.
No browser login, model prompts, real credentials, preferences or network calls.
Every fixture tree and binary is removed when this script ends.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tarfile
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'


def declaration(source, signature):
    start = source.index(signature)
    depth = 0
    for opening in range(start, len(source)):
        depth += (source[opening] == '(') - (source[opening] == ')')
        if source[opening] == '{' and depth == 0:
            break
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


cli = (APP / 'Cloud/CodexCLI.swift').read_text()
auth = (APP / 'Cloud/CodexAuth.swift').read_text()
diagnostics = (APP / 'Cloud/CodexDiagnostics.swift').read_text()
production = 'nonisolated enum CodexCLI { enum CLIError: Error { case launchFailed(String), timedOut(after: TimeInterval) }\n' + '\n'.join(declaration(cli, name) for name in [
    'static var managedBinaryPath:', 'static func locateBinary(', 'static func isRunnable(',
    'static func loginStatus(', 'static func installedVersion(', 'static func approvedVersion(',
    'struct ExecResult:', 'private final class PipeDrain:', 'private final class ProcHolder:',
    'static func executeAsync(', 'private static func execute(',
]) + '\n}\n'
production += 'nonisolated enum CodexAuth {\n' + '\n'.join(declaration(auth, name) for name in [
    'enum Tier:', 'struct Plan:', 'private nonisolated static var authURL:',
    'nonisolated static func currentPlan(', 'private nonisolated static func planClaim(',
    'private static func writeBack(',
]).replace('private static func writeBack(', 'static func writeBack(', 1) + '\n}\n'
production += declaration(diagnostics, 'nonisolated struct CodexAuthSnapshot:')

FIXTURE = r'''
import Foundation
import Darwin
import os
extension URL {
    static var sentientSupport: URL { Fixture.base.appendingPathComponent("Support") }
}
nonisolated enum Fixture {
    static var base: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURE_BASE"]!) }
    static var foreign: URL { base.appendingPathComponent("standalone/.codex") }
    static var retired: URL { URL.sentientSupport.appendingPathComponent("Bundled Codex") }
    static var scenario: String { ProcessInfo.processInfo.environment["FIXTURE_SCENARIO"]! }
    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func remove(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true || FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    static func jwt(plan: String) -> String {
        let claims: [String: Any] = ["sub": "synthetic-person", "https://api.openai.com/auth": ["chatgpt_plan_type": plan], "exp": 4102444800]
        let bytes = try! JSONSerialization.data(withJSONObject: claims)
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return "fixture.\(payload).invalid"
    }
    static func auth(plan: String, account: String) -> String {
        let object: [String: Any] = ["auth_mode": "chatgpt", "sentinel": "preserve-own-key", "tokens": ["account_id": account, "access_token": jwt(plan: plan), "id_token": jwt(plan: plan), "refresh_token": "nonfunctional-fixture"]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    static func snapshot(_ root: URL) throws -> [String: String] {
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        var result: [String: String] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as! FileAttributeType
            let payload = type == .typeRegular ? try CodexRuntime.sha256(url) : type.rawValue
            result[path] = "\(attributes[.systemFileNumber]!)|\(attributes[.posixPermissions]!)|\(payload)"
        }
        return result
    }
}
nonisolated enum DependencyDownload {
    static func run(_ url: URL, to destination: URL, timeout: TimeInterval, resumeDataURL: URL?, onProgress: @Sendable (Double?) -> Void) async throws {
        fatalError("Network is forbidden in this fixture")
    }
}
nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture.unused.helper"
    enum RuntimeError: Error { case helperRunning }
    static func validate(at url: URL) async throws -> Bool { fatalError("No helper execution") }
}
nonisolated enum CustomProvider { static let apiKeyEnvName = "SENTIENT_MODEL_API_KEY"; static let apiKeyEnvValue = "fixture-custom-only" }
nonisolated enum ChildProcessDiagnostics { static let environmentKey = "FIXTURE_CHILD_DIAGNOSTICS"; @TaskLocal static var directory: URL? }
nonisolated struct SidekickInteraction: Sendable {
    static let current: Self? = nil
    enum Failure: Error { case toolWhileWaiting }
    func observeToolEvent(_ line: String) throws { }
}
nonisolated final class RunWatchdog {
    init(timeout: TimeInterval, interaction: SidekickInteraction?, onTimeout: @escaping @Sendable () -> Void) { }
    func cancel() { }
}

@main struct Harness {
    static func main() async throws {
        let fm = FileManager.default
        var checks = 0
        func check(_ valid: Bool, _ label: String) {
            precondition(valid, label); checks += 1; print("PASS \(Fixture.scenario): \(label)")
        }
        func rejects(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
        let sentinelScript = "#!/bin/sh\n/usr/bin/touch '\(Fixture.base.path)/FOREIGN_EXECUTED'\nexit 1\n"
        for foreign in [Fixture.foreign, Fixture.retired.appendingPathComponent(".codex")] {
            try Fixture.write(Fixture.auth(plan: "free", account: "standalone-account"), to: foreign.appendingPathComponent("auth.json"))
            try Fixture.write("foreign configuration", to: foreign.appendingPathComponent("config.toml"))
            try Fixture.write("foreign session", to: foreign.appendingPathComponent("sessions/sentinel.jsonl"))
            try Fixture.write("foreign plugin", to: foreign.appendingPathComponent("plugins/cache/sentinel.json"))
            try Fixture.write(sentinelScript, to: foreign.appendingPathComponent("packages/standalone/current/bin/codex"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.appendingPathComponent("packages/standalone/current/bin/codex").path)
            try Fixture.write(#"{"version":"0.160.0","target":"fixture"}"#, to: foreign.appendingPathComponent("packages/standalone/current/codex-package.json"))
        }
        try Fixture.write("old migration", to: Fixture.retired.appendingPathComponent(".migration-started"))
        let originalForeign = try Fixture.snapshot(Fixture.foreign)
        let originalRetired = try Fixture.snapshot(Fixture.retired)
        check(CodexRuntime.root == URL.sentientSupport.appendingPathComponent("Private Codex", isDirectory: true), "new root excludes retired runtime")
        check(CodexCLI.locateBinary() == nil && CodexAuth.currentPlan() == nil && CodexRuntime.accountIdentity == nil, "standalone binary and login ignored")
        check(await CodexCLI.loginStatus() == false, "standalone login never satisfies private sign-in")
        try CodexRuntime.prepareHome()
        try Fixture.write("stale marker", to: CodexRuntime.root.appendingPathComponent(".migration-started"))

        if Fixture.scenario == "bad-archive" {
            var rejected = false
            do { try await CodexRuntimeInstall.install(.cli) { _ in } } catch { rejected = true }
            check(rejected && CodexCLI.locateBinary() == nil, "invalid archive never published")
        } else {
            try await CodexRuntimeInstall.install(.cli) { _ in }
            let version = await CodexCLI.installedVersion()
            check(CodexCLI.locateBinary() == CodexRuntime.executable.path && version == "0.160.0", "approved local package installed and executed privately")
            check(try await CodexCLI.executeAsync(binary: CodexRuntime.executable.path, args: ["--fixture-home"], stdinText: nil, cwd: nil, timeout: 5).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == CodexRuntime.home.path, "actual process uses private CODEX_HOME")
            let signedIn = await CodexCLI.loginStatus()
            check(CodexAuth.currentPlan() == nil && !signedIn && !fm.fileExists(atPath: CodexRuntime.plugins.path), "install imports no auth or connector cache")
            switch Fixture.scenario {
            case "normal":
                let own = Fixture.auth(plan: "plus", account: "private-account")
                try Fixture.write(own, to: CodexRuntime.auth)
                check(try CodexRuntime.readAuthData() == Data(own.utf8) && CodexAuth.currentPlan()?.raw == "plus" && CodexRuntime.accountIdentity != nil, "private regular auth is readable")
                check(CodexAuthSnapshot.read().mode == .chatgpt && CodexAuthSnapshot.read().plan == "plus", "diagnostics use only private auth")
                check(await CodexCLI.loginStatus(), "explicit private login detected")
                let object = try JSONSerialization.jsonObject(with: Data(own.utf8)) as! [String: Any]
                try CodexAuth.writeBack(["id_token": Fixture.jwt(plan: "pro"), "refresh_token": "rotated-fixture"], into: object)
                let updated = try JSONSerialization.jsonObject(with: CodexRuntime.readAuthData()) as! [String: Any]
                check(CodexAuth.currentPlan()?.raw == "pro" && updated["sentinel"] as? String == "preserve-own-key", "refresh writeback preserves own account fields")
                check((try fm.attributesOfItem(atPath: CodexRuntime.auth.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "own auth mode is private")
                let authBefore = try CodexRuntime.readAuthData()
                try Fixture.write("own config", to: CodexRuntime.home.appendingPathComponent("config.toml"))
                try Fixture.write("own session", to: CodexRuntime.home.appendingPathComponent("sessions/sentinel.jsonl"))
                try await CodexRuntimeInstall.install(.cli, force: true) { _ in }
                check(try CodexRuntime.readAuthData() == authBefore && String(contentsOf: CodexRuntime.home.appendingPathComponent("sessions/sentinel.jsonl"), encoding: .utf8) == "own session", "software repair retains private login and sessions")
                let inherited = ["HOME": Fixture.foreign.path, "CODEX_HOME": Fixture.foreign.path, "CODEX_CLI_PATH": Fixture.foreign.appendingPathComponent("packages/standalone/current/bin/codex").path, "OPENAI_API_KEY": "fixture", "CODEX_API_KEY": "fixture", "CODEX_ACCESS_TOKEN": "fixture", "CODEX_REFRESH_TOKEN_URL_OVERRIDE": "fixture", "CODEX_REVOKE_TOKEN_URL_OVERRIDE": "fixture", "CODEX_APP_SERVER_LOGIN_CLIENT_ID": "fixture", "SENTIENT_MODEL_API_KEY": "custom-fixture"]
                let env = CodexRuntime.environment(inherited, binary: CodexRuntime.executable.path)
                check(env["CODEX_HOME"] == CodexRuntime.home.path && env["HOME"] == NSHomeDirectory() && env.keys.filter { inherited[$0] == "fixture" }.isEmpty && env["SENTIENT_MODEL_API_KEY"] == "custom-fixture", "hostile inherited auth variables cannot override private login")
                check(env["CODEX_CLI_PATH"] == CodexRuntime.executable.path, "inherited helper CLI path is replaced by private binary")
                let foreignBinary = Fixture.foreign.appendingPathComponent("packages/standalone/current/bin/codex").path
                check(!CodexRuntime.isCodex(foreignBinary) && CodexRuntime.environment(inherited, binary: foreignBinary) == inherited && CodexRuntime.arguments(["--version"], binary: foreignBinary) == ["--version"], "unrelated process environment preserved")
                check(CodexRuntime.arguments(["--version"], binary: CodexRuntime.executable.path).contains("cli_auth_credentials_store=\"file\""), "private CLI explicitly uses file credentials")
                try Fixture.write("stale private plugin", to: CodexRuntime.plugins.appendingPathComponent("old.json"))
                check(try CodexRuntime.prepareAccountCache() && CodexRuntime.connectorCacheMatchesAccount && !fm.fileExists(atPath: CodexRuntime.plugins.path), "new own account clears only own cache")
                check(try CodexRuntime.prepareAccountCache() == false, "same own account retains cache")
                check(CodexRuntimeInstall.safeEntries("bin/codex\ncodex-package.json\n") && !CodexRuntimeInstall.safeEntries("../auth.json\n") && !CodexRuntimeInstall.safeEntries("/absolute\n") && !CodexRuntimeInstall.safeEntries("bin\\escape\n"), "archive traversal names rejected")
            case "auth-link":
                try fm.createSymbolicLink(at: CodexRuntime.auth, withDestinationURL: Fixture.foreign.appendingPathComponent("auth.json"))
                check(rejects { _ = try CodexRuntime.readAuthData() } && rejects { try CodexRuntime.prepareHome() }, "auth symlink rejected before read or chmod")
                check(CodexAuth.currentPlan() == nil && CodexRuntime.accountIdentity == nil && CodexAuthSnapshot.read().mode == .unreadable, "linked standalone login never appears in app")
                check(await CodexCLI.loginStatus() == false, "actual process refuses auth symlink")
            case "auth-fifo":
                precondition(mkfifo(CodexRuntime.auth.path, 0o600) == 0)
                let start = Date()
                check(rejects { _ = try CodexRuntime.readAuthData() } && CodexAuth.currentPlan() == nil, "auth special file rejected")
                check(Date().timeIntervalSince(start) < 1, "auth FIFO cannot stall profile reads")
            case "home-link", "root-link":
                let target = Fixture.scenario == "home-link" ? CodexRuntime.home : CodexRuntime.root
                try Fixture.remove(target)
                try fm.createSymbolicLink(at: target, withDestinationURL: Fixture.foreign)
                check(rejects { _ = try CodexRuntime.readAuthData() } && rejects { try CodexRuntime.prepareHome() }, "linked home/root rejected before auth or directory mutation")
                check(CodexRuntime.accountIdentity == nil && CodexAuth.currentPlan() == nil, "linked home/root has no adopted login")
                if Fixture.scenario == "root-link" { check(CodexCLI.locateBinary() == nil, "linked runtime root not discovered") }
            case "plugin-link", "plugin-cache-link":
                try Fixture.write(Fixture.auth(plan: "plus", account: "private-account"), to: CodexRuntime.auth)
                let relative = Fixture.scenario == "plugin-link" ? "plugins" : "plugins/cache"
                let link = CodexRuntime.home.appendingPathComponent(relative)
                try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: link, withDestinationURL: Fixture.foreign.appendingPathComponent(relative))
                check(rejects { _ = try CodexRuntime.prepareAccountCache() }, "plugin parent symlink rejects cache cleanup")
                check(CodexRuntime.connectorCacheMatchesAccount == false, "linked plugin cache is never trusted")
            case "marker-link":
                try Fixture.write(Fixture.auth(plan: "plus", account: "private-account"), to: CodexRuntime.auth)
                let marker = Fixture.foreign.appendingPathComponent(".sentient-connector-account")
                try Fixture.write(CodexRuntime.accountIdentity!, to: marker)
                try fm.createSymbolicLink(at: CodexRuntime.home.appendingPathComponent(".sentient-connector-account"), withDestinationURL: marker)
                check(!CodexRuntime.connectorCacheMatchesAccount, "linked external cache marker is not trusted")
                check(rejects { _ = try CodexRuntime.prepareAccountCache() }, "linked cache marker rejected before read or replacement")
                try Fixture.remove(marker)
            case "marker-fifo":
                try Fixture.write(Fixture.auth(plan: "plus", account: "private-account"), to: CodexRuntime.auth)
                precondition(mkfifo(CodexRuntime.home.appendingPathComponent(".sentient-connector-account").path, 0o600) == 0)
                let start = Date()
                check(rejects { _ = try CodexRuntime.prepareAccountCache() } && !CodexRuntime.connectorCacheMatchesAccount, "cache marker special file rejected")
                check(Date().timeIntervalSince(start) < 1, "cache marker FIFO cannot stall profile reads")
            case "modified-cli":
                check(await CodexCLI.isRunnable(), "verified CLI initially runnable")
                try Fixture.write(sentinelScript, to: CodexRuntime.executable)
                check(await CodexCLI.isRunnable() == false, "changed executable rejected by actual launch path")
            case "cli-link":
                try Fixture.remove(CodexRuntime.executable)
                try fm.createSymbolicLink(at: CodexRuntime.executable, withDestinationURL: Fixture.foreign.appendingPathComponent("packages/standalone/current/bin/codex"))
                check(CodexCLI.locateBinary() == nil, "linked foreign executable not discovered")
                check(await CodexCLI.isRunnable() == false, "linked foreign executable cannot launch")
            case "cli-directory-link", "manifest-link":
                let directory = Fixture.scenario == "cli-directory-link"
                let target = directory ? CodexRuntime.cliDirectory : CodexRuntime.cliDirectory.appendingPathComponent("codex-package.json")
                let source = directory ? Fixture.foreign.appendingPathComponent("packages/standalone/current") : Fixture.foreign.appendingPathComponent("packages/standalone/current/codex-package.json")
                try Fixture.remove(target)
                try fm.createSymbolicLink(at: target, withDestinationURL: source)
                check(CodexCLI.locateBinary() == nil, "linked release or package metadata not discovered")
                check(await CodexCLI.isRunnable() == false, "linked release or metadata cannot launch")
            default: preconditionFailure("unknown fixture scenario")
            }
        }
        check(try Fixture.snapshot(Fixture.foreign) == originalForeign && Fixture.snapshot(Fixture.retired) == originalRetired, "standalone and retired sentinel contents/inodes/modes unchanged")
        check(!fm.fileExists(atPath: Fixture.base.appendingPathComponent("FOREIGN_EXECUTED").path), "foreign CLI never executed")
        print("Checked \(checks) \(Fixture.scenario) checks; failures=0")
    }
}
'''

SHELL = '''#!/bin/sh
case "$*" in
*--version*) echo 'codex-cli 0.160.0';;
*--help*) echo 'Synthetic Codex fixture';;
*--fixture-home*) echo "$CODEX_HOME";;
*'login status'*) if test -f "$CODEX_HOME/auth.json"; then echo 'Logged in'; else echo 'Not logged in'; exit 1; fi;;
*) exit 2;;
esac
'''

with tempfile.TemporaryDirectory(prefix='sentient-private-runtime-') as directory:
    root = Path(directory)
    package = root / 'package'
    (package / 'bin').mkdir(parents=True)
    (package / 'bin/codex').write_text(SHELL)
    (package / 'bin/codex').chmod(0o755)
    (package / 'codex-package.json').write_text(json.dumps({'version': '0.160.0', 'target': 'fixture'}))
    archives = root / 'archives'
    archives.mkdir()
    archive = archives / 'fixture-cli.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for relative in ['bin/codex', 'codex-package.json']:
            tar.add(package / relative, arcname=relative)
    files = [dict(path=str(path.relative_to(package)), bytes=path.stat().st_size,
                  sha256=hashlib.sha256(path.read_bytes()).hexdigest(), executable=bool(path.stat().st_mode & 0o111))
             for path in sorted(package.rglob('*')) if path.is_file()]
    cli_manifest = dict(version='0.160.0', filename=archive.name, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), bytes=archive.stat().st_size, files=files)
    manifest = root / 'manifest.json'
    manifest.write_text(json.dumps(dict(target='fixture', cli=cli_manifest, helper=cli_manifest, helperBuild=1)))
    fixture = root / 'Fixture.swift'
    fixture.write_text(FIXTURE + '\n' + production)
    binary = root / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-DDEBUG', '-swift-version', '6', '-parse-as-library',
                    str(APP / 'Cloud/CodexRuntime.swift'), str(APP / 'Cloud/CodexRuntimeInstall.swift'),
                    str(fixture), '-o', str(binary)], check=True)
    total_checks = 1  # Release artifact selection below.
    for scenario in ['normal', 'auth-link', 'auth-fifo', 'home-link', 'root-link', 'plugin-link', 'plugin-cache-link', 'marker-link', 'marker-fifo', 'modified-cli', 'cli-link', 'cli-directory-link', 'manifest-link', 'bad-archive']:
        base = root / scenario
        base.mkdir()
        env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', FIXTURE_BASE=str(base), FIXTURE_SCENARIO=scenario,
                   SENTIENT_CODEX_MANIFEST=str(manifest), SENTIENT_CODEX_ARCHIVE_DIR=str(archives),
                   HOME=str(base / 'standalone'), CODEX_HOME=str(base / 'standalone/.codex'),
                   CODEX_CLI_PATH=str(base / 'standalone/.codex/packages/standalone/current/bin/codex'),
                   SENTIENT_CODEX_MIGRATION_SOURCE=str(base / 'standalone/.codex'))
        if scenario == 'bad-archive':
            bad = base / 'archives'
            bad.mkdir()
            (bad / archive.name).write_text('wrong bytes')
            env['SENTIENT_CODEX_ARCHIVE_DIR'] = str(bad)
        result = subprocess.run([str(binary)], env=env, cwd=base, check=True, timeout=30, capture_output=True, text=True)
        print(result.stdout, end='', flush=True)
        total_checks += int(result.stdout.split('Checked ')[-1].split()[0])
    # Release artifact selection must ignore the DEBUG local-archive knob.
    release_probe = root / 'ReleaseProbe.swift'
    release_probe.write_text('import Foundation\nextension URL { static var sentientSupport: URL { fatalError() } }\n@main struct Probe { static func main() { let artifact = CodexRuntime.Artifact(version: "fixture", filename: "fixture.tar.gz", sha256: "", bytes: 0, files: []); precondition(artifact.url.absoluteString == "https://sentient-downloads.sentient-doubletap-relay.workers.dev/releases/fixture.tar.gz"); print("PASS release: approved Cloudflare artifact source only") } }')
    release_binary = root / 'release-check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(APP / 'Cloud/CodexRuntime.swift'), str(release_probe), '-o', str(release_binary)], check=True)
    subprocess.run([str(release_binary)], env=dict(PATH='/usr/bin:/bin', SENTIENT_CODEX_ARCHIVE_DIR=str(archives)), check=True, timeout=10)
    print(f'Checked {total_checks} private runtime assertions; failures=0')
