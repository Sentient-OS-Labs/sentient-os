// Records lifecycle metadata from owned helper processes and reports failures from the GUI parent.
// observe scopes a private temporary channel; helpers never initialize a second telemetry SDK.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation
import Darwin

nonisolated enum ChildProcessDiagnostics {
    static let environmentKey = "SENTIENT_CHILD_DIAGNOSTICS"
    @TaskLocal static var directory: URL?
    enum Role: String, Codable, Sendable {
        case claudeSubscription, outlookPolicy, slackPolicy, directHeaders, directPolicy
        static func from(_ argument: String?) -> Role? {
            switch argument {
            case "--claude-subscription-process": .claudeSubscription
            case "--outlook-tool-policy": .outlookPolicy
            case "--slack-tool-policy": .slackPolicy
            case "--direct-mcp-headers": .directHeaders
            case "--direct-mcp-policy": .directPolicy
            default: nil
            }
        }
    }
    struct Record: Codable, Sendable {
        let role: Role
        let pid: Int32
        let began: Date
        var ended: Date?
        var status: Int32?
    }
    struct Child: Sendable {
        let url: URL
        let record: Record
        func finish(_ status: Int32) {
            var final = record; final.ended = Date(); final.status = status
            if let data = try? JSONEncoder().encode(final) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Only the GUI creates channels, inside its private temporary directory. No args, output or IDs are forwarded.
    static func begin(role: Role) -> Child? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let dir = URL(fileURLWithPath: path).standardizedFileURL
        guard dir.lastPathComponent.hasPrefix("sentient-diagnostics-"),
              dir.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: dir.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return nil }
        let record = Record(role: role, pid: getpid(), began: Date())
        let child = Child(url: dir.appendingPathComponent(UUID().uuidString + ".json"), record: record)
        guard let data = try? JSONEncoder().encode(record), (try? data.write(to: child.url, options: .atomic)) != nil else { return nil }
        return child
    }

    static func observe<T>(isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async rethrows -> T {
        guard directory == nil, CrashReporting.diagnosticsEnabled else { return try await body() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sentient-diagnostics-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch {
            Diagnostics.report(.childFailed, phase: .setup, reason: "diagnostic_channel", error: error)
            return try await body()
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await $directory.withValue(dir) {
            do {
                let result = try await body()
                // Give short-lived helpers time to record their normal EOF exit after the CLI exits.
                try? await Task.sleep(for: .milliseconds(250))
                collect(dir, cancelled: Task.isCancelled)
                return result
            } catch {
                try? await Task.sleep(for: .milliseconds(250))
                collect(dir, cancelled: Task.isCancelled || Diagnostics.isCancellation(error))
                throw error
            }
        }
    }

    static func collect(_ dir: URL, cancelled: Bool) {
        guard !cancelled, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for file in files.prefix(256) where file.pathExtension == "json" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
                  let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            let reason: String
            if let status = record.status {
                guard status != 0, status != 130, status != 143 else { continue }
                reason = "nonzero_exit"
            } else {
                // A live helper can still be draining. Only an exited process missing its completion is suspicious.
                guard record.pid > 1, kill(record.pid, 0) != 0, errno == ESRCH else { continue }
                reason = "exit_without_completion"
            }
            CrashReporting.captureEvent(Diagnostics.Event.childFailed.rawValue,
                tags: ["role": record.role.rawValue, "phase": "child", "reason": reason,
                       "backend": Diagnostics.current?.backend ?? ModelBackend.current.rawValue],
                extra: ["exit_code": record.status.map(String.init) ?? "unknown",
                        "duration_ms": String(max(0, Int((record.ended ?? Date()).timeIntervalSince(record.began) * 1000)))],
                fingerprint: ["child", record.role.rawValue, reason, record.status.map(String.init) ?? "unknown"])
        }
    }
}
