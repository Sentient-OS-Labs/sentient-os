// Quietly migrates an existing user's Codex home into Sentient, with an atomic cutover.
// Keeps one shared login file through a compatibility link; snapshots active SQLite databases.
// Doc: Cloud/Documentation - Cloud - Codex Setup.md

import AppKit
import CryptoKit
import Security
import Darwin
import Foundation
import os
import SQLite3

nonisolated enum CodexRuntimeMigration {
    private struct Routing { var enabled = false; var binary: String? }
    private static let routing = OSAllocatedUnfairLock(initialState: Routing())
    @MainActor private static var attempt: Task<Bool, Never>?
    @MainActor private static var retryTask: Task<Void, Never>?
    @MainActor private static var stopped = false

    static var legacyHome: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SENTIENT_CODEX_MIGRATION_SOURCE"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    static var legacyHelper: URL { legacyHome.appendingPathComponent("computer-use/Codex Computer Use.app") }
    private static var marker: URL { CodexRuntime.root.appendingPathComponent("state-migration.json") }
    private static var started: URL { CodexRuntime.root.appendingPathComponent(".migration-started") }
    static var completed: Bool { FileManager.default.fileExists(atPath: marker.path) }
    static var isPending: Bool { routing.withLock { $0.enabled } && !completed }
    static var legacyBinary: String? { routing.withLock { $0.binary } }

    /// Called before startup health/upgrade checks. No observable setup state, window or login flow.
    @MainActor static func start(existingUser: Bool) {
        guard existingUser, !stopped, retryTask == nil, !completed else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyHome.path),
              !fm.fileExists(atPath: CodexRuntime.auth.path) || fm.fileExists(atPath: started.path) else { return }
        var candidates = [legacyHome.appendingPathComponent("packages/standalone/current/bin/codex").path]
        #if DEBUG
        let isolated = ProcessInfo.processInfo.environment["SENTIENT_CODEX_MIGRATION_SOURCE"] != nil
        #else
        let isolated = false
        #endif
        if !isolated {
            candidates.append(NSHomeDirectory() + "/.local/bin/codex")
            if let cached = UserDefaults.standard.string(forKey: "codexcli.binaryPath") { candidates.append(cached) }
            candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            let nvm = NSHomeDirectory() + "/.nvm/versions/node"
            if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
                candidates += versions.sorted(by: >).map { nvm + "/" + $0 + "/bin/codex" }
            }
        }
        let binary = candidates.first(where: fm.isExecutableFile(atPath:))
        routing.withLock { $0 = Routing(enabled: true, binary: binary) }
        retryTask = Task {
            defer { retryTask = nil }
            while !Task.isCancelled, isPending {
                if await finishCurrentAttempt() { break }
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
    }

    @MainActor static func finishCurrentAttempt() async -> Bool {
        guard !stopped else { return false }
        guard isPending else { return true }
        if let attempt { return await attempt.value }
        let task = Task {
            do {
                try await migrate()
                await CodexSetup.shared.refreshInstalled()
                await CodexSetup.shared.refreshLoginStatus()
                ComputerUseSetup.current.refresh()
                Log("Codex migration: local cutover complete")
                return true
            } catch {
                // Paths, account details and token contents never enter migration diagnostics.
                if !Task.isCancelled { Log("Codex migration: deferred; original installation remains available") }
                return false
            }
        }
        attempt = task
        defer { attempt = nil }
        return await task.value
    }

    @MainActor static func cancel() async {
        stopped = true
        retryTask?.cancel(); attempt?.cancel()
        _ = await attempt?.value
        _ = await retryTask?.value
    }

    @concurrent private static func migrate() async throws {
        try CodexRuntime.prepareHome()
        let migrationLock = try CodexRuntime.FileLock(CodexRuntime.root.appendingPathComponent(".migration.lock"), exclusive: true)
        defer { migrationLock.unlock() }
        guard !completed else { return }
        try Data().write(to: started, options: .atomic)
        try requireNoKeychainLogin()
        try await CodexRuntimeInstall.install(.cli) { _ in }
        try await CodexRuntimeInstall.install(.helper) { _ in }
        // Keep an older running helper usable until it exits naturally. Never terminate another
        // app's computer-use task or open a repair window to finish this migration.
        let runningHelpers = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID).map(\.bundleURL)
        }
        let canSwitch = runningHelpers.allSatisfy { url in
            guard let url else { return false }
            return url.resolvingSymlinksInPath() == CodexRuntime.helper.resolvingSymlinksInPath()
                || (url.resolvingSymlinksInPath() == legacyHelper.resolvingSymlinksInPath()
                    && (try? CodexRuntime.verify(CodexRuntime.release.helper, at: url)) != nil)
        }
        guard canSwitch else { throw CodexRuntime.Failure.busy }
        let lease = try CodexRuntime.FileLock(CodexRuntime.root.appendingPathComponent(".runtime.lock"), exclusive: true)
        defer { lease.unlock() }
        let fm = FileManager.default
        let sourceAuth = legacyHome.appendingPathComponent("auth.json")
        // A crash after the auth bridge means the complete home already moved. Finalize it
        // in place so any pre-existing open credential handle keeps its original inode.
        if sourceAuth.resolvingSymlinksInPath() == CodexRuntime.auth.resolvingSymlinksInPath() {
            _ = try loginStatus(home: CodexRuntime.home)
            try completeMigration()
            return
        }
        let candidate = CodexRuntime.root.appendingPathComponent(".home-migration-\(UUID().uuidString)")
        try CodexRuntime.directory(candidate)
        var preserveCandidate = false
        defer { if !preserveCandidate { try? fm.removeItem(at: candidate) } }
        try copyState(from: legacyHome, to: candidate)
        let helperParent = candidate.appendingPathComponent("computer-use")
        try CodexRuntime.directory(helperParent)
        try fm.copyItem(at: CodexRuntime.helper, to: helperParent.appendingPathComponent("Codex Computer Use.app"))
        try Task.checkCancellation()
        let copiedAuth = candidate.appendingPathComponent("auth.json")
        let hasAuth = fm.fileExists(atPath: sourceAuth.path)
        var sourceIdentity: String?
        var sourceStatus: Int32?
        if hasAuth {
            try copyAuth(from: sourceAuth, to: copiedAuth)
            sourceIdentity = CodexRuntime.identity(at: copiedAuth)
            sourceStatus = try loginStatus(home: legacyHome, binary: legacyBinary)
            guard try loginStatus(home: candidate) == sourceStatus else { throw CodexRuntime.Failure.invalidPackage }
        }
        try Task.checkCancellation()
        try CodexRuntimeInstall.publish(candidate: candidate, destination: CodexRuntime.home, replacing: true)
        do {
            if let sourceStatus { try bridgeAuthentication(from: sourceAuth, expectedStatus: sourceStatus) }
            // The copied cache belongs to the same login. Do not discard it as a new account.
            if let identity = sourceIdentity {
                try identity.write(to: CodexRuntime.home.appendingPathComponent(".sentient-connector-account"), atomically: true, encoding: .utf8)
            }
            try completeMigration()
        } catch {
            // Restore the original auth path before rolling back its linked target directory.
            do {
                try restoreLegacyAuthentication()
                try CodexRuntimeInstall.publish(candidate: candidate, destination: CodexRuntime.home, replacing: true)
            } catch { preserveCandidate = true }
            throw error
        }
    }

    private static func completeMigration() throws {
        if FileManager.default.fileExists(atPath: CodexRuntime.auth.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CodexRuntime.auth.path)
        }
        try Task.checkCancellation()
        try Data(#"{"version":1,"localOnly":true}"#.utf8).write(to: marker, options: .atomic)
        try? FileManager.default.removeItem(at: started)
    }

    private static func copyState(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let omitted: Set<String> = ["auth.json", "packages", "computer-use", "tmp", "log", "shell_snapshots",
                                    "mcp-oauth-locks", "thread-writer-locks", "models_cache.json"]
        for entry in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            let name = entry.lastPathComponent
            guard !omitted.contains(name), !name.hasSuffix("-wal"), !name.hasSuffix("-shm"),
                  !name.hasSuffix("-journal"), !name.hasPrefix(".sentient-auth-") else { continue }
            let target = destination.appendingPathComponent(name)
            if name.hasSuffix(".sqlite") { try snapshotDatabase(from: entry, to: target) }
            else { try fm.copyItem(at: entry, to: target) }
        }
    }

    private static func snapshotDatabase(from source: URL, to target: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let input { sqlite3_close(input) }; throw CodexRuntime.Failure.installation
        }
        defer { sqlite3_close(input) }
        guard sqlite3_open(target.path, &output) == SQLITE_OK else {
            if let output { sqlite3_close(output) }; throw CodexRuntime.Failure.installation
        }
        defer { sqlite3_close(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw CodexRuntime.Failure.installation }
        var result = SQLITE_OK
        for _ in 0..<100 {
            result = sqlite3_backup_step(backup, -1)
            if result != SQLITE_BUSY && result != SQLITE_LOCKED { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw CodexRuntime.Failure.installation }
        // Session index paths reference the copied rollouts, while workspace paths stay unchanged.
        if source.lastPathComponent.hasPrefix("state_") {
            var statement: OpaquePointer?
            let sql = "UPDATE threads SET rollout_path = ?1 || substr(rollout_path, length(?2) + 1) WHERE substr(rollout_path, 1, length(?2)) = ?2"
            if sqlite3_prepare_v2(output, sql, -1, &statement, nil) == SQLITE_OK {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, CodexRuntime.home.path + "/", -1, transient)
                sqlite3_bind_text(statement, 2, legacyHome.path + "/", -1, transient)
                guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw CodexRuntime.Failure.installation }
            }
            sqlite3_finalize(statement)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Read a complete auth document without logging it. Copying an in-progress truncated write
    /// fails this attempt and retries quietly; no invalid auth file becomes the active login.
    private static func copyAuth(from source: URL, to target: URL) throws {
        let data = try Data(contentsOf: source)
        guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw CodexRuntime.Failure.invalidPackage }
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func loginStatus(home: URL, binary: String? = nil) throws -> Int32 {
        let process = Process()
        let executable = binary.map { URL(fileURLWithPath: $0) } ?? CodexRuntime.executable
        process.executableURL = executable
        // Never let a validation probe open a Keychain consent dialog.
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "-c", "check_for_update_on_startup=false", "login", "status"]
        process.environment = ["HOME": NSHomeDirectory(), "CODEX_HOME": home.path,
                               "PATH": executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationReason == .exit else { throw CodexRuntime.Failure.invalidPackage }
        return process.terminationStatus
    }

    private static func bridgeAuthentication(from source: URL, expectedStatus: Int32) throws {
        if source.resolvingSymlinksInPath() == CodexRuntime.auth.resolvingSymlinksInPath() { return }
        let fm = FileManager.default
        // Transfer the existing inode, rather than duplicating rotating credentials. A Codex
        // process that already has the file open continues writing the same backing file.
        let transfer = CodexRuntime.home.appendingPathComponent(".auth-transfer-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: transfer) }
        try fm.linkItem(at: source.resolvingSymlinksInPath(), to: transfer)
        guard rename(transfer.path, CodexRuntime.auth.path) == 0 else { throw CodexRuntime.Failure.installation }
        let link = source.deletingLastPathComponent().appendingPathComponent(".sentient-auth-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: CodexRuntime.auth)
        defer { try? fm.removeItem(at: link) }
        guard renameatx_np(AT_FDCWD, link.path, AT_FDCWD, source.path, UInt32(RENAME_SWAP)) == 0 else {
            throw CodexRuntime.Failure.installation
        }
        do {
            let before = try fm.attributesOfItem(atPath: link.resolvingSymlinksInPath().path)[.systemFileNumber] as? NSNumber
            let after = try fm.attributesOfItem(atPath: CodexRuntime.auth.path)[.systemFileNumber] as? NSNumber
            guard before == after else { throw CodexRuntime.Failure.busy }
            guard try loginStatus(home: CodexRuntime.home) == expectedStatus else { throw CodexRuntime.Failure.invalidPackage }
        } catch {
            _ = renameatx_np(AT_FDCWD, link.path, AT_FDCWD, source.path, UInt32(RENAME_SWAP))
            throw error
        }
    }

    /// A Keychain-backed account must keep its existing runtime until it can be migrated without
    /// consent UI. Never interpret an inaccessible secret as "signed out" or open a login window.
    private static func requireNoKeychainLogin() throws {
        let digest = SHA256.hash(data: Data(legacyHome.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Codex Auth",
            kSecAttrAccount: "cli|" + digest.prefix(16), kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecItemNotFound else { throw CodexRuntime.Failure.busy }
    }

    /// Leave standalone Codex signed in if Sentient is uninstalled after a migration.
    static func restoreLegacyAuthentication() throws {
        let source = legacyHome.appendingPathComponent("auth.json")
        let fm = FileManager.default
        guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              source.resolvingSymlinksInPath() == CodexRuntime.auth.resolvingSymlinksInPath() else { return }
        let temporary = legacyHome.appendingPathComponent(".sentient-auth-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.linkItem(at: CodexRuntime.auth, to: temporary)
        guard rename(temporary.path, source.path) == 0 else { throw CodexRuntime.Failure.installation }
    }
}
