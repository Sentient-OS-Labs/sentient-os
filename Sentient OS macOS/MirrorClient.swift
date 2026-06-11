//
//  MirrorClient.swift
//  Sentient OS macOS
//
//  The app side of the hosted MCP mirror (Arch §7). Mirrors the local vault to our one
//  persistent backend so the user's ChatGPT/Claude can read it over MCP. Opt-in, opt-out,
//  one-click delete — the Mac's vault is always canonical; the mirror is a disposable copy.
//
//  IDENTITY = TWO TOKENS, NO ACCOUNTS (Invariant 4 + the read/write split):
//   • read token  — lives in the share URL (mcp.sentient-os.ai/u/<read>/mcp); MCP reads only.
//   • write token — NEVER leaves this Mac (Keychain); sent as `Authorization: Bearer <write>`
//                   on push/delete/stats. The server binds it on the first push (stores only
//                   its sha256). So a leaked share URL can never replace or delete the vault.
//  Both are minted once, on opt-in, and kept in the Keychain. Losing them is a non-event:
//  mint new ones, re-push, the orphaned cloud copy expires on its 30-day lease.
//
//  Sync = whole-vault zip-replace (Arch §7): POST /vault sends the entire vault as a zip
//  (~KBs of markdown) on any change; DELETE /vault is the one-click delete.
//
//  Doc: Documentation/MCP Mirror Client.md
//

import Foundation

actor MirrorClient {

    static let shared = MirrorClient()

    /// Production mirror. Overridable for local server testing via SENTIENT_MIRROR_BASE.
    static var baseURL: String {
        ProcessInfo.processInfo.environment["SENTIENT_MIRROR_BASE"] ?? "https://mcp.sentient-os.ai"
    }

    struct Stats: Sendable {
        let notesRead24h: Int
        let toolCalls24h: Int
        let lastAccess: Date?
    }

    enum MirrorError: LocalizedError {
        case notEnabled
        case http(Int, String)
        case zipFailed(String)
        case noVault

        var errorDescription: String? {
            switch self {
            case .notEnabled:          return "The cloud mirror isn't turned on."
            case .http(let c, let b):  return "Mirror server returned HTTP \(c). \(b.prefix(200))"
            case .zipFailed(let m):    return "Couldn't package the vault: \(m)"
            case .noVault:             return "There's no vault on disk to mirror yet."
            }
        }
    }

    // MARK: Enable / disable

    /// Whether the user has opted into the mirror (the tokens exist in the Keychain).
    var isEnabled: Bool { Keychain.read(Self.readKey) != nil && Keychain.read(Self.writeKey) != nil }

    /// Opt in: mint both tokens (idempotent — keeps existing ones so the share URL is stable).
    /// Returns the share URL.
    @discardableResult
    func enable() -> String {
        if Keychain.read(Self.readKey) == nil { Keychain.set(Self.readKey, Self.mintToken()) }
        if Keychain.read(Self.writeKey) == nil { Keychain.set(Self.writeKey, Self.mintToken()) }
        return shareURL!
    }

    /// The user-facing MCP connector URL (read token), or nil if not enabled. This is what
    /// "Copy MCP Link" copies and what gets pasted into ChatGPT/Claude.
    var shareURL: String? {
        guard let read = Keychain.read(Self.readKey) else { return nil }
        return "\(Self.baseURL)/u/\(read)/mcp"
    }

    // MARK: Push / delete / stats

    /// Zip the local vault and replace the mirror with it. Renews the 30-day lease.
    /// No-op-safe to call after any vault change (initial gen, daily update, user edit).
    func push() async throws {
        guard let read = Keychain.read(Self.readKey), let write = Keychain.read(Self.writeKey) else {
            throw MirrorError.notEnabled
        }
        let root = VaultGenerator.vaultRoot
        guard FileManager.default.fileExists(atPath: root.path) else { throw MirrorError.noVault }

        let zip = try Self.zipDirectory(root)
        defer { try? FileManager.default.removeItem(at: zip) }

        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u/\(read)/vault")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(write)", forHTTPHeaderField: "Authorization")
        req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: zip)
        try Self.check(resp, data)
    }

    /// The one-click delete — removes the cloud copy (and its access log). The local vault
    /// is untouched. Tokens are kept so re-enabling reuses the same share URL.
    func deleteRemote() async throws {
        guard let read = Keychain.read(Self.readKey), let write = Keychain.read(Self.writeKey) else {
            throw MirrorError.notEnabled
        }
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u/\(read)/vault")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(write)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    /// Full opt-out: delete the cloud copy AND forget the tokens (a fresh opt-in later mints
    /// a new share URL). Best-effort on the network call — local forget always happens.
    func disable() async {
        try? await deleteRemote()
        Keychain.delete(Self.readKey)
        Keychain.delete(Self.writeKey)
    }

    /// The "your AIs read N notes" numbers for the home screen. nil if not enabled / no vault yet.
    func stats() async throws -> Stats {
        guard let read = Keychain.read(Self.readKey), let write = Keychain.read(Self.writeKey) else {
            throw MirrorError.notEnabled
        }
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u/\(read)/stats")!)
        req.setValue("Bearer \(write)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let last = (obj["last_access"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Stats(notesRead24h: obj["notes_read_24h"] as? Int ?? 0,
                     toolCalls24h: obj["tool_calls_24h"] as? Int ?? 0,
                     lastAccess: last)
    }

    // MARK: Helpers

    private static let readKey = "mcp.mirror.readToken"
    private static let writeKey = "mcp.mirror.writeToken"

    /// 32 random bytes → base64url (43 chars, no padding) — inside the server's [32,64] window
    /// and URL-safe, so it drops straight into the path.
    private static func mintToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw MirrorError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Zip a directory into a temp .zip using the OS's own coordinated "for uploading" read —
    /// no shelling out, no dependency. The zip's entries are vault-relative (the server expects
    /// paths like `README.md`, `Career/Job Search.md`).
    private static func zipDirectory(_ dir: URL) throws -> URL {
        var coordError: NSError?
        var thrown: Error?
        var result: URL?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipped in
            // `zipped` is a temp .zip the OS created; move it somewhere we own before the block ends.
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("vault-\(UUID().uuidString).zip")
            do { try FileManager.default.moveItem(at: zipped, to: dst); result = dst }
            catch { thrown = error }
        }
        if let coordError { throw MirrorError.zipFailed(coordError.localizedDescription) }
        if let thrown { throw MirrorError.zipFailed(thrown.localizedDescription) }
        guard let result else { throw MirrorError.zipFailed("no archive produced") }
        return result
    }
}

// MARK: - Keychain (first user: a tiny generic-password helper)

/// Minimal Keychain wrapper for small secrets (the mirror tokens). One service, key = account.
enum Keychain {
    private static let service = "ai.sentient-os.app"

    static func set(_ key: String, _ value: String) {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ] as CFDictionary)
    }
}
