//
//  ComputerUseSetup.swift
//  Sentient OS macOS
//
//  Step 3 of Codex setup: make `codex` computer use work on a PLAIN Codex CLI — with NO desktop
//  app install. Intel builds install Sentient's bundled x86_64 plugin locally. Apple Silicon
//  keeps the existing Sky path: OpenAI ships the entire computer-use payload (the plugin + native
//  "Codex Computer Use.app" helper) bundled INSIDE their desktop app (renamed Codex.app →
//  ChatGPT.app 2026-07, same DMG URL); the desktop "enable computer use" toggle is a local file
//  copy PLUS a skill-variant swap (reverse-engineered + proven byte-identical). So we reproduce
//  it ourselves: download OpenAI's official DMG, lift the bundled `openai-bundled` marketplace
//  out of it, lay the three trees into ~/.codex, select the node-repl skill variant, relax the
//  confirmation policy (ComputerUseSkillPatch), and patch config.toml.
//  Nothing is hosted by us — the bits come straight from OpenAI's CDN.
//
//  Key entry points:
//   - ComputerUseSetup.isInstalled            → already bootstrapped? (plugin cache + native helper)
//   - ComputerUseSetup.install(onLine:)       → route to bundled Intel or existing Sky installation
//
//  Doc: Documentation/Computer-Use Bootstrap (Codex Reverse-Engineering).md
//

import Foundation

enum ComputerUseSetup {

    private static let intelPluginVersion = "1.0.0"

    /// OpenAI's official desktop-app installer (public CDN, no auth; still named Codex.dmg after
    /// the app's rename to ChatGPT). The computer-use payload lives inside the app bundle at
    /// <app>/Contents/Resources/plugins/openai-bundled/.
    static let dmgURL = URL(string: "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg")!

    /// The bundled marketplace inside the mounted DMG's app. The app's name has changed once
    /// already (Codex.app → ChatGPT.app, 2026-07), so locate whatever .app sits at the DMG root
    /// and key on the payload's shape, never on the app's name.
    private static func marketplace(inMount mount: URL) throws -> URL {
        let apps = ((try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        for app in apps {
            let candidate = app.appendingPathComponent("Contents/Resources/plugins/openai-bundled")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw SetupError.missingSource(apps.isEmpty ? "no .app in the DMG"
                                                    : "no openai-bundled marketplace in \(apps.map(\.lastPathComponent).joined(separator: ", "))")
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

    private static var intelInstallRoot: URL {
        codexHome.appendingPathComponent("plugins/cache/sentient/computer-use/\(intelPluginVersion)")
    }

    private static var intelMarketplaceInstallRoot: URL {
        codexHome.appendingPathComponent(".tmp/marketplaces/sentient")
    }

    private static var skyNotifyClient: URL {
        codexHome.appendingPathComponent(
            "computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")
    }

    /// Already FULLY wired? All three must hold for computer use to actually work — so a half-finished
    /// copy or a config the user edited out reads as "not installed" and gets repaired on the next run
    /// (rather than a bare dir merely existing). NOT a version check: an older but working install
    /// still counts (use `force` to replace it). Also true if the real desktop app set it up.
    static var isInstalled: Bool {
        switch ComputerUseBackend.current {
        case .sky: isSkyInstalled
        case .sentientIntel: isIntelInstalled
        }
    }

    private static var isSkyPayloadInstalled: Bool {
        let fm = FileManager.default
        // 1) the native helper's actual Mach-O (not just the .app dir → catches a half-copy)
        let helperBin = codexHome.appendingPathComponent(
            "computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
        guard fm.fileExists(atPath: helperBin.path) else { return false }
        // 2) at least one installed plugin version carrying its manifest AND the node-repl skill
        //    (the runtime-bootstrap instructions codex needs — the DMG ships a policy-only stub
        //    SKILL.md, so a plain copy without install()'s variant swap is a broken half-install
        //    and must read as "not installed" so it gets repaired)
        let pluginRoot = codexHome.appendingPathComponent("plugins/cache/openai-bundled/computer-use")
        let hasPlugin = (try? fm.contentsOfDirectory(atPath: pluginRoot.path))?.contains {
            fm.fileExists(atPath: pluginRoot.appendingPathComponent("\($0)/.codex-plugin/plugin.json").path)
                && ((try? String(contentsOf: pluginRoot.appendingPathComponent("\($0)/skills/computer-use/SKILL.md"),
                                 encoding: .utf8))?.contains("setupComputerUseRuntime") ?? false)
        } ?? false
        guard hasPlugin else { return false }
        // 3) the local marketplace snapshot is present and still describes computer-use.
        let marketplaceManifest = codexHome.appendingPathComponent(
            ".tmp/bundled-marketplaces/openai-bundled/.agents/plugins/marketplace.json")
        guard let marketplaceData = try? Data(contentsOf: marketplaceManifest),
              let marketplace = try? JSONSerialization.jsonObject(with: marketplaceData) as? [String: Any],
              marketplace["name"] as? String == "openai-bundled",
              let plugins = marketplace["plugins"] as? [[String: Any]],
              plugins.contains(where: { $0["name"] as? String == "computer-use" }) else { return false }
        return true
    }

    private static var isSkyInstalled: Bool {
        guard isSkyPayloadInstalled else { return false }
        // 4) config.toml actually selects Sky exclusively.
        let config = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        return ComputerUsePluginConfig.hasExclusiveBackend(
            active: .sky, inactive: .sentientIntel, in: config)
    }

    private static var isIntelInstalled: Bool {
        guard hasValidIntelPlugin(at: intelInstallRoot),
              hasValidIntelMarketplace(at: intelMarketplaceInstallRoot) else { return false }

        let config = (try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        return ComputerUsePluginConfig.localMarketplaceSource(name: "sentient", in: config)
                == intelMarketplaceInstallRoot.path
            && !ComputerUsePluginConfig.hasOwnedSkyNotify(in: config, executable: skyNotifyClient.path)
            && ComputerUsePluginConfig.hasExclusiveBackend(
            active: .sentientIntel, inactive: .sky, in: config)
    }

    // MARK: The bootstrap

    /// Download OpenAI's Codex.dmg, extract the bundled computer-use plugin + native helper +
    /// marketplace into ~/.codex, and patch config.toml. Idempotent (a no-op if already installed).
    /// Streams human-readable progress to `onLine` (same convention as install/login).
    static func install(force: Bool = false, onLine: @escaping @Sendable (String) -> Void) async throws {
        switch ComputerUseBackend.current {
        case .sky:
            try await installSky(force: force, onLine: onLine)
        case .sentientIntel:
            try await installIntel(force: force, onLine: onLine)
        }
    }

    private static func installSky(force: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        let coordinator = ComputerUseSkyInstallCoordinator(
            payloadIsValid: { isSkyPayloadInstalled },
            isReady: { isSkyInstalled },
            patchConfig: { try patchConfig() },
            performFullInstall: { try await performFullSkyInstall(onLine: onLine) }
        )
        let outcome = try await coordinator.install(force: force)
        switch outcome {
        case .alreadyReady:
            onLine("✓ Computer use already set up")
        case .configOnly:
            onLine("✓ Computer use config repaired")
        case .fullInstall:
            break
        }
    }

    private static func performFullSkyInstall(onLine: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
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
        let src = try marketplace(inMount: mount)
        let pluginSrc = src.appendingPathComponent("plugins/computer-use")
        guard fm.fileExists(atPath: pluginSrc.path) else { throw SetupError.missingSource(pluginSrc.lastPathComponent) }
        let version = try readVersion(pluginSrc.appendingPathComponent(".codex-plugin/plugin.json"))
        onLine("Found computer-use \(version); installing…")

        // 4) Lay down the three trees (ditto preserves the code signatures / xattrs).
        onLine("Copying marketplace…")
        try await dittoReplace(src, codexHome.appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled"))
        onLine("Copying plugin…")
        try await dittoReplace(pluginSrc, codexHome.appendingPathComponent("plugins/cache/openai-bundled/computer-use/\(version)"))
        onLine("Copying native helper…")
        try await dittoReplace(pluginSrc.appendingPathComponent("Codex Computer Use.app"),
                               codexHome.appendingPathComponent("computer-use/Codex Computer Use.app"))

        // 5) Select the node-repl skill variant, then relax its confirmation policy.
        onLine("Selecting the node-repl skill variant…")
        try selectNodeReplVariant(version: version)
        ComputerUseSkillPatch.ensureApplied()

        // 6) Wire it up in config.toml (idempotent).
        onLine("Patching config.toml…")
        try patchConfig()

        guard isSkyInstalled else { throw SetupError.copy("post-install check failed") }
        onLine("✓ Computer use ready")
    }

    /// Intel never downloads, launches, or copies Sky. Its complete plugin tree is signed inside
    /// Sentient's app bundle, validated before and after copy, then enabled in the user's config.
    private static func installIntel(force: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        if !force, isIntelInstalled { onLine("✓ Computer use already set up"); return }

        guard let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("IntelComputerUse", isDirectory: true),
              FileManager.default.fileExists(atPath: bundledRoot.path) else {
            throw SetupError.missingSource("bundled IntelComputerUse")
        }

        let bundledPluginRoot = bundledRoot.appendingPathComponent("plugins/computer-use")
        onLine("Validating bundled Intel computer use…")
        try validateIntelMarketplace(at: bundledRoot)

        onLine("Installing Intel marketplace…")
        try await dittoReplace(bundledRoot, intelMarketplaceInstallRoot)
        onLine("Installing Intel plugin…")
        try await dittoReplace(bundledPluginRoot, intelInstallRoot)
        try validateIntelMarketplace(at: intelMarketplaceInstallRoot)
        try validateIntelPlugin(at: intelInstallRoot)

        onLine("Patching config.toml…")
        try patchIntelConfig()

        guard isIntelInstalled else { throw SetupError.copy("Intel post-install check failed") }
        onLine("✓ Computer use ready")
    }

    // MARK: Steps

    /// Replace `dst` with a fresh copy of `src` via /usr/bin/ditto (signature/xattr-preserving).
    private static func dittoReplace(_ src: URL, _ dst: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try await sh("/usr/bin/ditto", [src.path, dst.path])
        guard r.status == 0, fm.fileExists(atPath: dst.path) else {
            throw SetupError.copy("ditto \(src.lastPathComponent): \(r.out.trimmedTail)")
        }
    }

    /// The desktop app's "enable" flow doesn't just copy the plugin — it selects a skill VARIANT:
    /// the shipped `skills/computer-use/SKILL.md` is a policy-only stub, and the real CLI skill
    /// (node_repl runtime bootstrap + API docs + policy) sits beside the manifest as
    /// `.codex-plugin/computer-use-node-repl.md`. Without the swap, codex has no idea how to start
    /// the runtime and flails. Reproduce it in both installed trees and stamp
    /// `bundledContentVariant` into both plugin.json copies — byte-matching the desktop app's own
    /// output (verified against a real desktop-app install, 2026-07-09). A payload without the
    /// variant file predates the mechanism and is complete as shipped → no-op.
    private static func selectNodeReplVariant(version: String) throws {
        let roots = [codexHome.appendingPathComponent("plugins/cache/openai-bundled/computer-use/\(version)"),
                     codexHome.appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled/plugins/computer-use")]
        guard let variant = try? String(contentsOf: roots[0].appendingPathComponent(".codex-plugin/computer-use-node-repl.md"),
                                        encoding: .utf8) else { return }
        for root in roots {
            do {
                try variant.write(to: root.appendingPathComponent("skills/computer-use/SKILL.md"),
                                  atomically: true, encoding: .utf8)
                let manifest = root.appendingPathComponent(".codex-plugin/plugin.json")
                guard var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] else {
                    throw SetupError.copy("plugin.json isn't an object")
                }
                obj["bundledContentVariant"] = "node-repl"
                try (try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
                    .write(to: manifest, options: .atomic)
            } catch { throw SetupError.copy("variant swap in \(root.lastPathComponent): \(error)") }
        }
    }

    /// Pull the plugin version (e.g. "1.0.857") out of the plugin's manifest — it names the cache dir.
    private static func readVersion(_ pluginJSON: URL) throws -> String {
        guard let data = try? Data(contentsOf: pluginJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, !v.isEmpty else {
            throw SetupError.missingSource("plugin.json version")
        }
        return v
    }

    private static let intelExecutableNames = ["SentientComputerUseMCP", "SentientComputerUseService"]

    private static func hasValidIntelExecutables(in root: URL) -> Bool {
        intelExecutableNames.allSatisfy { name in
            let executable = root.appendingPathComponent("bin/\(name)")
            return FileManager.default.isExecutableFile(atPath: executable.path)
                && validationTool("/usr/bin/lipo", ["-archs", executable.path]).output
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64"
                && validationTool("/usr/bin/codesign", ["--verify", "--strict", executable.path]).status == 0
        }
    }

    private static func hasValidIntelPlugin(at root: URL) -> Bool {
        do { try validateIntelPlugin(at: root); return true }
        catch { return false }
    }

    private static func hasValidIntelMarketplace(at root: URL) -> Bool {
        do { try validateIntelMarketplace(at: root); return true }
        catch { return false }
    }

    private static func intelMCPConfiguration(at root: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(".mcp.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any],
              let computerUse = servers["computer-use"] as? [String: Any] else { return nil }
        return computerUse
    }

    private static func validateIntelPlugin(at root: URL) throws {
        let fm = FileManager.default
        let pluginManifest = root.appendingPathComponent(".codex-plugin/plugin.json")
        guard let manifestData = try? Data(contentsOf: pluginManifest),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              manifest["name"] as? String == "computer-use",
              manifest["version"] as? String == intelPluginVersion,
              manifest["mcpServers"] as? String == "./.mcp.json",
              manifest["skills"] as? String == "./skills/",
              fm.fileExists(atPath: root.appendingPathComponent("skills/computer-use/SKILL.md").path) else {
            throw SetupError.missingSource("Intel plugin metadata")
        }
        guard let mcp = intelMCPConfiguration(at: root),
              mcp.count == 2,
              mcp["command"] as? String == "./bin/SentientComputerUseMCP",
              mcp["cwd"] as? String == "." else {
            throw SetupError.missingSource("Intel .mcp.json route")
        }
        guard hasValidIntelExecutables(in: root) else {
            throw SetupError.copy("Intel executables are missing, not executable, or not x86_64-only")
        }

        let metadataFiles = [".mcp.json", ".codex-plugin/plugin.json", "skills/computer-use/SKILL.md"]
        for relativePath in metadataFiles {
            let text = (try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
            guard !text.contains("SkyComputerUseService") else {
                throw SetupError.copy("Intel plugin references SkyComputerUseService in \(relativePath)")
            }
        }
    }

    private static func validateIntelMarketplace(at root: URL) throws {
        let manifestURL = root.appendingPathComponent(".agents/plugins/marketplace.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] as? String == "sentient",
              let plugins = object["plugins"] as? [[String: Any]], plugins.count == 1,
              plugins[0]["name"] as? String == "computer-use",
              let source = plugins[0]["source"] as? [String: Any], source.count == 2,
              source["source"] as? String == "local",
              source["path"] as? String == "./plugins/computer-use",
              let policy = plugins[0]["policy"] as? [String: Any],
              policy["installation"] as? String == "AVAILABLE" else {
            throw SetupError.missingSource("Sentient marketplace manifest")
        }
        try validateIntelPlugin(at: root.appendingPathComponent("plugins/computer-use"))
    }

    private static func validationTool(_ launch: String, _ arguments: [String])
        -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Enable Sentient's Intel plugin in-place and explicitly disable OpenAI's plugin.
    /// exists. Existing tables are edited; duplicate tables/keys are rejected instead of emitting
    /// invalid TOML. Re-running this function produces byte-identical output.
    private static func patchIntelConfig() throws {
        let url = codexHome.appendingPathComponent("config.toml")
        let original: String
        if FileManager.default.fileExists(atPath: url.path) {
            do { original = try String(contentsOf: url, encoding: .utf8) }
            catch { throw SetupError.config("couldn't read existing config: \(error)") }
        } else {
            original = ""
        }
        let updated: String
        do {
            let withoutSkyNotify = try ComputerUsePluginConfig.removingOwnedSkyNotify(
                from: original, executable: skyNotifyClient.path)
            let withoutLegacySkyMCP = try ComputerUsePluginConfig.removingOwnedLegacySkyMCPServer(
                from: withoutSkyNotify, executable: skyNotifyClient.path)
            let withMarketplace = try ComputerUsePluginConfig.settingLocalMarketplace(
                name: "sentient", source: intelMarketplaceInstallRoot.path, in: withoutLegacySkyMCP)
            let withIntel = try ComputerUsePluginConfig.settingEnabled(
                true, for: .sentientIntel, in: withMarketplace, createIfMissing: true)
            updated = try ComputerUsePluginConfig.settingEnabled(
                false, for: .sky, in: withIntel, createIfMissing: true)
        } catch {
            throw SetupError.config((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard updated != original else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError.config("\(error)")
        }
    }

    /// Add the three config blocks the desktop toggle writes, only if absent (idempotent). The
    /// top-level `notify` key must precede any [table], so it's prepended; the tables are appended.
    private static func patchConfig() throws {
        let url = codexHome.appendingPathComponent("config.toml")
        let original: String
        if FileManager.default.fileExists(atPath: url.path) {
            do { original = try String(contentsOf: url, encoding: .utf8) }
            catch { throw SetupError.config("couldn't read existing config: \(error)") }
        } else {
            original = ""
        }
        var text = original

        let client = skyNotifyClient.path
        let source = codexHome.appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled").path

        var prefix = "", suffix = ""
        if text.range(of: #"(?m)^\s*notify\s*="#, options: .regularExpression) == nil {
            prefix = "notify = [\"\(tomlEscape(client))\", \"turn-ended\"]\n\n"
        }
        if !text.contains("[marketplaces.openai-bundled]") {
            suffix += "\n[marketplaces.openai-bundled]\nsource_type = \"local\"\nsource = \"\(tomlEscape(source))\"\n"
        }
        text = prefix + text + suffix
        do {
            text = try ComputerUsePluginConfig.settingEnabled(
                true, for: .sky, in: text, createIfMissing: true)
            text = try ComputerUsePluginConfig.settingEnabled(
                false, for: .sentientIntel, in: text, createIfMissing: true)
        } catch {
            throw SetupError.config((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        guard text != original else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch { throw SetupError.config("\(error)") }
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
