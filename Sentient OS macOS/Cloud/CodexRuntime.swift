// Sentient's approved Codex release, private paths, process settings and installation locks.
// A quiet migration keeps the original home available until the private runtime is ready.
// Doc: Cloud/Documentation - Cloud - Codex Setup.md

import CryptoKit
import Darwin
import Foundation

nonisolated enum CodexRuntime {
    struct FileRecord: Codable, Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
        let executable: Bool
    }
    struct Artifact: Codable, Sendable {
        let version: String
        let filename: String
        let sha256: String
        let bytes: Int64
        let files: [FileRecord]
        var url: URL {
            #if DEBUG
            if let directory = ProcessInfo.processInfo.environment["SENTIENT_CODEX_ARCHIVE_DIR"] {
                return URL(fileURLWithPath: directory).appendingPathComponent(filename)
            }
            #endif
            return URL(string: "https://sentient-downloads.sentient-doubletap-relay.workers.dev/releases/\(filename)")!
        }
    }
    struct Release: Codable, Sendable {
        let target: String
        let cli: Artifact
        let helper: Artifact
        let helperBuild: Int
    }
    static let release: Release = {
        var url = Bundle.main.url(forResource: "BundledCodexRelease", withExtension: "json")
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SENTIENT_CODEX_MANIFEST"] { url = URL(fileURLWithPath: path) }
        #endif
        guard let url, let data = try? Data(contentsOf: url),
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            preconditionFailure("Missing approved Codex release manifest")
        }
        return release
    }()

    static var root: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SENTIENT_CODEX_RUNTIME_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return URL.sentientSupport.appendingPathComponent("Bundled Codex", isDirectory: true)
    }
    static var home: URL { root.appendingPathComponent(".codex", isDirectory: true) }
    static var cliDirectory: URL { root.appendingPathComponent("releases/cli-\(release.cli.version)", isDirectory: true) }
    static var executable: URL { cliDirectory.appendingPathComponent("bin/codex") }
    static var activeHome: URL { CodexRuntimeMigration.isPending ? CodexRuntimeMigration.legacyHome : home }
    static var auth: URL { home.appendingPathComponent("auth.json") }
    static var activeAuth: URL { activeHome.appendingPathComponent("auth.json") }
    static var plugins: URL { activeHome.appendingPathComponent("plugins/cache/openai-curated-remote", isDirectory: true) }
    static var helper: URL { home.appendingPathComponent("computer-use/Codex Computer Use.app", isDirectory: true) }
    static var receipt: URL { root.appendingPathComponent("installed-runtime.json") }
    static var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }

    /// Stable, local-only account fingerprint. Neither account IDs nor tokens enter diagnostics.
    static var accountIdentity: String? { identity(at: activeAuth) }
    static func identity(at authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let account = tokens["account_id"] as? String, !account.isEmpty else { return nil }
        var subject = ""
        if let token = tokens["id_token"] as? String {
            let parts = token.split(separator: ".")
            if parts.count == 3 {
                var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                if let bytes = Data(base64Encoded: encoded),
                   let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    subject = claims["sub"] as? String ?? ""
                }
            }
        }
        return SHA256.hash(data: Data((account + "|" + subject).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Run before refreshing a newly signed-in account. Account-bound plugin files are disposable;
    /// software, login and sessions are never included in this cleanup.
    static func prepareAccountCache() throws -> Bool {
        guard !CodexRuntimeMigration.isPending else { return false }
        try prepareHome()
        let lease = try FileLock(root.appendingPathComponent(".runtime.lock"), exclusive: true)
        defer { lease.unlock() }
        guard let identity = accountIdentity else { return false }
        let marker = home.appendingPathComponent(".sentient-connector-account")
        if (try? String(contentsOf: marker, encoding: .utf8)) == identity { return false }
        let cache = home.appendingPathComponent("plugins/cache")
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        try identity.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }

    static var connectorCacheMatchesAccount: Bool {
        if CodexRuntimeMigration.isPending { return true }
        guard let identity = accountIdentity else { return false }
        return (try? String(contentsOf: home.appendingPathComponent(".sentient-connector-account"), encoding: .utf8)) == identity
    }

    enum Failure: LocalizedError {
        case invalidPackage, busy, unsupported, diskSpace, installation
        var errorDescription: String? {
            switch self {
            case .invalidPackage: "The Codex download or installation could not be verified. Repair it and try again."
            case .busy: "Codex is in use or setup is already running. Finish the active task, then try again."
            case .unsupported: "This Codex package requires an Apple Silicon Mac."
            case .diskSpace: "There isn't enough free space to install Codex. Free up space and try again."
            case .installation: "Codex setup could not finish. Your saved login and tasks were preserved. Try again."
            }
        }
    }

    static func prepareHome() throws {
        try directory(root)
        for path in [home, root.appendingPathComponent("releases"), downloads,
                     home.appendingPathComponent("computer-use")] { try directory(path) }
        if FileManager.default.fileExists(atPath: auth.path) {
            let values = try auth.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw Failure.invalidPackage
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        }
    }
    static func directory(_ url: URL) throws {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType != .typeDirectory {
            throw Failure.invalidPackage
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Only Codex receives these settings. Claude and shared utility subprocesses keep their own environment.
    static func isCodex(_ binary: String) -> Bool {
        (binary.hasPrefix(root.path + "/") && URL(fileURLWithPath: binary).lastPathComponent == "codex")
            || binary == CodexRuntimeMigration.legacyBinary
    }
    /// A command selected before cutover may have waited for its shared lease. Route that
    /// command through the completed home too, so its session is written to the new database.
    static func binaryAfterLease(_ selected: String) -> String {
        selected == CodexRuntimeMigration.legacyBinary && CodexRuntimeMigration.completed ? executable.path : selected
    }
    static func arguments(_ args: [String], binary: String) -> [String] {
        guard isCodex(binary) else { return args }
        if binary == CodexRuntimeMigration.legacyBinary { return ["-c", "check_for_update_on_startup=false"] + args }
        return ["-c", "cli_auth_credentials_store=\"file\"", "-c", "check_for_update_on_startup=false"] + args
    }
    static func environment(_ inherited: [String: String], binary: String) -> [String: String] {
        guard isCodex(binary) else { return inherited }
        var env = inherited
        env["HOME"] = NSHomeDirectory()
        env["CODEX_HOME"] = binary == CodexRuntimeMigration.legacyBinary ? CodexRuntimeMigration.legacyHome.path
            : binary == executable.path ? activeHome.path : home.path
        // A developer shell's API credentials must not replace the user's private ChatGPT login.
        env.removeValue(forKey: "OPENAI_API_KEY")
        for key in ["CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_REFRESH_TOKEN_URL_OVERRIDE",
                    "CODEX_REVOKE_TOKEN_URL_OVERRIDE", "CODEX_APP_SERVER_LOGIN_CLIENT_ID"] { env.removeValue(forKey: key) }
        return env
    }

    final class FileLock: @unchecked Sendable {
        private let mutex = NSLock()
        private var descriptor: Int32
        init(_ url: URL, exclusive: Bool, wait: Bool = false, cancelled: () -> Bool = { false }) throws {
            descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Failure.installation }
            do {
                while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
                    guard wait, errno == EWOULDBLOCK || errno == EINTR else { throw Failure.busy }
                    if cancelled() { throw CancellationError() }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if cancelled() { throw CancellationError() }
            } catch {
                close(descriptor); descriptor = -1
                throw error
            }
        }
        func unlock() {
            mutex.lock(); defer { mutex.unlock() }
            if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
        }
        deinit { unlock() }
    }
    /// Covers native readiness and the complete computer-use task, including helper child
    /// processes, so a migration or repair cannot change its chosen CLI or home mid-task.
    static func sharedRuntimeLease() async throws -> FileLock {
        let acquisition = Task.detached {
            try prepareHome()
            return try FileLock(root.appendingPathComponent(".runtime.lock"), exclusive: false,
                                wait: true, cancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler { try await acquisition.value }
            onCancel: { acquisition.cancel() }
    }

    static func executionLease(for binary: String, exclusive: Bool = false, cancelled: () -> Bool = { false }) throws -> FileLock? {
        guard isCodex(binary) else { return nil }
        try prepareHome()
        guard binary == executable.path || binary == CodexRuntimeMigration.legacyBinary else { return nil } // staged validation isn't a live task
        // A new command waits for an atomic publication; background setup never surfaces a
        // spurious "busy" failure in a user task. Installers themselves always defer when busy.
        return try FileLock(root.appendingPathComponent(".runtime.lock"), exclusive: exclusive, wait: !exclusive, cancelled: cancelled)
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Exact file inventory also rejects added payloads, links and modified executable modes.
    static func verify(_ artifact: Artifact, at directory: URL) throws {
        let fm = FileManager.default
        try requireRealDirectory(directory)
        guard let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure.invalidPackage
        }
        var found = Set<String>()
        let prefix = directory.resolvingSymlinksInPath().path + "/"
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure.invalidPackage }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw Failure.invalidPackage }
            // Foundation may enumerate /tmp through /private/tmp (or another volume alias).
            // Compare consistently resolved paths while still rejecting links above.
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { throw Failure.invalidPackage }
            found.insert(String(path.dropFirst(prefix.count)))
        }
        guard found == Set(artifact.files.map(\.path)) else { throw Failure.invalidPackage }
        for file in artifact.files {
            let url = directory.appendingPathComponent(file.path)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.bytes,
                  ((((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111) != 0) == file.executable,
                  try sha256(url) == file.sha256 else { throw Failure.invalidPackage }
        }
    }

    private static func requireRealDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure.invalidPackage
        }
    }

    private final class VerificationCache: @unchecked Sendable {
        let lock = NSLock()
        var snapshots: [String: String] = [:]
        func verify(_ artifact: Artifact, at root: URL) throws {
            lock.lock(); defer { lock.unlock() }
            try CodexRuntime.requireRealDirectory(root)
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw Failure.invalidPackage
            }
            var values: [String] = []
            for case let url as URL in entries {
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Failure.invalidPackage }
                values.append("\(url.path)|\(info.st_ino)|\(info.st_size)|\(info.st_mode)|\(info.st_mtimespec)|\(info.st_ctimespec)")
            }
            let snapshot = values.sorted().joined(separator: "\n")
            if snapshots[root.path] != snapshot {
                try CodexRuntime.verify(artifact, at: root)
                snapshots[root.path] = snapshot
            }
        }
    }
    private static let verification = VerificationCache()
    static func verifyCLIForLaunch() throws { try verification.verify(release.cli, at: cliDirectory) }

    static var cliPresent: Bool {
        let manifest = cliDirectory.appendingPathComponent("codex-package.json")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: manifest),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return info["version"] as? String == release.cli.version && info["target"] as? String == release.target
    }
}
