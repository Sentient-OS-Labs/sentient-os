#!/usr/bin/env python3
"""Install the real pinned archives and check private login and the native MCP catalog.

Uses production runtime/install/helper/session code and CLI process methods in a temporary
runtime. Credentials are synthetic, no model turns run, and no native tools are called.
An optional previous manifest/archive pair tests an actual old-to-new software upgrade.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

import test_private_codex_runtime as fixture

HARNESS = r'''
nonisolated func Log(_ message: String) {}
nonisolated enum CrashReporting {
    static func diagnosticBreadcrumb(_ name: String, data: [String: String]) {}
}
@main struct RealRuntime {
    static func main() async throws {
        let fm = FileManager.default
        try CodexRuntime.prepareHome()
        let state = ["auth.json", "config.toml", "sessions/sentinel.jsonl", "plugins/cache/sentinel.json"]
        // This JWT is deliberately unsigned and cannot authorize any remote request.
        if !fm.fileExists(atPath: CodexRuntime.auth.path) {
            try Fixture.write(Fixture.auth(plan: "plus", account: "synthetic-upgrade"), to: CodexRuntime.auth)
            try Fixture.write("# synthetic configuration\n", to: CodexRuntime.home.appendingPathComponent("config.toml"))
            try Fixture.write("synthetic session", to: CodexRuntime.home.appendingPathComponent("sessions/sentinel.jsonl"))
            try Fixture.write("synthetic cache", to: CodexRuntime.home.appendingPathComponent("plugins/cache/sentinel.json"))
        }
        var before: [String: String] = [:]
        func snapshot(_ name: String) throws -> String {
            let path = CodexRuntime.home.appendingPathComponent(name)
            let inode = try fm.attributesOfItem(atPath: path.path)[.systemFileNumber]!
            return "\(inode)|\(try CodexRuntime.sha256(path))"
        }
        for name in state { before[name] = try snapshot(name) }
        try await CodexRuntimeInstall.install(.cli) { _ in }
        try await CodexRuntimeInstall.install(.helper) { _ in }
        try CodexRuntime.verifyCLIForLaunch()
        let installed = try await OpenAIComputerUse.validate(at: CodexRuntime.helper)
        let version = await CodexCLI.installedVersion()
        precondition(version == CodexRuntime.release.cli.version)
        let signedIn = await CodexCLI.loginStatus()
        precondition(signedIn, "New CLI did not recognize preserved private file credentials")
        for name in state { let after = try snapshot(name); precondition(before[name] == after, "Account/state rewritten: \(name)") }
        // No login should be invented by a global CLI or the desktop application.
        let auth = try CodexRuntime.readAuthData()
        try fm.removeItem(at: CodexRuntime.auth)
        let absent = await CodexCLI.loginStatus()
        precondition(!absent, "Missing private credentials must require sign-in")
        try auth.write(to: CodexRuntime.auth)
        let restored = await CodexCLI.loginStatus()
        precondition(restored)
        let config = try OpenAIComputerUse.Configuration.resolve()
        let session = try await OpenAIComputerUseSession.open(config)
        do {
            let data = try await session.catalog()
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let servers = object["data"] as! [[String: Any]]
            let server = servers.first { $0["name"] as? String == "sentient_native" }!
            let tools = server["tools"] as! [String: Any]
            let required: Set<String> = ["list_apps", "get_app_state", "click", "perform_secondary_action", "set_value",
                                        "select_text", "scroll", "drag", "press_key", "type_text"]
            precondition(required.isSubset(of: Set(tools.keys)), "Native contract changed")
            for name in required {
                let definition = tools[name] as! [String: Any]
                precondition(definition["inputSchema"] is [String: Any])
            }
            await session.close()
        } catch { await session.close(); throw error }
        print("PASS real CLI \(version!) + helper \(installed.version): verified installation, preserved private login/state, missing-login detection, and ten native tool definitions via production session")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archives", required=True, type=Path)
    parser.add_argument("--manifest", type=Path, default=fixture.APP / "Cloud/BundledCodexRelease.json")
    parser.add_argument("--previous-manifest", type=Path)
    parser.add_argument("--previous-archives", type=Path)
    args = parser.parse_args()
    if bool(args.previous_manifest) != bool(args.previous_archives):
        parser.error("Pass both previous-manifest and previous-archives")
    with tempfile.TemporaryDirectory(prefix="sentient-real-upgrade-") as temporary:
        root = Path(temporary)
        stubs = fixture.FIXTURE.split("@main struct Harness")[0]
        start = stubs.index("nonisolated enum OpenAIComputerUse {")
        end = stubs.index("nonisolated enum CustomProvider", start)
        stubs = stubs[:start] + stubs[end:]
        source = root / "Harness.swift"
        source.write_text(stubs + fixture.production + HARNESS)
        sources = ["Cloud/CodexRuntime.swift", "Cloud/CodexRuntimeInstall.swift", "Driver/OpenAIComputerUse.swift",
                   "Driver/OpenAIComputerUseSession.swift", "Diagnostics/NativeComputerUseFailure.swift"]
        executable = root / "check"
        subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-swift-version", "6", "-parse-as-library",
                        *[str(fixture.APP / name) for name in sources], str(source), "-o", str(executable)], check=True)
        pairs = [(args.manifest, args.archives)]
        if args.previous_manifest:
            pairs.insert(0, (args.previous_manifest, args.previous_archives))
        for manifest, archives in pairs:
            release = json.loads(manifest.read_text())
            print("Checking", release["cli"]["version"], release["helper"]["version"], flush=True)
            env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", FIXTURE_BASE=str(root), FIXTURE_SCENARIO="real",
                       SENTIENT_CODEX_RUNTIME_ROOT=str(root / "runtime"), SENTIENT_CODEX_MANIFEST=str(manifest.resolve()),
                       SENTIENT_CODEX_ARCHIVE_DIR=str(archives.resolve()), HOME=str(root), TMPDIR=str(root))
            subprocess.run([str(executable)], env=env, cwd=root, check=True, timeout=180)


if __name__ == "__main__":
    main()
