//
//  PlaywrightCLI.swift
//  Sentient OS macOS
//
//  Proactive Intelligence — PART 3 (the executor), the browser engine's discovery + lifecycle.
//  `@playwright/cli` (binary `playwright-cli`) is a thin client over a detached daemon that holds a
//  Playwright-bundled Chromium open; codex drives it (snapshot → ref → act) once we've confirmed it
//  exists and torn down stale daemons. We never run the user's real Chrome (its ProcessSingleton
//  wedges — measured 10/10). Doc: Browser Automation & Session Reuse (Proactive Part 3).md §2, §5.5.
//
//  Mirrors CodexCLI's binary discovery: known paths → nvm-versioned dirs → login-shell `which`,
//  cached in UserDefaults. `SENTIENT_PLAYWRIGHT_CLI` overrides for dev.
//
//  Key methods:
//   - PlaywrightCLI.locateBinary()  → cached absolute path (nil = not installed)
//   - PlaywrightCLI.killAll()       → best-effort teardown of the detached daemon (every exit path)
//

import Foundation

/// Pure utility (discovery + Process) — `nonisolated` so the off-main ProactiveExecutor actor can
/// call it directly (the project defaults declarations to @MainActor; these don't belong there).
nonisolated enum PlaywrightCLI {

    private static let pathCacheKey = "playwrightcli.binaryPath"
    private static let binaryName = "playwright-cli"

    /// The `playwright-cli` binary, or nil if not installed. Cached + re-verified, like CodexCLI.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SENTIENT_PLAYWRIGHT_CLI"],
           fm.isExecutableFile(atPath: override) { return override }
        if let cached = UserDefaults.standard.string(forKey: pathCacheKey),
           fm.isExecutableFile(atPath: cached) { return cached }

        let home = fm.homeDirectoryForCurrentUser.path
        var known = [
            "\(home)/.local/bin/\(binaryName)",
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
        ]
        let nvmBin = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmBin) {
            known += versions.sorted(by: >).map { "\(nvmBin)/\($0)/bin/\(binaryName)" }
        }
        let found = known.first(where: { fm.isExecutableFile(atPath: $0) }) ?? whichViaLoginShell(binaryName)
        if let found { UserDefaults.standard.set(found, forKey: pathCacheKey) }
        return found
    }

    static var isAvailable: Bool { locateBinary() != nil }

    /// The directory holding the binary — handed to codex as an extra PATH dir so its shell (and the
    /// `#!/usr/bin/env node` shim) can find `playwright-cli` + the co-located `node`.
    static var binDir: String? { locateBinary().map { ($0 as NSString).deletingLastPathComponent } }

    /// Tear down the detached daemon + any open browser. Best-effort; safe to call on every exit path.
    static func killAll() {
        guard let bin = locateBinary() else { return }
        _ = try? run(bin, ["kill-all"], timeout: 20)
    }

    // MARK: tiny blocking process runner (discovery + kill-all only)

    private static func whichViaLoginShell(_ name: String) -> String? {
        guard let out = try? run("/bin/zsh", ["-lic", "which \(name)"], timeout: 5) else { return nil }
        let fm = FileManager.default
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ binary: String, _ args: [String], timeout: TimeInterval) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        let binDir = (binary as NSString).deletingLastPathComponent
        var env: [String: String] = ["PATH": "\(binDir):/usr/bin:/bin:/usr/sbin:/sbin"]
        let current = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER"] where current[key] != nil { env[key] = current[key] }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()

        let watchdog = DispatchWorkItem { [weak proc] in proc?.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
