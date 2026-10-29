#!/usr/bin/env python3
"""Exercise actual runtime installation and helper handoff with disposable upgrade fixtures.

Only Launch Services, code-sign validation, and CLI probes are inert. The real manifest
verification, archive extraction, file leases, atomic swap, rollback, and graceful shutdown
code run. No user processes, credentials, preferences, network, or model calls are used.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import zipfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SWIFT = r'''
import Foundation
import Darwin

extension URL { static var sentientSupport: URL { fatalError("Use an isolated runtime") } }
@MainActor final class NSRunningApplication {
    static var apps: [NSRunningApplication] = []
    let bundleURL: URL?
    var isTerminated = false
    var refuses = false
    var terminateCalls = 0
    var forceCalls = 0
    var onTerminate: (() -> Void)?
    init(_ path: URL?) { bundleURL = path }
    static func runningApplications(withBundleIdentifier: String) -> [NSRunningApplication] { apps.filter { !$0.isTerminated } }
    func terminate() { terminateCalls += 1; onTerminate?(); if !refuses { isTerminated = true } }
    func forceTerminate() { forceCalls += 1; fatalError("An update must never force-quit") }
}
nonisolated enum CodexCLI {
    struct ExecResult { let status: Int32; let stdout: String }
    static func executeAsync(binary: String, args: [String], stdinText: String?, cwd: URL?, timeout: TimeInterval) async throws -> ExecResult {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: binary); task.arguments = args
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return ExecResult(status: task.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
    static func installedVersion(binary: String) async -> String? { "2.0.0" }
    static func isRunnable(binary: String) async -> Bool { true }
}
nonisolated enum DependencyDownload {
    static func run(_ url: URL, to: URL, timeout: TimeInterval, resumeDataURL: URL?, onProgress: @Sendable (Double?) -> Void) async throws {
        fatalError("Network is forbidden")
    }
}
nonisolated enum OpenAIComputerUse {
    static let bundleID = "fixture.helper"
    enum RuntimeError: Error { case helperRunning, invalidSignature }
    static func validate(at url: URL) async throws {
        if ProcessInfo.processInfo.environment["SCENARIO"] == "signature" { throw RuntimeError.invalidSignature }
        precondition(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/service").path))
    }
__HELPER_METHODS__
}
@main struct Upgrade {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let scenario = ProcessInfo.processInfo.environment["SCENARIO"]!
        try CodexRuntime.prepareHome()
        let old = CodexRuntime.helper
        try fm.createDirectory(at: old.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let service = old.appendingPathComponent("Contents/MacOS/service")
        try Data("old helper".utf8).write(to: service)
        // Keep inode evidence as well as content. Upgrade must not rewrite account/state files.
        let state = ["auth.json", "config.toml", "sessions/old.jsonl", "state_5.sqlite", "plugins/cache/account.json"]
        var before: [String: String] = [:]
        for name in state {
            let path = CodexRuntime.home.appendingPathComponent(name)
            try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("synthetic " + name).utf8).write(to: path)
            let inode = try fm.attributesOfItem(atPath: path.path)[.systemFileNumber]!
            before[name] = "\(inode)|\(try CodexRuntime.sha256(path))"
        }
        // A successful CLI installation can precede a helper failure; its presence must
        // not make setup accept an old helper, and retry must retain all mutable state.
        try await CodexRuntimeInstall.install(.cli) { _ in }
        let owned = NSRunningApplication(old)
        let foreign = NSRunningApplication(URL(fileURLWithPath: "/foreign/Codex Computer Use.app"))
        NSRunningApplication.apps = scenario == "no-helper-process" ? [foreign] : [owned, foreign]
        var lease: CodexRuntime.FileLock?
        if scenario == "busy" { lease = try CodexRuntime.sharedRuntimeLeaseSync() }
        if scenario == "refusal" || scenario == "cancel" { owned.refuses = true }
        if scenario == "respawn" { owned.onTerminate = { NSRunningApplication.apps.append(NSRunningApplication(old)) } }
        if scenario == "rollback" {
            try fm.removeItem(at: CodexRuntime.receipt)
            try fm.createDirectory(at: CodexRuntime.receipt, withIntermediateDirectories: false)
        }
        let install = Task { try await CodexRuntimeInstall.install(.helper) { _ in } }
        if scenario == "cancel" {
            for _ in 0..<500 {
                if owned.terminateCalls > 0 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(owned.terminateCalls == 1, "Cancellation must exercise shutdown")
            install.cancel()
        }
        var failure: Error?
        do { try await install.value } catch { failure = error }
        lease?.unlock()
        let succeeds = ["success", "no-helper-process"].contains(scenario)
        precondition((failure == nil) == succeeds, "Unexpected install outcome: \(scenario), \(String(describing: failure))")
        precondition(foreign.terminateCalls == 0 && foreign.forceCalls == 0)
        if succeeds {
            try CodexRuntime.verify(CodexRuntime.release.helper, at: old)
            precondition(owned.terminateCalls == (scenario == "success" ? 1 : 0))
            // No-op reuse must not stop a healthy current helper.
            let current = NSRunningApplication(old); NSRunningApplication.apps = [current]
            try await CodexRuntimeInstall.install(.helper) { _ in }
            precondition(current.terminateCalls == 0)
        } else {
            let preserved = try String(contentsOf: service, encoding: .utf8)
            precondition(preserved == "old helper", "Old helper lost on failure")
            if ["busy", "signature", "corrupt"].contains(scenario) { precondition(owned.terminateCalls == 0) }
            if scenario == "cancel" { precondition(failure is CancellationError) }
            if scenario == "refusal" {
                owned.refuses = false
                try await CodexRuntimeInstall.install(.helper) { _ in }
                try CodexRuntime.verify(CodexRuntime.release.helper, at: old)
            }
        }
        for name in state {
            let path = CodexRuntime.home.appendingPathComponent(name)
            let inode = try fm.attributesOfItem(atPath: path.path)[.systemFileNumber]!
            let hash = try CodexRuntime.sha256(path)
            precondition(before[name] == "\(inode)|\(hash)", "Mutable state changed: \(name)")
        }
        print("PASS \(scenario): upgrade outcome, helper ownership, and login/config/session/cache bytes and inodes")
    }
}
extension CodexRuntime {
    static func sharedRuntimeLeaseSync() throws -> FileLock {
        try FileLock(root.appendingPathComponent(".runtime.lock"), exclusive: false)
    }
}
'''


def record(path, relative):
    return dict(path=relative, bytes=path.stat().st_size,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(), executable=bool(path.stat().st_mode & 0o111))


with tempfile.TemporaryDirectory(prefix="sentient-upgrade-") as directory:
    root = Path(directory)
    helper = (APP / "Driver/OpenAIComputerUse.swift").read_text()
    methods = "\n".join(declaration(helper, name) for name in [
        "@MainActor static func stopOwnedHelper(", "@MainActor private static func terminateHelpers("])
    (root / "Fixture.swift").write_text(SWIFT.replace("__HELPER_METHODS__", methods))
    (root / "Install.swift").write_text((APP / "Cloud/CodexRuntimeInstall.swift").read_text().replace("import AppKit", ""))
    subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-swift-version", "6", "-parse-as-library",
                    str(APP / "Cloud/CodexRuntime.swift"), str(root / "Install.swift"),
                    str(root / "Fixture.swift"), "-o", str(root / "test")], check=True)
    archives = root / "archives"
    archives.mkdir()
    files = {}
    for component, relative in [("cli", "bin/codex"), ("helper", "Contents/MacOS/service")]:
        package = root / component
        path = package / relative
        path.parent.mkdir(parents=True)
        path.write_text("new " + component)
        path.chmod(0o755)
        archive = archives / (component + (".tar.gz" if component == "cli" else ".zip"))
        if component == "cli":
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(path, arcname=relative)
        else:
            with zipfile.ZipFile(archive, "w") as zip:
                zip.write(path, arcname="Codex Computer Use.app/" + relative)
        files[component] = dict(version="2.0.0", filename=archive.name, bytes=archive.stat().st_size,
                                sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), files=[record(path, relative)])
    manifest = root / "manifest.json"
    manifest.write_text(json.dumps(dict(target="fixture", helperBuild=2, **files)))
    for scenario in ["success", "no-helper-process", "busy", "refusal", "respawn", "cancel", "signature", "corrupt", "rollback"]:
        selected_archives = archives
        if scenario == "corrupt":
            selected_archives = root / "bad-archives"
            selected_archives.mkdir()
            (selected_archives / "cli.tar.gz").write_bytes((archives / "cli.tar.gz").read_bytes())
            (selected_archives / "helper.zip").write_text("corrupt")
        env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", SCENARIO=scenario,
                   SENTIENT_CODEX_RUNTIME_ROOT=str(root / scenario), SENTIENT_CODEX_MANIFEST=str(manifest),
                   SENTIENT_CODEX_ARCHIVE_DIR=str(selected_archives))
        subprocess.run([str(root / "test")], env=env, check=True, timeout=25)
