//
//  Log.swift
//  Sentient OS macOS
//
//  Log() — the codebase-wide replacement for print() (bare print is a code smell;
//  Dev Notes §Eval culture). Prints to stdout/Xcode console as usual and, in DEBUG
//  builds only, tees a timestamped copy to /tmp/sentient-dev.log (append-mode, one
//  banner per launch) so agents can `tail -f` a GUI-run session live. Release builds
//  never write the file.
//

import Foundation

/// Drop-in for `print()`: same signature, same console output, plus the DEBUG file tee.
func Log(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    print(message, terminator: terminator)
    CrashReporting.breadcrumb(message)   // trail of recent log lines, attached to any crash report
    #if DEBUG
    LogFile.shared.append(message)
    #endif
}

/// Content-safe error rendering for `Log()` error paths. In RELEASE it yields the enum case /
/// type name only ("CLIError.exitFailure", "CocoaError(NSCocoaErrorDomain 512)") — never the
/// description, because error payloads embed content (CLIError carries up to 300 chars of codex
/// stderr; Cocoa file errors carry note titles in paths) and every Log() line ships to Sentry as
/// a Release breadcrumb. DEBUG builds return the full description (the dev log wants the meat;
/// Sentry never boots in DEBUG).
func ErrorLabel(_ error: Error) -> String {
    #if DEBUG
    return "\(error)"
    #else
    let mirror = Mirror(reflecting: error)
    if mirror.displayStyle == .enum, let caseName = mirror.children.first?.label {
        return "\(type(of: error)).\(caseName)"
    }
    let ns = error as NSError
    return "\(type(of: error))(\(ns.domain) \(ns.code))"
    #endif
}

#if DEBUG
/// Serial appender for /tmp/sentient-dev.log. All writes funnel through one queue,
/// so calls are safe from any thread or actor.
private final class LogFile: @unchecked Sendable {
    static let shared = LogFile()
    private let queue = DispatchQueue(label: "sentientos.logfile")
    private let handle: FileHandle?
    private let clock: DateFormatter

    private init() {
        let path = "/tmp/sentient-dev.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        let banner = "\n=== \(ProcessInfo.processInfo.processName) launched \(Date()) (pid \(ProcessInfo.processInfo.processIdentifier)) ===\n"
        handle?.write(Data(banner.utf8))
    }

    func append(_ message: String) {
        queue.async { [self] in
            handle?.write(Data("[\(clock.string(from: Date()))] \(message)\n".utf8))
        }
    }
}
#endif
