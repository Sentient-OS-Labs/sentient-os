#!/usr/bin/env python3
"""Check private helper routing and uninstall preservation with isolated fixtures.

Compiles the production helper configuration/ownership and foreground cleanup methods.
Runs the production post-exit shell cleanup against temporary paths only. No accounts,
Keychain, real helper applications, model prompts, or network are used.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


helper = (APP / "Driver/OpenAIComputerUse.swift").read_text()
uninstall = (APP / "System/Uninstall.swift").read_text()
runtime = (APP / "Driver/OpenAIComputerUseRuntime.swift").read_text()
assert "CodexRuntimeMigration" not in helper + uninstall
assert "CodexRuntime.activeHome" not in helper
lab = (APP / "Self Tests - Temp/NativeComputerUseLab.swift").read_text()
assert "LAB_CLI_BINARY" not in lab and "LAB_NATIVE_HELPER" not in lab
assert "configuration.clientEnvironment.sorted" in lab
restart = declaration(runtime, "func restart(configuration selected:")
assert "$0.bundleURL?.standardizedFileURL == configuration.appURL.standardizedFileURL" in restart
assert "restoreLegacyAuthentication" not in uninstall
assert 'URL.sentientSupport.path, retiredRuntimeDirectoryName] + stragglers' in uninstall
assert '"sleep 2\\n" + postExitCleanupScript' in uninstall
script = re.search(r'static let postExitCleanupScript = #"""\n(.*?)\n    """#', uninstall, re.S).group(1)
retired = re.search(r'static let retiredRuntimeDirectoryName = "([^"]+)"', uninstall).group(1)

production = "\n".join(declaration(helper, signature) for signature in (
    "struct Configuration:",
    "enum RuntimeError:",
    "@concurrent static func acceptsRunningHelper(",
    "@MainActor static func stopOwnedHelper()",
    "static func tomlString(_ value:",
))
cleanup = declaration(uninstall, "static func removeSupportFiles(at support:")
fixture = r'''
import Foundation
import Darwin

nonisolated enum CodexRuntime {
    nonisolated(unsafe) static var root = URL(fileURLWithPath: "/fixture-unset")
    nonisolated(unsafe) static var prepared = 0
    nonisolated(unsafe) static var verified = 0
    static var home: URL { root.appendingPathComponent(".codex", isDirectory: true) }
    static var executable: URL { root.appendingPathComponent("bin/codex") }
    static var helper: URL { home.appendingPathComponent("computer-use/Codex Computer Use.app", isDirectory: true) }
    static func prepareHome() throws { prepared += 1 }
    static func verifyCLIForLaunch() throws { verified += 1 }
}
nonisolated enum CodexCLI {
    static func locateBinary() -> String? { CodexRuntime.executable.path }
}
@MainActor final class NSRunningApplication {
    static var applications: [NSRunningApplication] = []
    let bundleURL: URL?
    var isTerminated = false
    var terminateCalls = 0
    var forceTerminateCalls = 0
    init(_ url: URL?) { bundleURL = url }
    static func runningApplications(withBundleIdentifier: String) -> [NSRunningApplication] { applications }
    func terminate() { terminateCalls += 1; isTerminated = true }
    func forceTerminate() { forceTerminateCalls += 1; isTerminated = true }
}
nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture"
    static let clientRelativePath = "Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    static var codexHome: URL { CodexRuntime.home }
__PRODUCTION__
}
enum Uninstall {
    static let retiredRuntimeDirectoryName = "Bundled Codex"
__CLEANUP__
}
@main struct Fixture {
    @MainActor static func main() async throws {
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode == "cleanup" {
            do { try Uninstall.removeSupportFiles(at: root) }
            catch { exit(2) }
            return
        }
        CodexRuntime.root = root
        if mode == "linked-helper" {
            let foreign = root.appendingPathComponent("foreign/Codex Computer Use.app").resolvingSymlinksInPath()
            let foreignApp = NSRunningApplication(foreign)
            NSRunningApplication.applications = [foreignApp]
            try await OpenAIComputerUse.stopOwnedHelper()
            precondition(foreignApp.terminateCalls == 0 && foreignApp.forceTerminateCalls == 0)
            print("PASS a private helper app symlink never makes a foreign process owned")
            return
        }
        let inherited = ["HOME": root.path, "PATH": "/fixture/bin", "CODEX_HOME": "/foreign/.codex",
                         "CODEX_CLI_PATH": "/foreign/codex", "OPENAI_API_KEY": "fixture-key"]
        let config = try OpenAIComputerUse.Configuration(cliPath: CodexRuntime.executable.path, environment: inherited)
        precondition(config.home == CodexRuntime.home.resolvingSymlinksInPath() && config.cliURL == CodexRuntime.executable.resolvingSymlinksInPath())
        precondition(config.environment["CODEX_HOME"] == config.home.path)
        precondition(config.environment["CODEX_CLI_PATH"] == config.cliURL.path)
        precondition(config.environment["OPENAI_API_KEY"] == nil)
        let afterLease = try config.afterRuntimeLease()
        precondition(afterLease == config)
        print("PASS private helper routing overrides foreign environment")
        let prepared = CodexRuntime.prepared, verified = CodexRuntime.verified
        do {
            _ = try OpenAIComputerUse.Configuration(cliPath: root.appendingPathComponent("foreign/codex").path)
            preconditionFailure("foreign executable accepted")
        } catch OpenAIComputerUse.RuntimeError.cliUnavailable {}
        do {
            _ = try OpenAIComputerUse.Configuration(cliPath: CodexRuntime.executable.path,
                                                   home: root.appendingPathComponent("foreign/.codex"))
            preconditionFailure("foreign home accepted")
        } catch OpenAIComputerUse.RuntimeError.cliUnavailable {}
        precondition(CodexRuntime.prepared == prepared && CodexRuntime.verified == verified)
        print("PASS foreign executable/home rejected before verification or preparation")
        let own = config.appURL
        let foreign = root.appendingPathComponent("standalone/.codex/computer-use/Codex Computer Use.app")
        let retired = root.appendingPathComponent("Bundled Codex/.codex/computer-use/Codex Computer Use.app")
        let ownAccepted = await OpenAIComputerUse.acceptsRunningHelper(at: own, configuration: config)
        let foreignAccepted = await OpenAIComputerUse.acceptsRunningHelper(at: foreign, configuration: config)
        let retiredAccepted = await OpenAIComputerUse.acceptsRunningHelper(at: retired, configuration: config)
        precondition(ownAccepted && !foreignAccepted && !retiredAccepted)
        print("PASS running foreign and retired helpers are never reused")
        let ownApp = NSRunningApplication(CodexRuntime.helper), foreignApp = NSRunningApplication(foreign)
        let retiredApp = NSRunningApplication(retired), unknownApp = NSRunningApplication(nil)
        NSRunningApplication.applications = [ownApp, foreignApp, retiredApp, unknownApp]
        try await OpenAIComputerUse.stopOwnedHelper()
        precondition(ownApp.terminateCalls == 1)
        precondition([foreignApp, retiredApp, unknownApp].allSatisfy { $0.terminateCalls == 0 && $0.forceTerminateCalls == 0 })
        print("PASS uninstall terminates only the exact private helper")
    }
}
'''.replace("__PRODUCTION__", production).replace("__CLEANUP__", cleanup)


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


with tempfile.TemporaryDirectory(prefix="sentient-private-cleanup-") as tmp:
    base = Path(tmp).resolve()
    swift = base / "Fixture.swift"
    swift.write_text(fixture)
    binary = base / "fixture"
    run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)])
    private = base / "Private Codex"
    (private / "bin").mkdir(parents=True)
    (private / ".codex/computer-use/Codex Computer Use.app").mkdir(parents=True)
    cli = private / "bin/codex"
    cli.write_text("fixture executable only")
    cli.chmod(0o755)
    run([str(binary), "helper", str(private)])
    foreign_helper = private / "foreign/Codex Computer Use.app"
    foreign_helper.mkdir(parents=True)
    helper_link = private / ".codex/computer-use/Codex Computer Use.app"
    helper_link.rmdir()
    helper_link.symlink_to(foreign_helper, target_is_directory=True)
    run([str(binary), "linked-helper", str(private)])

    support = base / "Support ' $(touch SHOULD_NOT_EXIST)"
    backing = support / retired / ".codex/auth.json"
    backing.parent.mkdir(parents=True)
    backing.write_text("synthetic retired credentials")
    outside = base / "standalone"
    outside.mkdir()
    link = outside / "auth.json"
    link.symlink_to(backing)
    sentinel = outside / "untouched"
    sentinel.write_text("synthetic standalone state")
    original = (backing.stat().st_ino, backing.stat().st_mtime_ns, backing.read_bytes(), os.readlink(link))

    def populate():
        (support / "Private Codex/.codex").mkdir(parents=True)
        (support / "Private Codex/.codex/auth.json").write_text("synthetic private credentials")
        (support / ".hidden-state").write_text("remove")
        (support / "ordinary").write_text("remove")
        (support / "outside-link").symlink_to(sentinel)

    def preserved():
        assert (backing.stat().st_ino, backing.stat().st_mtime_ns, backing.read_bytes(), os.readlink(link)) == original
        assert link.read_bytes() == original[2]
        assert sentinel.read_text() == "synthetic standalone state"
        assert sorted(p.name for p in support.iterdir()) == [retired]
        assert not (base / "SHOULD_NOT_EXIST").exists()

    populate()
    run([str(binary), "cleanup", str(support)])
    preserved()
    run([str(binary), "cleanup", str(support)])
    preserved()
    print("PASS foreground cleanup preserves retired auth inode and external compatibility link")
    populate()
    stray = base / "preferences ' $(touch SHOULD_NOT_EXIST)"
    stray.write_text("remove")
    run(["/bin/sh", "-c", script, "fixture-cleanup", str(support), retired, str(stray)], cwd=base)
    preserved()
    assert not stray.exists()
    print("PASS post-exit cleanup preserves retired subtree and treats paths as data")

    for mode in ("foreground", "shell"):
        empty = base / ("empty-" + mode)
        empty.mkdir()
        (empty / "owned").write_text("remove")
        if mode == "foreground":
            run([str(binary), "cleanup", str(empty)])
        else:
            run(["/bin/sh", "-c", script, "fixture-cleanup", str(empty), retired])
        assert not empty.exists()
        symlink_support = base / ("symlink-retired-" + mode)
        symlink_support.mkdir()
        preserved_link = symlink_support / retired
        preserved_link.symlink_to(outside, target_is_directory=True)
        (symlink_support / "owned").write_text("remove")
        if mode == "foreground":
            run([str(binary), "cleanup", str(symlink_support)])
        else:
            run(["/bin/sh", "-c", script, "fixture-cleanup", str(symlink_support), retired])
        assert preserved_link.is_symlink() and os.readlink(preserved_link) == str(outside)
        assert sentinel.read_text() == "synthetic standalone state"
        assert list(symlink_support.iterdir()) == [preserved_link]
    print("PASS both cleanup paths remove empty support and blindly preserve retired symlinks")

    linked_support = base / "linked-support"
    linked_support.symlink_to(outside, target_is_directory=True)
    foreground = subprocess.run([str(binary), "cleanup", str(linked_support)])
    shell = subprocess.run(["/bin/sh", "-c", script, "fixture-cleanup", str(linked_support), retired])
    assert foreground.returncode == 2 and shell.returncode == 1
    assert linked_support.is_symlink() and sentinel.read_text() == "synthetic standalone state"
    assert link.read_bytes() == original[2]
    print("PASS both cleanup paths reject a symlinked support root without traversing it")

print("Private helper and uninstall isolation checks passed.")
