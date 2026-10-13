//
//  WakeHelperMaintenance.swift
//  Sentient OS macOS · Scheduling/
//
//  Fixed-scope root maintenance for the native wake helper. retireLegacy removes the previous
//  launchd job only after this helper is approved; removeState removes our own files on uninstall.
//  No XPC caller can supply a command or a path.
//  Doc: Documentation - Overnight Scheduler & Wake Helper.md
//

import Foundation
import Darwin

nonisolated enum WakeHelperMaintenance {
    static let supportPath = "/Library/Application Support/SentientOS"
    static let armedPath = supportPath + "/armed-wake"
    static let logPath = "/Library/Logs/SentientOS-wakehelper.log"

    /// A distinct service name lets the new, approved daemon retire the old one without a
    /// bootstrap-name collision or a second privilege-escalation mechanism.
    @discardableResult
    static func retireLegacy(
        runCommand: (String, [String]) throws -> Int32 = run,
        removePlist: () throws -> Bool = removeLegacyPlist
    ) throws -> Bool {
        let target = "system/" + WakeHelperConfig.legacyServiceName
        let status = try runCommand("/bin/launchctl", ["print", target])
        // launchctl uses bootstrap error 113 for an absent service. Other errors must not be
        // mistaken for absence: never delete the plist while a legacy helper might still run.
        guard status == 0 || status == 113 else { throw failure(status) }
        if status == 0 {
            _ = try runCommand("/bin/launchctl", ["bootout", target])
            let remaining = try runCommand("/bin/launchctl", ["print", target])
            guard remaining == 113 else { throw failure(remaining) }
        }
        let removed = try removePlist()
        return status == 0 || removed
    }

    private static func removeLegacyPlist() throws -> Bool {
        let existed = FileManager.default.fileExists(atPath: WakeHelperConfig.legacyPlistPath)
        try unlinkFile(WakeHelperConfig.legacyPlistPath)
        return existed
    }

    static func removeState() throws {
        try validateSupportDirectory()
        try unlinkFile(armedPath)
        try unlinkFile(logPath)
        // Never recursively delete a shared support directory or follow a symlink.
        if rmdir(supportPath) != 0, errno != ENOENT, errno != ENOTEMPTY, errno != EEXIST {
            throw failure(Int32(errno))
        }
    }

    static func validateSupportDirectory() throws {
        var info = stat()
        guard lstat(supportPath, &info) == 0 else {
            if errno == ENOENT { return }
            throw failure(Int32(errno))
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
              info.st_mode & 0o022 == 0 else { throw failure(EPERM) }
    }

    private static func unlinkFile(_ path: String) throws {
        // unlink removes the named entry itself, including a symlink, without following it.
        if unlink(path) != 0, errno != ENOENT { throw failure(Int32(errno)) }
    }

    /// Bounded process execution on the helper's serial queue. No shell or user-provided input.
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw failure(ETIMEDOUT)
        }
        return process.terminationStatus
    }

    private static func failure(_ code: Int32) -> NSError {
        NSError(domain: "SentientWakeMaintenance", code: Int(code))
    }
}
