// A pre-inference request survives macOS's own Quit and Reopen consent flow as an unsent draft.
// Cleared before capture/model work and on explicit cancellation. Never executed automatically.
import Foundation

nonisolated enum PermissionWaitDraft {
    struct Snapshot: Codable {
        let generation: UUID
        let runID: UUID
        let text: String
        let reply: SidekickConversationEvent.ReplyReference?
    }
    enum Failure: LocalizedError {
        case unavailable, changed
        var errorDescription: String? {
            switch self {
            case .unavailable: "Sidekick could not preserve this request for permission setup. Your request remains in the conversation."
            case .changed: "The saved permission request changed. Send your request again when setup is ready."
            }
        }
    }
    private static var url: URL { URL.sentientSupport.appendingPathComponent("Sidekick/PermissionWaitDraft.json") }
    static func save(_ snapshot: Snapshot) throws {
        let file = url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        guard !snapshot.text.isEmpty, data.count <= 1_000_000 else { throw Failure.unavailable }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Caller restores only into an empty composer of the same conversation generation, then
    /// clears the matching run. Reading never consumes a request during a transient store failure.
    static func read() -> Snapshot? {
        let file = url
        guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? .max) <= 1_000_000,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    /// An inability to clear the current request blocks inference: a later launch must never
    /// restore a request that may already have produced side effects. A newer run is untouched.
    static func clear(matching runID: UUID) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let saved = read(), saved.runID == runID else { throw Failure.changed }
        try FileManager.default.removeItem(at: url)
    }
    /// In-place cancellation retires the content even if directory permissions prevent unlink.
    /// A crash after truncation leaves an unreadable tombstone, never a restorable request.
    static func cancel(matching runID: UUID) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let saved = read(), saved.runID == runID else { throw Failure.changed }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("cancelled\n".utf8))
        try handle.synchronize()
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}
