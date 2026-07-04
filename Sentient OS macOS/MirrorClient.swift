//
//  MirrorClient.swift
//  Sentient OS macOS
//
//  The app side of the hosted MCP mirror (Arch §7). Mirrors the local vault to our one
//  persistent backend so the user's ChatGPT/Claude can read it over MCP. Opt-in, opt-out,
//  one-click delete — the Mac's vault is always canonical; the mirror is a disposable copy.
//
//  IDENTITY = ONE TOKEN, NO ACCOUNTS (Invariant 4):
//   A single random token in the share URL (mcp.sentient-os.ai/u/<token>/mcp) is the identity.
//   It authorizes everything — MCP reads AND push/delete/stats — so push/delete carry no auth
//   header. Tradeoff: anyone who sees the share URL can also overwrite/delete the vault;
//   mitigated by no accounts, the 30-day lease, one-click delete, and the vault being
//   PII-stripped. The token is minted once on opt-in and kept in the Keychain; losing it is a
//   non-event (mint a new one, re-push; the orphaned cloud copy expires on its 30-day lease).
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

    /// The coached system prompt the user pastes into ChatGPT/Claude/Gemini (custom instructions).
    /// Naming the connector + "always call get_structure" is what reliably makes the client load and
    /// use the tools — clients lazy-load connector tools behind a search gate (Arch §7 field learnings).
    /// Lives here (the MCP owner) so every surface that offers "Copy System Prompt" shares one copy.
    static let systemPrompt = """
        Use the Sentient OS MCP whenever relevant. It gives you access to the user's personal knowledge \
        base, created just for you! It's basically an Obsidian vault of notes about their actual life: \
        their work, projects, plans, relationships, places, preferences, and history, built from their \
        entire digital life (notes, messages, emails, etc.) using on-device LLMs that analyzed their \
        whole digital life.

        In fact, using it would help you improve almost anything you need to help the user with!

        ALWAYS call get_structure at the start of ANY chat with the user.

        It returns the folder and file-name index structure of the vault (so you can know if there's \
        anything you want to read in full), and it also returns the README file of the vault with some \
        incredible general context. So ALWAYS call this at the start of EVERY chat.

        And yeah, any time you think another file is really relevant to a conversation/prompt, go read \
        it in full using get_files!
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
        case noVault
        case tokenGenerationFailed      // SecRandomCopyBytes failed — never mint a weak/zero token (B3)
        case keychainWriteFailed        // SecItemAdd failed — don't hand out a URL for an unstored token (B3)

        var errorDescription: String? {
            switch self {
            case .notEnabled:            return "The cloud mirror isn't turned on."
            case .http(0, _):            return "Couldn't reach the mirror server (no HTTP response — proxy or captive portal?)."
            case .http(let c, let b):    return "Mirror server returned HTTP \(c). \(b.prefix(200))"
            case .zipFailed(let m):      return "Couldn't package the vault: \(m)"
            case .noVault:               return "There's no vault on disk to mirror yet."
            case .tokenGenerationFailed: return "Couldn't generate a secure mirror key. Please try again."
            case .keychainWriteFailed:   return "Couldn't save the mirror key to the Keychain. Please try again."
            }
        }
    }

    // MARK: Enable / disable

    /// Whether mirroring is currently ON. Deliberately INDEPENDENT of the token's existence: the
    /// token (the identity, Invariant 4) is minted once and kept forever so the share link stays
    /// stable across OFF→ON — it's what the user pasted into ChatGPT/Claude, so toggling must never
    /// reroll it. This flag is the on/off the toggle flips, and what gates auto-push.
    var isEnabled: Bool {
        let d = UserDefaults.standard
        // Migrate pre-flag builds, which equated "enabled" with "a token exists".
        if d.object(forKey: Self.enabledKey) == nil { return Keychain.read(Self.tokenKey) != nil }
        return d.bool(forKey: Self.enabledKey)
    }

    /// Opt in: mint the token if absent (idempotent — an existing token is kept, so the share URL
    /// is stable) and flip mirroring ON. Returns the share URL.
    @discardableResult
    func enable() throws -> String {
        if Keychain.read(Self.tokenKey) == nil {
            let token = try Self.mintToken()                         // throws rather than mint a weak token (B3)
            guard Keychain.set(Self.tokenKey, token) else { throw MirrorError.keychainWriteFailed }
        }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        guard let url = shareURL else { throw MirrorError.keychainWriteFailed }   // token didn't read back
        Analytics.signal("Mirror.enabled")
        return url
    }

    /// The user-facing MCP connector URL, or nil if not enabled. This is what "Copy MCP Link"
    /// copies and what gets pasted into ChatGPT/Claude.
    var shareURL: String? {
        guard let token = Keychain.read(Self.tokenKey) else { return nil }
        return "\(Self.baseURL)/u/\(token)/mcp"
    }

    // MARK: Push / delete / stats

    /// Zip the local vault and replace the mirror with it. Renews the 30-day lease.
    /// No-op-safe to call after any vault change (initial gen, daily update, user edit).
    func push() async throws {
        guard let token = Keychain.read(Self.tokenKey) else { throw MirrorError.notEnabled }
        let root = VaultGenerator.vaultRoot
        guard FileManager.default.fileExists(atPath: root.path) else { throw MirrorError.noVault }

        let zip = try Self.zipDirectory(root)
        defer { try? FileManager.default.removeItem(at: zip) }

        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u/\(token)/vault")!)
        req.httpMethod = "POST"
        req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: zip)
        try Self.check(resp, data)
        Analytics.signal("Mirror.pushed")
    }

    /// The one-click delete — removes the cloud copy (and its access log). The local vault
    /// is untouched. The token is kept so re-enabling reuses the same share URL.
    func deleteRemote() async throws {
        guard let token = Keychain.read(Self.tokenKey) else { throw MirrorError.notEnabled }
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u/\(token)/vault")!)
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

    /// Mint a NEW token — the remediation if a share URL ever leaks. Deletes the cloud copy under
    /// the OLD token (best-effort), replaces the Keychain identity, and re-pushes if mirroring is on
    /// so the new URL serves immediately. The old URL dies: the user must update their connectors.
    func regenerateToken() async throws -> String {
        try? await deleteRemote()
        let token = try Self.mintToken()
        guard Keychain.set(Self.tokenKey, token) else { throw MirrorError.keychainWriteFailed }
        Analytics.signal("Mirror.regenerated")
        guard let url = shareURL else { throw MirrorError.keychainWriteFailed }
        if isEnabled { try? await push() }
        return url
    }

    /// The "your AIs read N notes" numbers for the home screen. nil if not enabled / no vault yet.
    func stats() async throws -> Stats {
        guard let token = Keychain.read(Self.tokenKey) else { throw MirrorError.notEnabled }
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/u/\(token)/stats")!)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let last = (obj["last_access"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Stats(notesRead24h: obj["notes_read_24h"] as? Int ?? 0,
                     toolCalls24h: obj["tool_calls_24h"] as? Int ?? 0,
                     lastAccess: last)
    }

    // MARK: Helpers

    private static let tokenKey = "mcp.mirror.token"      // Keychain: the identity (persists)
    private static let enabledKey = "mcp.mirror.enabled"  // UserDefaults: the on/off the toggle flips

    /// 32 random bytes → base64url (43 chars, no padding) — inside the server's [32,64] window
    /// and URL-safe, so it drops straight into the path.
    private static func mintToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // B3: on failure SecRandomCopyBytes leaves `bytes` all-zero → a predictable identity. Fail
        // loudly instead of ever minting a weak token.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MirrorError.tokenGenerationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
