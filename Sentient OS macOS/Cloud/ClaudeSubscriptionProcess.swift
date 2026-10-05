// Runs the official Claude CLI in an owned child of Sentient, including parent-exit cleanup.
// The app reuses this entry before normal startup; model execution stays in the shared CLI runner.
// Doc: Documentation - Cloud - ClaudeCLI (the claude -p engine).md

import Darwin
import Foundation
import os

nonisolated enum ClaudeSubscriptionProcess {
    static let argument = "--claude-subscription-process"

    struct Invocation: Codable, Sendable {
        let parent: Int32
        let binary: String
        let arguments: [String]
        let input: String
        let environment: [String: String]
        let timeout: TimeInterval
    }

    /// Only metadata needed by ClaudeCLI.parseEnvelope is retained; screenshots stream through.
    static func retainEnvelopeLine(_ line: String) -> Bool {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return ["system", "result", "rate_limit_event"].contains(event["type"] as? String ?? "")
    }

    static func run() async -> Int32 {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 64 * 1_024 * 1_024 else { return 1 }
            let invocation = try JSONDecoder().decode(Invocation.self, from: data)
            guard invocation.parent > 1, getppid() == invocation.parent else { return 1 }
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGPIPE, SIG_IGN)
            let stopped = OSAllocatedUnfairLock(initialState: false)
            let signals = [SIGTERM, SIGINT].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
                source.setEventHandler { stopped.withLock { $0 = true } }
                source.resume()
                return source
            }
            defer {
                for source in signals { source.cancel() }
                removeOwnedDirectory()
            }
            let result = try await withThrowingTaskGroup(of: CodexCLI.ExecResult?.self) { group in
                group.addTask {
                    try await CodexCLI.executeAsync(binary: invocation.binary, args: invocation.arguments,
                        stdinText: invocation.input, cwd: nil, timeout: invocation.timeout,
                        extraEnv: invocation.environment, includeCustomProviderKey: false,
                        retainStdoutLine: retainEnvelopeLine) { line in
                            try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
                        }
                }
                group.addTask {
                    while getppid() == invocation.parent && !stopped.withLock({ $0 }) {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    return nil
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let result else { return 130 }
            if !result.stderr.isEmpty {
                try? FileHandle.standardError.write(contentsOf: Data(result.stderr.utf8))
            }
            return result.status
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            if let error = error as? CodexCLI.CLIError, case .timedOut = error { return 124 }
            return 1
        }
    }

    private static func removeOwnedDirectory() {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let prefix = "sentient-claude-"
        guard directory.deletingLastPathComponent() == temporary,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
