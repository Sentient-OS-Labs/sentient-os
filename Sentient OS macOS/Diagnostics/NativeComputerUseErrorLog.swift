// Local-only native error evidence. Do not use Log(): that also feeds remote breadcrumbs.
import Foundation

nonisolated final class NativeComputerUseErrorLog: @unchecked Sendable {
    static let shared = NativeComputerUseErrorLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SentientOS/ComputerUse", isDirectory: true))
    private let directory: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "sentient.native-error-log")

    init(directory: URL, maximumBytes: Int = 8 * 1_048_576) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    static func record(tool: String, failure: NativeComputerUseFailure) {
        shared.append(tool: tool, failure: failure)
    }

    func append(tool: String, failure: NativeComputerUseFailure) {
        queue.async { [self] in
            do {
                var entry: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                    "tool": tool, "classification": failure.fields,
                    "effects_may_be_unknown": failure.effectsMayBeUnknown]
                if let raw = failure.rawError {
                    entry["raw_error"] = try JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)
                } else {
                    entry["raw_error"] = failure.modelError ?? failure.localizedDescription
                }
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                data.append(10)
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("errors.jsonl")
                let previous = directory.appendingPathComponent("errors.previous.jsonl")
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                // Retain complete records. A single large error can exceed the rotation target;
                // its size is already bounded by the native transport's response limit.
                if size > 0 && size + data.count > maximumBytes {
                    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                    try fm.moveItem(at: file, to: previous)
                }
                if !fm.fileExists(atPath: file.path) {
                    guard fm.createFile(atPath: file.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { return }
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Logging must never prevent the agent from receiving the actual tool result.
            }
        }
    }

    func flush() { queue.sync {} }
}
