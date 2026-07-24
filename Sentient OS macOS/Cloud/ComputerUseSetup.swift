//
//  ComputerUseSetup.swift
//  Sentient OS macOS
//
//  Step 3 of Codex setup: make `codex` computer use work on a PLAIN Codex CLI — with NO desktop
//  app install. OpenAI ships the entire computer-use payload (the plugin + the native
//  "Codex Computer Use.app" helper) bundled INSIDE their desktop app (renamed Codex.app →
//  ChatGPT.app 2026-07, same DMG URL); the desktop "enable computer use" toggle is a local file
//  copy (reverse-engineered + proven byte-identical). So we reproduce it ourselves: download
//  OpenAI's official DMG, lift the bundled `openai-bundled` marketplace and the native helper
//  out of it, lay the three trees into ~/.codex, relax the confirmation policy
//  (ComputerUseSkillPatch), and patch config.toml.
//  Nothing is hosted by us — the bits come straight from OpenAI's CDN.
//
//  Since plugin 1.0.1000502 (2026-07) the CLI's route is PURE MCP: the plugin's `.mcp.json`
//  registers a `computer-use` MCP server whose launcher execs the installed helper's native
//  client — the tools (click, type_text, get_app_state, …) are served natively, no node runtime
//  involved. The node-repl skill variant that we used to swap in is the DESKTOP app's arm of the
//  runtime split (it spawns node out of its own bundle; the plain CLI can't), so the swap is gone:
//  the shipped policy-only SKILL.md is exactly right for the CLI.
//
//  Key entry points:
//   - ComputerUseSetup.isInstalled            → already bootstrapped? (plugin cache + native helper)
//   - ComputerUseSetup.install(onLine:)       → download → mount → ditto → patch → detach
//
//  Doc: Documentation/Computer-Use Bootstrap (Codex Reverse-Engineering).md
//

import Foundation

enum ComputerUseSetup {

    /// OpenAI's official desktop-app installer (public CDN, no auth; still named Codex.dmg after
    /// the app's rename to ChatGPT). The computer-use payload lives inside the app bundle at
    /// <app>/Contents/Resources/plugins/openai-bundled/.
    static let dmgURL = URL(string: "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg")!

    /// The mounted DMG's app + the bundled marketplace inside it. The app's name has changed once
    /// already (Codex.app → ChatGPT.app, 2026-07), so locate whatever .app sits at the DMG root
    /// and key on the payload's shape, never on the app's name.
    private static func payloadSource(inMount mount: URL) throws -> (app: URL, marketplace: URL) {
        let apps = ((try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        for app in apps {
            let candidate = app.appendingPathComponent("Contents/Resources/plugins/openai-bundled")
            if FileManager.default.fileExists(atPath: candidate.path) { return (app, candidate) }
        }
        throw SetupError.missingSource(apps.isEmpty ? "no .app in the DMG"
                                                    : "no openai-bundled marketplace in \(apps.map(\.lastPathComponent).joined(separator: ", "))")
    }

    /// The native "Codex Computer Use.app" helper inside the mounted app. It has lived in two
    /// places so far: inside the plugin folder itself (through plugin 1.0.1000366), then inside
    /// the bundled @oai/sky node module (1.0.1000502+, 2026-07) — try both shapes.
    private static func nativeHelper(app: URL, pluginSrc: URL) throws -> URL {
        let candidates = [pluginSrc.appendingPathComponent("Codex Computer Use.app"),
                          app.appendingPathComponent("Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app")]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return found }
        throw SetupError.missingSource("Codex Computer Use.app (looked in the plugin folder and cua_node/@oai/sky)")
    }

    enum SetupError: LocalizedError {
        case download(String), mount(String), missingSource(String), copy(String), config(String)
        var errorDescription: String? {
            switch self {
            case .download(let m):      return "Download failed: \(m)"
            case .mount(let m):         return "Couldn't mount the Codex installer: \(m)"
            case .missingSource(let m): return "Computer-use payload not found in the installer (\(m))."
            case .copy(let m):          return "Couldn't copy files into ~/.codex: \(m)"
            case .config(let m):        return "Couldn't patch config.toml: \(m)"
            }
        }
    }

    /// ~/.codex (the app runs as the user, so this is the real per-user Codex home).
    private static var codexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Already FULLY wired? All three must hold for computer use to actually work — so a half-finished
    /// copy or a config the user edited out reads as "not installed" and gets repaired on the next run
    /// (rather than a bare dir merely existing). NOT a version check: an older but working install
    /// still counts (use `force` to replace it). Also true if the real desktop app set it up.
    static var isInstalled: Bool {
        let fm = FileManager.default
        // 1) the native helper's actual Mach-O (not just the .app dir → catches a half-copy)
        let helperBin = codexHome.appendingPathComponent(
            "computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
        guard fm.fileExists(atPath: helperBin.path) else { return false }
        // 2) at least one installed plugin version carrying its manifest, the .mcp.json that
        //    registers the computer-use MCP server, and the launcher it points at. A
        //    node-repl-era install (pre-1.0.1000502, no .mcp.json) reads as "not installed" ON
        //    PURPOSE: its skill drives a node_repl tool current CLIs no longer have, so it
        //    self-migrates to the MCP payload on the next setup pass.
        let pluginRoot = codexHome.appendingPathComponent("plugins/cache/openai-bundled/computer-use")
        let hasPlugin = (try? fm.contentsOfDirectory(atPath: pluginRoot.path))?.contains {
            let root = pluginRoot.appendingPathComponent($0)
            return fm.fileExists(atPath: root.appendingPathComponent(".codex-plugin/plugin.json").path)
                && fm.fileExists(atPath: root.appendingPathComponent(".mcp.json").path)
                && fm.isExecutableFile(atPath: root.appendingPathComponent("bin/computer-use-client-launcher").path)
        } ?? false
        guard hasPlugin else { return false }
        // 3) config.toml actually enables the plugin
        let config = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        return config.contains("[plugins.\"computer-use@openai-bundled\"]")
    }

    // MARK: The bootstrap

    /// Download OpenAI's Codex.dmg, extract the bundled computer-use plugin + native helper +
    /// marketplace into ~/.codex, and patch config.toml. Idempotent (a no-op if already installed).
    /// Streams human-readable progress to `onLine` (same convention as install/login).
    static func install(force: Bool = false, onLine: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        if !force, isInstalled { onLine("✓ Computer use already set up"); return }

        let tmp = fm.temporaryDirectory
        let dmg = tmp.appendingPathComponent("SentientCodex.dmg")
        let mount = tmp.appendingPathComponent("sentient-codex-mnt-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: dmg) }

        // 1) Download (≈535 MB) straight from OpenAI's CDN, with % progress.
        onLine("Downloading Codex.dmg (~535 MB) from OpenAI…")
        do {
            try await Downloader(dest: dmg) { w, t in
                let mb = 1_048_576.0
                onLine(String(format: "Downloading… %.0f%% (%.0f / %.0f MB)",
                              Double(w) / Double(t) * 100, Double(w) / mb, Double(t) / mb))
            }.run(from: dmgURL)
        } catch { throw SetupError.download((error as? LocalizedError)?.errorDescription ?? "\(error)") }

        // 2) Mount read-only.
        onLine("Mounting installer…")
        try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await sh("/usr/bin/hdiutil",
                                  ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        guard attach.status == 0 else { throw SetupError.mount(attach.out.trimmedTail) }
        defer { detachQuietly(mount); try? fm.removeItem(at: mount) }

        // 3) Locate the payload + its version.
        let (app, src) = try payloadSource(inMount: mount)
        let pluginSrc = src.appendingPathComponent("plugins/computer-use")
        guard fm.fileExists(atPath: pluginSrc.path) else { throw SetupError.missingSource(pluginSrc.lastPathComponent) }
        let helperSrc = try nativeHelper(app: app, pluginSrc: pluginSrc)
        let version = try readVersion(pluginSrc.appendingPathComponent(".codex-plugin/plugin.json"))
        onLine("Found computer-use \(version); installing…")

        // 4) Lay down the three trees (ditto preserves the code signatures / xattrs).
        onLine("Copying marketplace…")
        try await dittoReplace(src, codexHome.appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled"))
        onLine("Copying plugin…")
        try await dittoReplace(pluginSrc, codexHome.appendingPathComponent("plugins/cache/openai-bundled/computer-use/\(version)"))
        onLine("Copying native helper…")
        try await dittoReplace(helperSrc, codexHome.appendingPathComponent("computer-use/Codex Computer Use.app"))

        // 5) Relax the skill's confirmation policy.
        ComputerUseSkillPatch.ensureApplied()

        // 6) Wire it up in config.toml (idempotent).
        onLine("Patching config.toml…")
        try patchConfig()

        guard isInstalled else { throw SetupError.copy("post-install check failed") }
        onLine("✓ Computer use ready")
    }

    // MARK: Steps

    /// Replace `dst` with a fresh copy of `src` via /usr/bin/ditto (signature/xattr-preserving;
    /// --noqtn matches the desktop app's own copy — no quarantine rides into ~/.codex).
    private static func dittoReplace(_ src: URL, _ dst: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try await sh("/usr/bin/ditto", ["--noqtn", src.path, dst.path])
        guard r.status == 0, fm.fileExists(atPath: dst.path) else {
            throw SetupError.copy("ditto \(src.lastPathComponent): \(r.out.trimmedTail)")
        }
    }

    /// Pull the plugin version (e.g. "1.0.1000502") out of the plugin's manifest — it names the cache dir.
    private static func readVersion(_ pluginJSON: URL) throws -> String {
        guard let data = try? Data(contentsOf: pluginJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else {
            throw SetupError.missingSource("plugin.json version")
        }
        return v
    }

    /// Add the three config blocks the desktop toggle writes, only if absent (idempotent). The
    /// top-level `notify` key must precede any [table], so it's prepended; the tables are appended.
    private static func patchConfig() throws {
        let url = codexHome.appendingPathComponent("config.toml")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        let client = codexHome.appendingPathComponent(
            "computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient").path
        let source = codexHome.appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled").path

        var prefix = "", suffix = ""
        if text.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) == nil {
            prefix = "notify = [\"\(tomlEscape(client))\", \"turn-ended\"]\n\n"
        }
        if !text.contains("[marketplaces.openai-bundled]") {
            suffix += "\n[marketplaces.openai-bundled]\nsource_type = \"local\"\nsource = \"\(tomlEscape(source))\"\n"
        }
        if !text.contains("[plugins.\"computer-use@openai-bundled\"]") {
            suffix += "\n[plugins.\"computer-use@openai-bundled\"]\nenabled = true\n"
        }
        guard !prefix.isEmpty || !suffix.isEmpty else { return }   // already wired

        text = prefix + text + suffix
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw SetupError.config("\(error)") }
    }

    // MARK: Process helpers

    /// Minimal async Process runner (combined stdout+stderr) for the local hdiutil/ditto steps —
    /// off-main via a global queue. Output is small and bounded, so a single drain is safe.
    @discardableResult
    private static func sh(_ launch: String, _ args: [String]) async throws -> (status: Int32, out: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launch)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() }
                catch { cont.resume(throwing: SetupError.copy("\(launch): \(error)")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Best-effort synchronous unmount for the defer cleanup path.
    private static func detachQuietly(_ mount: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", mount.path, "-force"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private static func tomlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Downloader

/// A tiny URLSession download wrapper that streams byte progress and bridges to async/await.
/// Moves the finished file to `dest` inside the delegate callback (the temp file is reaped right
/// after), and surfaces non-200 responses as errors.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var finishError: Error?
    private var lastPct = -1

    init(dest: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.dest = dest
        self.onProgress = onProgress
        super.init()
    }

    func run(from url: URL) async throws {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 1800      // 30 min ceiling for the whole transfer
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); cont = c; lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
        guard t > 0 else { return }
        let pct = Int(Double(w) / Double(t) * 100)
        if pct != lastPct, pct % 2 == 0 { lastPct = pct; onProgress(w, t) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finishError = ComputerUseSetup.SetupError.download("HTTP \(http.statusCode)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)   // must happen before this returns
        } catch { finishError = error }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        if let error { c?.resume(throwing: error) }
        else if let finishError { c?.resume(throwing: finishError) }
        else { c?.resume(returning: ()) }
    }
}

private extension String {
    /// Last non-empty line, for compact error surfacing from multi-line tool output.
    var trimmedTail: String {
        split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? self
    }
}
