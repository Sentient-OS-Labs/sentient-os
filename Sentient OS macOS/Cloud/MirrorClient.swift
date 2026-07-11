//
//  MirrorClient.swift
//  Sentient OS macOS
//
//  The app side of the hosted MCP mirror. Mirrors the local vault to our one
//  persistent backend so the user's ChatGPT/Claude can read it over MCP. Opt-in, opt-out,
//  one-click delete — the Mac's vault is always canonical; the mirror is a disposable copy.
//
//  IDENTITY = ONE PASSWORD, NO ACCOUNTS (Invariant 4):
//   The share URL is mcp.sentient-os.ai/u_<userID>/p_<password>/mcp. The PASSWORD is the one
//   root secret (minted on opt-in, kept in the Keychain); the userID is DERIVED from it (a
//   one-way HKDF) and is a public, non-secret label. Because userID = f(password), the server
//   can verify statelessly that a URL's userID belongs to its password — that binding authorizes
//   reads AND push/delete/stats with no separate credential. Tradeoff: anyone who sees the full
//   share URL can also overwrite/delete the vault (and the server decrypts it for the instant of
//   a request); mitigated by no accounts, the 30-day lease, one-click delete, encryption at rest,
//   and the vault being PII-stripped. Losing the password is a non-event (mint a new one → new
//   URL, re-push; the orphaned cloud copy expires on its 30-day lease).
//
//  ENCRYPTED AT REST: push() encrypts the whole vault zip with AES-256-GCM (key derived from the
//   password via HKDF) BEFORE upload, so the server only ever stores ciphertext. See MirrorCrypto.
//
//  Sync = whole-vault encrypted-blob replace: POST /vault sends the entire vault as one encrypted
//  blob (~KBs of markdown) on any change; DELETE /vault is the one-click delete.
//
//  Doc: Documentation/MCP Mirror Client.md
//

import Foundation
import CryptoKit

/// The mirror's key schedule + envelope. MUST stay byte-for-byte in sync with the server's
/// `crypto.py` (same salt, info labels, lengths, AAD, and blob layout) or nothing decrypts.
///
///   encKey = HKDF-SHA256(ikm: password-utf8, salt: SALT, info: INFO_KEY, len: 32)   → AES-256 key
///   userID = base64url(HKDF-SHA256(password-utf8, SALT, INFO_UID, 32))[:UID_LEN]     (public label)
///   blob   = [1 byte version=1] + AES-GCM.combined(nonce ‖ ciphertext ‖ tag), AAD = userID
enum MirrorCrypto {
    static let salt = Data("sentient-os-mirror-v1".utf8)
    static let infoKey = Data("vault-content-key".utf8)
    static let infoUID = Data("vault-user-id".utf8)
    static let uidLen = 20
    static let version: UInt8 = 1

    private static func hkdf(_ password: String, info: Data, len: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
                               salt: salt, info: info, outputByteCount: len)
    }

    /// The public, non-secret vault label — a truncated base64url HKDF of the password.
    static func userID(_ password: String) -> String {
        let raw = hkdf(password, info: infoUID, len: 32).withUnsafeBytes { Data($0) }
        return String(base64url(raw).prefix(uidLen))
    }

    /// Encrypt the vault zip for upload: versioned AES-256-GCM with the userID as AAD.
    static func encrypt(_ plaintext: Data, password: String, uid: String) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: hkdf(password, info: infoKey, len: 32),
                                      authenticating: Data(uid.utf8))
        guard let combined = sealed.combined else { throw MirrorClient.MirrorError.encryptionFailed }
        var out = Data([version])
        out.append(combined)      // nonce(12) ‖ ciphertext ‖ tag(16)
        return out
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

actor MirrorClient {

    static let shared = MirrorClient()

    /// Production mirror. Overridable for local server testing via SENTIENT_MIRROR_BASE.
    static var baseURL: String {
        ProcessInfo.processInfo.environment["SENTIENT_MIRROR_BASE"] ?? "https://mcp.sentient-os.ai"
    }

    /// The coached system prompt the user pastes into ChatGPT/Claude/Gemini (custom instructions).
    /// Naming the connector + "always call get_structure" is what reliably makes the client load and
    /// use the tools — clients lazy-load connector tools behind a search gate (field lessons in
    /// Documentation/MCP Mirror Client.md).
    /// Lives here (the MCP owner) so every surface that offers "Copy System Prompt" shares one copy.
    static let systemPrompt = """
        You have access to the user's personal knowledge base through the Sentient OS MCP: an \
        Obsidian-style vault of markdown notes created just for you, to give you context about their \
        entire life (work, projects, plans, relationships, places, preferences, history…). It was \
        built by Sentient OS privately on their own device from their notes, messages, emails, and files.

        At the start of any conversation where knowing the user could help (that's most of them!), \
        call `get_structure`. It returns the vault's folder and file index, plus the README: a \
        portrait of the user with the most important context. Then call `get_files` to actually \
        read any relevant notes you may want to read.
        """

    struct Stats: Sendable {
        let notesRead24h: Int
        let toolCalls24h: Int
        let lastAccess: Date?
    }

    enum MirrorError: LocalizedError {
        case notEnabled
        case http(Int, String)          // status 0 = no HTTP response at all (proxy / captive portal)
        case zipFailed(String)
        case encryptionFailed           // AES-GCM seal failed — never upload plaintext as a fallback
        case noVault
        case tokenGenerationFailed      // SecRandomCopyBytes failed — never mint a weak/zero key (B3)
        case keychainWriteFailed        // SecItemAdd failed — don't hand out a URL for an unstored key (B3)

        var errorDescription: String? {
            switch self {
            case .notEnabled:            return "The cloud mirror isn't turned on."
            case .http(0, _):            return "Couldn't reach the mirror server (no HTTP response; proxy or captive portal?)."
            case .http(let c, let b):    return "Mirror server returned HTTP \(c). \(b.prefix(200))"
            case .zipFailed(let m):      return "Couldn't package the vault: \(m)"
            case .encryptionFailed:      return "Couldn't encrypt the vault for upload. Please try again."
            case .noVault:               return "There's no vault on disk to mirror yet."
            case .tokenGenerationFailed: return "Couldn't generate a secure mirror key. Please try again."
            case .keychainWriteFailed:   return "Couldn't save the mirror key to the Keychain. Please try again."
            }
        }
    }

    // MARK: Enable / disable

    /// Whether mirroring is currently ON. Deliberately INDEPENDENT of the password's existence: the
    /// password (the identity, Invariant 4) is minted once and kept forever so the share link stays
    /// stable across OFF→ON — it's what the user pasted into ChatGPT/Claude, so toggling must never
    /// reroll it. This flag is the on/off the toggle flips, and what gates auto-push.
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Opt in: mint the password if absent (idempotent — an existing password is kept, so the
    /// share URL is stable) and flip mirroring ON. Returns the share URL.
    @discardableResult
    func enable() throws -> String {
        if Keychain.read(Self.passwordKey) == nil {
            let password = try Self.mintPassword()                   // throws rather than mint a weak key (B3)
            guard Keychain.set(Self.passwordKey, password) else { throw MirrorError.keychainWriteFailed }
            Keychain.delete(Self.legacyTokenKey)                     // sweep any pre-encryption single token
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        guard let url = shareURL else { throw MirrorError.keychainWriteFailed }   // password didn't read back
        Analytics.signal("Mirror.enabled")
        return url
    }

    /// The user-facing MCP connector URL, or nil if not enabled. This is what "Copy MCP Link"
    /// copies and what gets pasted into ChatGPT/Claude. Format: /u_<userID>/p_<password>/mcp.
    var shareURL: String? {
        guard let password = Keychain.read(Self.passwordKey) else { return nil }
        return "\(Self.baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/mcp"
    }

    /// A display-safe version of the share URL: the userID shows (it's public), the PASSWORD is
    /// masked to its first 4 chars. ⚠️ "/mcp" is searched BACKWARDS: the host
    /// "https://mcp.sentient-os.ai" contains "/mcp", and a forward hit inverts the range.
    nonisolated static func maskedURL(_ url: String?) -> String {
        guard let url,
              let pStart = url.range(of: "/p_"),
              let end = url.range(of: "/mcp", options: .backwards),
              pStart.upperBound <= end.lowerBound else { return "mcp.sentient-os.ai/u_…/p_…/mcp" }
        let password = url[pStart.upperBound..<end.lowerBound]
        // Everything up to "/p_" — host + "/u_<userID>" — with the scheme stripped for display.
        let head = url[url.startIndex..<pStart.lowerBound]
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")     // dev SENTIENT_MIRROR_BASE override
        return "\(head)/p_\(password.prefix(4))••••••••/mcp"
    }

    // MARK: Push / delete / stats

    /// Zip the local vault, ENCRYPT it, and replace the mirror with the ciphertext. Renews the
    /// 30-day lease. No-op-safe to call after any vault change (initial gen, daily update, edit).
    func push() async throws {
        guard let password = Keychain.read(Self.passwordKey) else { throw MirrorError.notEnabled }
        let uid = MirrorCrypto.userID(password)
        let root = VaultGenerator.vaultRoot
        guard FileManager.default.fileExists(atPath: root.path) else { throw MirrorError.noVault }

        let zip = try Self.zipDirectory(root)
        defer { try? FileManager.default.removeItem(at: zip) }
        let blob = try MirrorCrypto.encrypt(try Data(contentsOf: zip), password: password, uid: uid)

        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u_\(uid)/p_\(password)/vault")!)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.upload(for: req, from: blob)
        try Self.check(resp, data)
        Analytics.signal("Mirror.pushed")
    }

    /// The one-click delete — removes the cloud copy (and its access log). The local vault
    /// is untouched. The password is kept so re-enabling reuses the same share URL.
    func deleteRemote() async throws {
        guard let password = Keychain.read(Self.passwordKey) else { throw MirrorError.notEnabled }
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/vault")!)
        req.httpMethod = "DELETE"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    /// Opt out: flip mirroring OFF and delete the cloud copy, but KEEP the token so re-enabling
    /// reuses the SAME share URL (it's what the user pasted into ChatGPT/Claude — opting out must
    /// not break those connectors). Best-effort on the network call; the local OFF always sticks.
    func disable() async {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        Analytics.signal("Mirror.disabled")
        try? await deleteRemote()
    }

    /// Mint a NEW password — the remediation if a share URL ever leaks. Deletes the cloud copy
    /// under the OLD identity (best-effort) FIRST-only if the new password persists, replaces the
    /// Keychain identity, and re-pushes if mirroring is on so the new URL serves immediately. The
    /// old URL dies: the user must update their connectors.
    func regenerateToken() async throws -> String {
        // Mint + persist the NEW password BEFORE deleting the old copy — a mint/write failure must
        // never leave the user with no cloud copy AND the old (now-orphaned) identity still active.
        let old = Keychain.read(Self.passwordKey)
        let password = try Self.mintPassword()
        guard Keychain.set(Self.passwordKey, password) else { throw MirrorError.keychainWriteFailed }
        if let old { try? await deleteRemoteFor(password: old) }   // best-effort nuke of the old vault
        Analytics.signal("Mirror.regenerated")
        guard let url = shareURL else { throw MirrorError.keychainWriteFailed }
        if isEnabled { try? await push() }
        return url
    }

    /// DELETE the cloud copy belonging to a SPECIFIC password (used by regenerate to nuke the old
    /// identity after the new one is safely in the Keychain).
    private func deleteRemoteFor(password: String) async throws {
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/vault")!)
        req.httpMethod = "DELETE"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    /// The "your AIs read N notes" numbers for the home screen. nil if not enabled / no vault yet.
    func stats() async throws -> Stats {
        guard let password = Keychain.read(Self.passwordKey) else { throw MirrorError.notEnabled }
        let req = URLRequest(url: URL(string: "\(Self.baseURL)/u_\(MirrorCrypto.userID(password))/p_\(password)/stats")!)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let last = (obj["last_access"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Stats(notesRead24h: obj["notes_read_24h"] as? Int ?? 0,
                     toolCalls24h: obj["tool_calls_24h"] as? Int ?? 0,
                     lastAccess: last)
    }

    // MARK: Helpers

    private static let passwordKey = "mcp.mirror.password"  // Keychain: the root secret (persists)
    private static let legacyTokenKey = "mcp.mirror.token"  // pre-encryption single token — swept on enable
    private static let enabledKey = "mcp.mirror.enabled"    // UserDefaults: the on/off the toggle flips

    /// 18 random bytes → base64url (24 chars, no padding) — inside the server's [16,64] window
    /// and URL-safe, so it drops straight into the path. 144 bits: infeasible to brute-force,
    /// which is what backs both the encryption key and the userID⇄password binding.
    private static func mintPassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        // B3: on failure SecRandomCopyBytes leaves `bytes` all-zero → a predictable identity. Fail
        // loudly instead of ever minting a weak key.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MirrorError.tokenGenerationFailed
        }
        return MirrorCrypto.base64url(Data(bytes))
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        // B4: a non-HTTP response (captive portal / transparent proxy returning something odd) must
        // NOT count as success — that would mark a never-synced vault as synced and clear vaultDirty.
        guard let http = resp as? HTTPURLResponse else { throw MirrorError.http(0, "non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw MirrorError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Zip the vault's CONTENTS into a temp .zip with ROOT-RELATIVE entries (`README.md`,
    /// `Career/Job.md`). We shell to `/usr/bin/zip` from inside the vault dir on purpose:
    /// NSFileCoordinator's `.forUploading` instead wraps everything under the vault folder name
    /// (`Sentient OS - Knowledge Base/…`), which breaks the server's root-relative contract — the README
    /// portrait stops bundling in `get_structure` and every note nests a level too deep. The macOS
    /// `zip` writes UTF-8 names without the 0x800 flag; the server recovers those. (`zip` ships with
    /// macOS; the app is non-sandboxed, so spawning it is fine — same as `CodexCLI`.)
    private static func zipDirectory(_ dir: URL) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-\(UUID().uuidString).zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = dir
        // -r recurse · -X drop extra macOS attributes · -q quiet · "." = the dir CONTENTS (no wrapper).
        proc.arguments = ["-r", "-X", "-q", dst.path, ".", "-x", ".DS_Store", "*/.DS_Store"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() }
        catch { throw MirrorError.zipFailed("couldn't launch /usr/bin/zip: \(error.localizedDescription)") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: dst.path) else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MirrorError.zipFailed("zip exited \(proc.terminationStatus): \(msg.prefix(200))")
        }
        return dst
    }
}

// MARK: - Keychain (first user: a tiny generic-password helper)

/// Minimal Keychain wrapper for small secrets (the mirror tokens). One service, key = account.
enum Keychain {
    private static let service = "ai.sentient-os.app"

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess   // B3: surface a failed persist
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
