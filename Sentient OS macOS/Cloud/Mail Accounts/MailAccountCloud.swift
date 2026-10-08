// MailAccountCloud.swift
// Queues only disclosed email addresses in Keychain until Supabase accepts them.
// The feedback list stores addresses alone; its Auth session is never attached to a contact row.
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
    private var forgetting = false

    private struct State: Codable {
        var pendingEmails: [String] = []
        var auth: AuthSession?

        init() {}

        private enum CodingKeys: String, CodingKey { case pendingEmails, auth, accounts }
        private struct LegacyAddress: Decodable { let email: String }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            auth = try container.decodeIfPresent(AuthSession.self, forKey: .auth)
            let addresses: [String]
            if container.contains(.pendingEmails) {
                addresses = try container.decode([String].self, forKey: .pendingEmails)
            } else {
                // Discard all old connector metadata, including for already-synced contacts.
                addresses = try container.decodeIfPresent([LegacyAddress].self, forKey: .accounts)?.map(\.email) ?? []
            }
            let normalized = addresses.compactMap(MailAccount.normalizedEmail)
            guard normalized.count == addresses.count else { throw MailAccountError.invalidAddress }
            pendingEmails = Set(normalized).sorted()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pendingEmails, forKey: .pendingEmails)
            try container.encodeIfPresent(auth, forKey: .auth)
        }
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

    func hasPendingSync() throws -> Bool {
        do { return try !load().pendingEmails.isEmpty }
        catch {
            if let counts = Diagnostics.backgroundFailure(.mailAccount) {
                Diagnostics.report(.serviceFailed, phase: .read, reason: "pending_contact_state", error: error,
                                   source: "mail_account", counts: counts, cooldown: 86_400)
            }
            throw error
        }
    }

    /// Add addresses without retaining their connector, source, or installation identity in the list.
    func save(_ emails: [String]) async throws -> Bool {
        guard !forgetting else { throw MailAccountError.busy }
        let normalized = emails.compactMap(MailAccount.normalizedEmail)
        guard !emails.isEmpty, emails.count <= 32, normalized.count == emails.count else {
            throw MailAccountError.invalidAddress
        }
        var next = try load()
        next.pendingEmails = Set(next.pendingEmails + normalized).sorted()
        try persist(next)
        do { try await sync(); return true }
        catch { scheduleRetry(); return false }
    }

    func retryPendingSync() async {
        guard !forgetting, (try? hasPendingSync()) == true else { return }
        do { try await sync() } catch { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard retryTask == nil, !forgetting, (try? hasPendingSync()) == true else { return }
        retryGeneration += 1
        let generation = retryGeneration
        retryTask = Task {
            var delay: UInt64 = 5
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { break }
                guard !forgetting, (try? hasPendingSync()) == true else { break }
                do { try await sync() } catch { /* Keep only the queued addresses for retry. */ }
                delay = min(delay * 3, 300)
            }
            if retryGeneration == generation { retryTask = nil }
        }
    }

    private func sync() async throws {
        if let syncTask { try await syncTask.value; return }
        let task = Task {
            // Clear the shared task before waking callers, so a new save cannot join an
            // already-completed drain and leave its address stranded until the next launch.
            defer { syncTask = nil }
            do { try await drain(); Diagnostics.backgroundRecovered(.mailAccount) }
            catch {
                if !Diagnostics.isCancellation(error), let counts = Diagnostics.backgroundFailure(.mailAccount) {
                    Diagnostics.report(.serviceFailed, phase: .publish, reason: "pending_contact_sync", error: error,
                                       source: "mail_account", counts: counts, flags: [.retriable: true], cooldown: 86_400)
                }
                throw error
            }
        }
        syncTask = task
        try await task.value
    }

    private func drain() async throws {
        while try hasPendingSync() {
            try Task.checkCancellation()
            let emails = Array(try load().pendingEmails.prefix(32))
            _ = try await authenticatedRequest(path: "rest/v1/rpc/add_feedback_emails", body: ["emails": emails])
            try Task.checkCancellation()
            // New addresses queued during the request remain pending for the next batch.
            var current = try load()
            current.pendingEmails.removeAll { emails.contains($0) }
            try persist(current)
        }
    }

    /// Uninstall clears this Mac's contact snapshot and credentials without deleting cloud records.
    /// Stop outstanding work first so a late response cannot restore the removed Keychain item.
    func forgetLocalState() async throws {
        guard !forgetting else { throw MailAccountError.busy }
        forgetting = true; defer { forgetting = false }
        retryGeneration += 1; retryTask?.cancel(); retryTask = nil
        syncTask?.cancel()
        if let syncTask { _ = try? await syncTask.value }
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
        if let data = try MailAccountKeychain.read(storageKey) {
            value = try JSONDecoder().decode(State.self, from: data)
            // Rewrite legacy snapshots immediately so old connector details do not linger locally.
            try MailAccountKeychain.write(storageKey, data: JSONEncoder().encode(value))
        }
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
