// A bounded restart handoff. The replacement launches only after the committed parent exits.
// Runs before AppState in the same signed executable; no shell, credentials or permission changes.
import Darwin
import Foundation

nonisolated enum PermissionRelaunchHandoff {
    static let argument = "--permission-relaunch-handoff"
    static let lifetime: TimeInterval = 15

    enum Failure: LocalizedError {
        case unavailable, notReady, expired
        var errorDescription: String? {
            switch self {
            case .unavailable: "Sentient could not prepare its restart. Try again; your current window is still open."
            case .notReady: "The restart helper did not get ready. Try again."
            case .expired: "The restart request expired. Try again when you are ready to quit."
            }
        }
    }

    @MainActor final class Ticket {
        private let process: Process
        private let directory: URL
        private let deadline: TimeInterval
        init(process: Process, directory: URL) {
            self.process = process; self.directory = directory
            deadline = ProcessInfo.processInfo.systemUptime + lifetime
        }
        var isReady: Bool { process.isRunning && marker("ready", at: directory) && ProcessInfo.processInfo.systemUptime < deadline - 1 }
        func commit() throws {
            guard isReady else { throw Failure.expired }
            try Data("1\n".utf8).write(to: directory.appendingPathComponent("commit"), options: .atomic)
        }
        func cancel() {
            try? Data("1\n".utf8).write(to: directory.appendingPathComponent("cancel"), options: .atomic)
            if process.isRunning { process.terminate() }
            else { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// The helper acknowledges preparation before the app saves its resume handoff or quits.
    @MainActor static func prepare(executable: URL? = Bundle.main.executableURL,
                                  temporaryRoot: URL = FileManager.default.temporaryDirectory) async throws -> Ticket {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        let directory = temporaryRoot.resolvingSymlinksInPath()
            .appendingPathComponent("sentient-permission-relaunch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, String(getpid()), directory.path]
        process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL"].contains($0.key) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            if marker("cancel", at: directory) { try? FileManager.default.removeItem(at: directory) }
        }
        let ticket = Ticket(process: process, directory: directory)
        do {
            try process.run()
            for _ in 0..<60 {
                try Task.checkCancellation()
                if ticket.isReady { return ticket }
                guard process.isRunning else { throw Failure.notReady }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure.notReady
        } catch {
            ticket.cancel()
            throw error
        }
    }

    /// Blocking is confined to the dedicated child process. Losing the actual parent, rather
    /// than observing a numeric PID disappear, avoids a PID-reuse race. An uncommitted or timed
    /// out request can never cause a relaunch after a later ordinary quit.
    static func run(arguments: [String], timeout: TimeInterval = lifetime,
                    launch: () -> Int32 = launchOwnBundle) -> Int32 {
        guard arguments.count == 4, arguments[1] == argument,
              let parent = Int32(arguments[2]), parent > 1, getppid() == parent else { return 1 }
        let directory = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        guard directory.lastPathComponent.hasPrefix("sentient-permission-relaunch-"),
              directory.resolvingSymlinksInPath() == directory else { return 1 }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true else { return 1 }
        do { try Data("1\n".utf8).write(to: directory.appendingPathComponent("ready"), options: .atomic) }
        catch { return 1 }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeout, 0.05), lifetime)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if marker("cancel", at: directory) {
                try? FileManager.default.removeItem(at: directory); return 1
            }
            if getppid() != parent {
                guard marker("commit", at: directory) else {
                    try? FileManager.default.removeItem(at: directory); return 1
                }
                let result = launch()
                if result == 0 { try? FileManager.default.removeItem(at: directory) }
                else { try? Data("launch_failed\n".utf8).write(to: directory.appendingPathComponent("result"), options: .atomic) }
                return result
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? FileManager.default.removeItem(at: directory)
        return 1
    }

    private static func marker(_ name: String, at directory: URL) -> Bool {
        let file = directory.appendingPathComponent(name)
        guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == 2 else { return false }
        return (try? Data(contentsOf: file)) == Data("1\n".utf8)
    }

    private static func launchOwnBundle() -> Int32 {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return 1 }
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", bundle.path]
        opener.standardInput = FileHandle.nullDevice
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        do {
            try opener.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while opener.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
            guard !opener.isRunning else { opener.terminate(); return 1 }
            return opener.terminationStatus
        } catch { return 1 }
    }
}
