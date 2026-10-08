// Downloads and verifies approved runtime archives, then publishes complete directories atomically.
// Mutable Codex state is never included in a software replacement or rollback.
// Doc: Cloud/Documentation - Cloud - Codex Setup.md

import AppKit
import Darwin
import Foundation

nonisolated enum CodexRuntimeInstall {
    enum Component: String, Codable, Sendable { case cli, helper }
    struct Receipt: Codable {
        struct Entry: Codable {
            let version: String
            let archiveSHA256: String
            let installedAt: Date
        }
        var components: [String: Entry] = [:]
    }

    @concurrent static func install(_ component: Component, force: Bool = false,
                        onLine: @escaping @Sendable (String) -> Void) async throws {
        #if !arch(arm64)
        throw CodexRuntime.Failure.unsupported
        #else
        try CodexRuntime.prepareHome()
        let artifact = component == .cli ? CodexRuntime.release.cli : CodexRuntime.release.helper
        let destination = component == .cli ? CodexRuntime.cliDirectory : CodexRuntime.helper
        let fm = FileManager.default
        let installLock = try CodexRuntime.FileLock(CodexRuntime.root.appendingPathComponent(".\(component.rawValue)-install.lock"), exclusive: true)
        defer { installLock.unlock() }
        if !force, (try? CodexRuntime.verify(artifact, at: destination)) != nil {
            try await validate(component, at: destination)
            onLine("✓ \(component == .cli ? "Codex" : "Computer use") is ready")
            return
        }
        let required = artifact.bytes + artifact.files.reduce(Int64(0)) { $0 + $1.bytes } + 100_000_000
        if let available = try? CodexRuntime.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < required { throw CodexRuntime.Failure.diskSpace }
        let archive = CodexRuntime.downloads.appendingPathComponent(artifact.filename)
        let resume = CodexRuntime.downloads.appendingPathComponent(artifact.filename + ".resume")
        let staging = CodexRuntime.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try CodexRuntime.directory(staging)
        var preserveStaging = false
        defer { if !preserveStaging { try? fm.removeItem(at: staging) } }
        let candidate = component == .cli ? staging.appendingPathComponent("payload")
            : staging.appendingPathComponent("payload/Codex Computer Use.app")
        let unpack = staging.appendingPathComponent("payload")
        if (try? CodexRuntime.sha256(archive)) != artifact.sha256 {
            try? fm.removeItem(at: archive)
            onLine("Downloading \(component == .cli ? "Codex" : "computer use")…")
            if artifact.url.isFileURL {
                try fm.copyItem(at: artifact.url, to: archive)
            } else {
                try await DependencyDownload.run(artifact.url, to: archive, timeout: 1_800, resumeDataURL: resume) { fraction in
                    if let fraction { onLine("Downloading \(component == .cli ? "Codex" : "computer use")… \(Int(fraction * 100))%") }
                }
            }
        }
        try Task.checkCancellation()
        onLine("Verifying download…")
        guard (try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.int64Value == artifact.bytes,
              try CodexRuntime.sha256(archive) == artifact.sha256 else {
            try? fm.removeItem(at: archive); try? fm.removeItem(at: resume)
            throw CodexRuntime.Failure.invalidPackage
        }
        try CodexRuntime.directory(unpack)
        onLine("Preparing \(component == .cli ? "Codex" : "computer use")…")
        // These approved archives contain only regular files and directories. Check both names
        // and types before extraction; never allow absolute paths, links or special devices.
        let listing = try await command("/usr/bin/tar", ["-tf", archive.path])
        guard safeEntries(listing.stdout) else { throw CodexRuntime.Failure.invalidPackage }
        let types = try await command("/usr/bin/tar", ["-tvf", archive.path])
        guard types.stdout.split(separator: "\n").allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw CodexRuntime.Failure.invalidPackage
        }
        _ = try await command("/usr/bin/tar", ["-xf", archive.path, "-C", unpack.path, "--no-same-owner"])
        try CodexRuntime.verify(artifact, at: candidate)
        try await validate(component, at: candidate)
        try Task.checkCancellation()

        // The same lock is held shared by live CLI/login/app-server processes. No installation
        // can replace either dependency during a task, including from another Sentient process.
        let runtimeLock = try CodexRuntime.FileLock(CodexRuntime.root.appendingPathComponent(".runtime.lock"), exclusive: true)
        defer { runtimeLock.unlock() }
        if component == .helper {
            let running = await MainActor.run {
                NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID).contains {
                    $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
                        || $0.bundleURL?.standardizedFileURL == candidate.standardizedFileURL
                }
            }
            guard !running else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        }
        let existed = fm.fileExists(atPath: destination.path)
        onLine("Finishing setup…")
        try publish(candidate: candidate, destination: destination, replacing: existed)
        do {
            try CodexRuntime.verify(artifact, at: destination)
            var receipt = (try? Data(contentsOf: CodexRuntime.receipt))
                .flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) } ?? Receipt()
            receipt.components[component.rawValue] = .init(version: artifact.version, archiveSHA256: artifact.sha256, installedAt: Date())
            try JSONEncoder().encode(receipt).write(to: CodexRuntime.receipt, options: .atomic)
        } catch {
            if existed {
                do { try publish(candidate: candidate, destination: destination, replacing: true) }
                catch { preserveStaging = true }
            } else { try? fm.removeItem(at: destination) }
            throw error
        }
        try? fm.removeItem(at: archive)
        try? fm.removeItem(at: resume)
        onLine("✓ \(component == .cli ? "Codex" : "Computer use") is ready")
        #endif
    }

    static func safeEntries(_ listing: String) -> Bool {
        let entries = listing.split(separator: "\n", omittingEmptySubsequences: true)
        return !entries.isEmpty && entries.allSatisfy { entry in
            !entry.hasPrefix("/") && !entry.contains("\\")
                && !entry.split(separator: "/").contains("..")
                && !entry.contains("\r") && !entry.contains("\0")
        }
    }

    static func publish(candidate: URL, destination: URL, replacing: Bool) throws {
        guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw CodexRuntime.Failure.invalidPackage
        }
        let flags = replacing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, destination.path, flags) == 0 else {
            throw CodexRuntime.Failure.installation
        }
    }

    private static func validate(_ component: Component, at directory: URL) async throws {
        switch component {
        case .cli:
            let binary = directory.appendingPathComponent("bin/codex").path
            guard await CodexCLI.installedVersion(binary: binary) == CodexRuntime.release.cli.version,
                  await CodexCLI.isRunnable(binary: binary) else { throw CodexRuntime.Failure.invalidPackage }
        case .helper:
            _ = try await OpenAIComputerUse.validate(at: directory)
        }
    }

    private static func command(_ binary: String, _ args: [String]) async throws -> CodexCLI.ExecResult {
        let result = try await CodexCLI.executeAsync(binary: binary, args: args, stdinText: nil, cwd: nil, timeout: 120)
        guard result.status == 0 else { throw CodexRuntime.Failure.invalidPackage }
        return result
    }
}
