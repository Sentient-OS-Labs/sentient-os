// Sentient's approved Codex release, private paths, process settings and installation locks.
// No standalone Codex software, authentication, configuration or session state is imported.
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

    /// Stable across releases; old runtime sessions and connector caches belong to a different profile.
    static let sessionScope = "private-codex-v1"

    static var root: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SENTIENT_CODEX_RUNTIME_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return URL.sentientSupport.appendingPathComponent("Private Codex", isDirectory: true)
    }
    static var home: URL { root.appendingPathComponent(".codex", isDirectory: true) }
    static var cliDirectory: URL { root.appendingPathComponent("releases/cli-\(release.cli.version)", isDirectory: true) }
    static var executable: URL { cliDirectory.appendingPathComponent("bin/codex") }
    static var auth: URL { home.appendingPathComponent("auth.json") }
    static var plugins: URL { home.appendingPathComponent("plugins/cache/openai-curated-remote", isDirectory: true) }
    static var helper: URL { home.appendingPathComponent("computer-use/Codex Computer Use.app", isDirectory: true) }
    static var receipt: URL { root.appendingPathComponent("installed-runtime.json") }
    static var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }

    /// Stable, local-only account fingerprint. Neither account IDs nor tokens enter diagnostics.
    static var accountIdentity: String? {
        guard let data = try? readAuthData(),
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
        try prepareHome()
        let lease = try FileLock(root.appendingPathComponent(".runtime.lock"), exclusive: true)
        defer { lease.unlock() }
        let cachedIdentity = try readConnectorCacheIdentity()
        guard let identity = accountIdentity else { return false }
        let marker = home.appendingPathComponent(".sentient-connector-account")
        if cachedIdentity == identity { return false }
        let cache = home.appendingPathComponent("plugins/cache")
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        try identity.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }

    static var connectorCacheMatchesAccount: Bool {
        guard let identity = accountIdentity else { return false }
        return (try? readConnectorCacheIdentity()) == identity
    }

    /// A cache path or marker can never redirect inspection or cleanup into a different profile.
    /// Missing directories are normal before the first connector refresh; existing links are not.
    private static func readConnectorCacheIdentity() throws -> String? {
        try requireRealDirectory(root)
        try requireRealDirectory(home)
        for path in [home.appendingPathComponent("plugins"), home.appendingPathComponent("plugins/cache"), plugins] {
            var info = stat()
            if lstat(path.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.invalidPackage }
            } else if errno != ENOENT { throw Failure.invalidPackage }
        }
        let marker = home.appendingPathComponent(".sentient-connector-account")
        let descriptor = open(marker.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.invalidPackage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.invalidPackage
        }
        return try handle.readToEnd().flatMap { String(data: $0, encoding: .utf8) }
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
    /// Read only this profile's regular auth file. Never follow an auth/home link into another install.
    static func readAuthData() throws -> Data {
        try requireRealDirectory(root)
        try requireRealDirectory(home)
        let descriptor = open(auth.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidPackage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.invalidPackage
        }
        return try handle.readToEnd() ?? Data()
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
        binary.hasPrefix(root.path + "/") && URL(fileURLWithPath: binary).lastPathComponent == "codex"
    }
    static func arguments(_ args: [String], binary: String) -> [String] {
        guard isCodex(binary) else { return args }
        return ["-c", "cli_auth_credentials_store=\"file\"", "-c", "check_for_update_on_startup=false"] + args
    }
    static func environment(_ inherited: [String: String], binary: String) -> [String: String] {
        guard isCodex(binary) else { return inherited }
        var env = inherited
        env["HOME"] = NSHomeDirectory()
        env["CODEX_HOME"] = home.path
        env["CODEX_CLI_PATH"] = binary
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
    /// processes, so a repair cannot change its chosen CLI or home mid-task.
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
        guard binary == executable.path else { return nil } // staged validation isn't a live task
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
        for directory in [root, root.appendingPathComponent("releases"), cliDirectory, cliDirectory.appendingPathComponent("bin")] {
            guard (try? requireRealDirectory(directory)) != nil else { return false }
        }
        var executableInfo = stat()
        guard lstat(executable.path, &executableInfo) == 0,
              (executableInfo.st_mode & S_IFMT) == S_IFREG else { return false }
        let manifest = cliDirectory.appendingPathComponent("codex-package.json")
        var manifestInfo = stat()
        guard lstat(manifest.path, &manifestInfo) == 0,
              (manifestInfo.st_mode & S_IFMT) == S_IFREG else { return false }
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: manifest),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return info["version"] as? String == release.cli.version && info["target"] as? String == release.target
    }
}
