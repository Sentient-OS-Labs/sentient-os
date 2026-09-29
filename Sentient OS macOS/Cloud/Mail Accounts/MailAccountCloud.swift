// MailAccountCloud.swift
// Saves disclosed mail addresses and a private installation session in Keychain, then syncs
// an atomic owner-scoped snapshot to Supabase. A failed sync stays pending across launches.
// Doc: Documentation - Connected Email Accounts.md

import Foundation
import Security

actor MailAccountCloud {
    static let shared = MailAccountCloud()
    private let session: URLSession
    private let storageKey: String
    private var state: State?
    private var syncTask: Task<Void, Error>?
    private var retryTask: Task<Void, Never>?
    private var retryGeneration = 0
    private var deleting = false

    private struct State: Codable {
        var accounts: [MailAccount] = []
        var auth: AuthSession?
        var pending = false
        var revision = 0
        var remoteDeleted = false
    }
    private struct AuthSession: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: TimeInterval
        let userID: UUID
    }
    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: UUID; let is_anonymous: Bool? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
    }

    init(session: URLSession = .shared, storageKey: String = "connected-email.state.v1") {
        self.session = session; self.storageKey = storageKey
    }

    func savedAccounts() throws -> [MailAccount] { try load().accounts }
    func hasPendingSync() throws -> Bool { try load().pending }

    /// Collection replaces only the requested provider/engine. Other
    /// engines remain independent; identical email addresses never merge installation owners.
    func save(_ accounts: [MailAccount], engine: MailAccount.Engine, provider: MailAccount.Provider? = nil,
              preservingConnectionIDs: Set<String> = []) async throws -> Bool {
        guard !deleting else { throw MailAccountError.busy }
        guard !accounts.isEmpty, accounts.count <= 32,
              accounts.allSatisfy({ $0.engine == engine && (provider == nil || $0.provider == provider)
                  && $0.consentVersion == 1 && MailAccount.normalizedEmail($0.email) == $0.email }),
              Set(accounts.map(\.id)).count == accounts.count else { throw MailAccountError.invalidAddress }
        var next = try load()
        let incomingIDs = Set(accounts.map(\.id))
        // A skipped lookup must not erase a previously saved address for that connection.
        next.accounts.removeAll {
            $0.engine == engine && (provider == nil || $0.provider == provider)
                && (!preservingConnectionIDs.contains($0.id) || incomingIDs.contains($0.id))
        }
        next.accounts += accounts
        guard next.accounts.count <= 32 else { throw MailAccountError.invalidResponse }
        next.pending = true; next.revision += 1
        try persist(next)
        do { try await sync(); return true }
        catch { scheduleRetry(); return false }
    }

    func retryPendingSync() async {
        guard !deleting, (try? load().pending) == true else { return }
        do { try await sync() } catch { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard retryTask == nil, !deleting else { return }
        retryGeneration += 1
        let generation = retryGeneration
        retryTask = Task {
            var delay: UInt64 = 5
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { break }
                guard !deleting, (try? load().pending) == true else { break }
                do { try await sync() } catch { /* Keep the encrypted local snapshot pending. */ }
                delay = min(delay * 3, 300)
            }
            if retryGeneration == generation { retryTask = nil }
        }
    }

    private func sync() async throws {
        if let syncTask { try await syncTask.value; return }
        let task = Task { try await drain() }
        syncTask = task
        defer { syncTask = nil }
        try await task.value
    }

    private func drain() async throws {
        while try load().pending {
            let snapshot = try load()
            let data = try JSONEncoder().encode(snapshot.accounts)
            let accounts = try JSONSerialization.jsonObject(with: data)
            _ = try await authenticatedRequest(path: "rest/v1/rpc/sync_connected_email_accounts", body: ["accounts": accounts])
            // A newer edit made while the request was in flight must remain pending.
            var current = try load()
            if current.revision == snapshot.revision { current.pending = false; try persist(current) }
        }
    }

    /// Remote deletion must succeed before the only credential that can authorize it is lost.
    /// Reset/uninstall can retry this operation without claiming an offline deletion succeeded.
    func erase() async throws {
        guard !deleting else { throw MailAccountError.busy }
        deleting = true; defer { deleting = false }
        retryGeneration += 1; retryTask?.cancel(); retryTask = nil
        if let syncTask { _ = try? await syncTask.value }
        var current = try load()
        if !current.remoteDeleted, current.auth != nil {
            _ = try await authenticatedRequest(path: "rest/v1/rpc/delete_connected_email_identity", body: [:])
            current = try load(); current.remoteDeleted = true
            // Preserve a successful remote deletion even if a later Keychain operation fails.
            state = current
            try persist(current)
        }
        try MailAccountKeychain.remove(storageKey)
        state = State()
    }

    private func authenticatedSession() async throws -> AuthSession {
        let current = try load()
        if let auth = current.auth, auth.expiresAt > Date().timeIntervalSince1970 + 90 { return auth }
        let data: Data
        if let auth = current.auth {
            data = try await request(path: "auth/v1/token", query: "grant_type=refresh_token", body: ["refresh_token": auth.refreshToken])
        } else {
            data = try await request(path: "auth/v1/signup", body: [:])
        }
        let response = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard response.user.is_anonymous == true, !response.access_token.isEmpty, !response.refresh_token.isEmpty,
              current.auth == nil || current.auth?.userID == response.user.id else { throw MailAccountError.invalidResponse }
        let auth = AuthSession(accessToken: response.access_token, refreshToken: response.refresh_token,
            expiresAt: Date().timeIntervalSince1970 + response.expires_in, userID: response.user.id)
        var updated = try load(); updated.auth = auth; try persist(updated)
        return auth
    }

    private func authenticatedRequest(path: String, body: [String: Any]) async throws -> Data {
        let auth = try await authenticatedSession()
        do { return try await request(path: path, body: body, token: auth.accessToken) }
        catch MailAccountError.signedOut {
            // A server can reject an access token before its local expiry. Refresh once;
            // never create a new owner when the existing refresh credential is rejected.
            var current = try load()
            current.auth = AuthSession(accessToken: auth.accessToken, refreshToken: auth.refreshToken,
                                       expiresAt: 0, userID: auth.userID)
            try persist(current)
            let refreshed = try await authenticatedSession()
            return try await request(path: path, body: body, token: refreshed.accessToken)
        }
    }

    private func request(path: String, query: String? = nil, body: [String: Any], token: String? = nil) async throws -> Data {
        var components = URLComponents(url: MailAccountCloudConfiguration.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query
        guard let url = components.url else { throw MailAccountError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(MailAccountCloudConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MailAccountError.requestFailed }
        guard (200..<300).contains(http.statusCode) else {
            // Never log response bodies, addresses, bearer tokens or Supabase error descriptions.
            if http.statusCode == 401 { throw MailAccountError.signedOut }
            throw MailAccountError.requestFailed
        }
        return data
    }

    private func load() throws -> State {
        if let state { return state }
        let value: State
        if let data = try MailAccountKeychain.read(storageKey) { value = try JSONDecoder().decode(State.self, from: data) }
        else { value = State() }
        state = value; return value
    }
    private func persist(_ value: State) throws {
        try MailAccountKeychain.write(storageKey, data: JSONEncoder().encode(value))
        state = value
    }
}

/// ThisDeviceOnly prevents a copied installation session from silently linking different Macs.
/// A locked/unavailable Keychain is an error, never interpreted as a new installation.
private nonisolated enum MailAccountKeychain {
    private static func identity(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ai.sentient-os.connected-email", kSecAttrAccount as String: key]
    }
    static func read(_ key: String) throws -> Data? {
        var query = identity(key); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MailAccountError.keychain }
        return data
    }
    static func write(_ key: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(identity(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw MailAccountError.keychain }
        var item = identity(key); item.merge(attributes) { _, new in new }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MailAccountError.keychain }
    }
    static func remove(_ key: String) throws {
        let status = SecItemDelete(identity(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MailAccountError.keychain }
    }
}
