// Installs only OpenAI's signed computer-use helper from its official desktop installer.
// Stages and validates the complete bundle before an atomic swap; never edits Codex config/login.
// Doc: Driver/Documentation - Native Computer Use.md

import AppKit
import Darwin
import Foundation

enum OpenAIComputerUseSetup {
    static let downloadURL = URL(string: "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg")!
    private static var receiptURL: URL { URL.sentientSupport.appendingPathComponent("native-computer-use.json") }

    struct Receipt: Codable, Sendable {
        let version: String
        let build: Int
        let installedAt: Date
        let appPath: String
        let createdBySentient: Bool
    }

    static var hasInstallationHistory: Bool {
        OpenAIComputerUse.isInstalled || FileManager.default.fileExists(atPath: receiptURL.path)
    }

    enum SetupError: LocalizedError {
        case installer(String), missingPayload, installationBusy, publication
        var errorDescription: String? {
            switch self {
            case .installer(let stage): "OpenAI computer-use setup could not finish \(stage). Try again."
            case .missingPayload: "This OpenAI installer does not contain a compatible computer-use helper. Your existing setup was preserved."
            case .installationBusy: "Computer-use setup is already running in another Sentient window. Try again shortly."
            case .publication: "The computer-use helper could not be installed. Your previous installation was preserved."
            }
        }
    }

    static func install(force: Bool = false, receipt: URL? = nil, sourceURL: URL? = nil,
                        onProgress: @escaping @MainActor @Sendable (ComputerUseSetup.Progress) -> Void,
                        onLine: @escaping @Sendable (String) -> Void) async throws {
        if !force, (try? await OpenAIComputerUse.validate(at: OpenAIComputerUse.appURL)) != nil {
            onLine("✓ OpenAI computer use is ready")
            onProgress(.ready)
            return
        }
        try Task.checkCancellation()
        let fm = FileManager.default
        let receiptURL = receipt ?? Self.receiptURL
        let destination = OpenAIComputerUse.appURL
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Serialize our own app instances as well as callers inside a single process.
        let lock = open(parent.appendingPathComponent(".sentient-install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw SetupError.publication }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SetupError.installationBusy }

        let before = fingerprint(destination)
        let existed = fm.fileExists(atPath: destination.path)
        let staging = parent.appendingPathComponent(".sentient-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var preserveStaging = false
        defer { if !preserveStaging { try? fm.removeItem(at: staging) } }
        let dmg = staging.appendingPathComponent("OpenAI.dmg")
        let mount = staging.appendingPathComponent("mount", isDirectory: true)
        let candidate = staging.appendingPathComponent("Codex Computer Use.app", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)

        onLine("Downloading computer use from OpenAI…")
        onProgress(.downloading(nil))
        try await DependencyDownload.run(sourceURL ?? downloadURL, to: dmg, timeout: 1_800) { fraction in
            Task { @MainActor in onProgress(.downloading(fraction)) }
        }
        try Task.checkCancellation()
        onLine("Preparing computer use…")
        onProgress(.unpacking)
        // hdiutil verifies the disk image checksum while mounting. Do not disable that check.
        // Both the download and all extracted executable code are subsequently verified.
        do {
            try await command("/usr/bin/hdiutil",
                ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path], stage: "opening the installer", timeout: 120)
            let source = try payload(in: mount)
            onProgress(.checkingSignature)
            try await OpenAIComputerUse.validate(at: source)
            try await command("/usr/bin/ditto", [source.path, candidate.path], stage: "copying the helper", timeout: 120)
        } catch {
            preserveStaging = await !detach(mount)
            throw error
        }
        guard await detach(mount) else {
            preserveStaging = true
            throw SetupError.installer("closing the installer")
        }
        let incoming = try await OpenAIComputerUse.validate(at: candidate)
        try Task.checkCancellation()

        // Reuse a newer verified desktop installation. The public DMG may lag the desktop updater.
        let current = try? await OpenAIComputerUse.validate(at: destination)
        try Task.checkCancellation()
        if let current, current.build > incoming.build {
            onLine("✓ A newer OpenAI computer-use helper is already installed")
            onProgress(.ready)
            return
        }
        guard fingerprint(destination) == before else { throw OpenAIComputerUse.RuntimeError.changedInstallation }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID).isEmpty else {
            throw OpenAIComputerUse.RuntimeError.helperRunning
        }
        onLine("Finishing computer-use setup…")
        onProgress(.installing)
        try publish(candidate: candidate, destination: destination, replacing: existed)
        // After a swap the old complete bundle is still at candidate, so a validation failure
        // can restore it without any window where the working destination disappears.
        do {
            _ = try await OpenAIComputerUse.validate(at: destination)
        } catch {
            if existed {
                do { try publish(candidate: candidate, destination: destination, replacing: true) }
                catch {
                    // Never delete the only remaining copy of the previous working bundle.
                    preserveStaging = true
                    Log("OpenAIComputerUseSetup: previous helper preserved in installation staging")
                }
            } else { try? fm.removeItem(at: destination) }
            throw error
        }
        let previous = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) }
        let owned = previous?.appPath == destination.path && previous?.createdBySentient == true
        let installationReceipt = Receipt(version: incoming.version, build: incoming.build, installedAt: Date(),
            appPath: destination.path, createdBySentient: !existed || owned)
        do {
            try fm.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(installationReceipt).write(to: receiptURL, options: .atomic)
        } catch { Log("OpenAIComputerUseSetup: helper verified; receipt unavailable (\(ErrorLabel(error)))") }
        onProgress(.ready)
        onLine("✓ OpenAI computer use is ready")
    }

    /// Recognize the payload by structure, not the desktop app's changing display name.
    static func payload(in mount: URL) throws -> URL {
        let apps = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        let paths = [
            "Contents/Resources/cua_node/lib/node_modules/@oai/sky/Codex Computer Use.app",
            "Contents/Resources/plugins/openai-bundled/plugins/computer-use/Codex Computer Use.app"
        ]
        for app in apps {
            for path in paths {
                let candidate = app.appendingPathComponent(path)
                if OpenAIComputerUse.installation(at: candidate) != nil { return candidate }
            }
        }
        throw SetupError.missingPayload
    }

    /// Both paths are on the same volume. Exchange keeps the previous directory intact until
    /// verification finishes; EXCL refuses to overwrite an installation created concurrently.
    static func publish(candidate: URL, destination: URL, replacing: Bool) throws {
        guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw SetupError.publication
        }
        let flags = replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw SetupError.publication
        }
    }

    private static func fingerprint(_ app: URL) -> String? {
        guard let values = try? app.resourceValues(forKeys: [.fileResourceIdentifierKey, .contentModificationDateKey]) else { return nil }
        let installation = OpenAIComputerUse.installation(at: app)
        return "\(String(describing: values.fileResourceIdentifier))|\(String(describing: values.contentModificationDate))|\(installation?.build ?? 0)"
    }

    private static func command(_ binary: String, _ arguments: [String], stage: String, timeout: TimeInterval) async throws {
        let result = try await CodexCLI.executeAsync(binary: binary, args: arguments,
            stdinText: nil, cwd: nil, timeout: timeout)
        guard result.status == 0 else { throw SetupError.installer(stage) }
    }

    /// Unmount even when the installer was canceled. The detached cleanup has its own deadline.
    private static func detach(_ mount: URL) async -> Bool {
        let mountPath = mount.resolvingSymlinksInPath().path
        return await Task.detached {
            for arguments in [["detach", mountPath], ["detach", mountPath, "-force"]] {
                if let result = try? await CodexCLI.executeAsync(binary: "/usr/bin/hdiutil",
                    args: arguments, stdinText: nil, cwd: nil, timeout: 20), result.status == 0 { return true }
                // An attach can fail before a volume exists. Distinguish that harmless case
                // from a still-mounted image before removing the download's staging directory.
                if let result = try? await CodexCLI.executeAsync(binary: "/usr/bin/hdiutil",
                    args: ["info", "-plist"], stdinText: nil, cwd: nil, timeout: 10), result.status == 0,
                   let data = result.stdout.data(using: .utf8),
                   let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                   let images = info["images"] as? [[String: Any]] {
                    let mounted = images.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
                        .compactMap { $0["mount-point"] as? String }
                        .contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == mount.resolvingSymlinksInPath() }
                    if !mounted { return true }
                }
            }
            return false
        }.value
    }
}
