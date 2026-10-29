// Authenticates hosted inference independently of subscriptions, invitations and feedback contacts.
// start/usage/control use bounded, redirect-free requests; refresh never replaces a saved identity.
// Doc: Cloud/Documentation - Cloud - Frontier Model Choice (BYOM).md

import Foundation
import Security

nonisolated struct HostedInferenceConfiguration: Sendable {
    let gatewayURL: URL
    let identityURL: URL
    let publishableKey: String

    static var current: Self? {
        var endpoint = Bundle.main.object(forInfoDictionaryKey: "SentientInferenceURL") as? String ?? ""
        #if DEBUG
        endpoint = UserDefaults.standard.string(forKey: "sentient.hosted.gatewayURL") ?? endpoint
        #endif
        guard let gateway = URL(string: endpoint), validEndpoint(gateway) else { return nil }
        let identity = Bundle.main.object(forInfoDictionaryKey: "SentientInferenceIdentityURL") as? String
            ?? "https://hjqedlalhfoxwehxhton.supabase.co"
        let key = Bundle.main.object(forInfoDictionaryKey: "SentientInferencePublishableKey") as? String
            ?? "sb_publishable_MFHS0LDzdAW1lGyEf1MUig_BzqObIr9"
        guard let identityURL = URL(string: identity), validEndpoint(identityURL), !key.isEmpty else { return nil }
        return Self(gatewayURL: gateway, identityURL: identityURL, publishableKey: key)
    }

    static func validEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        if parts.scheme == "https" { return true }
        #if DEBUG
        return parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
        #else
        return false
        #endif
    }
}

actor HostedInferenceClient {
    static let shared = HostedInferenceClient()
    typealias Failure = HostedInference.Failure

    nonisolated struct CredentialStore: Sendable {
        let read: @Sendable () throws -> Data?
        let write: @Sendable (Data) throws -> Void
        static let keychain = Self(read: { try HostedInferenceCredential.read() },
                                   write: { try HostedInferenceCredential.write($0) })
    }

    private struct Identity: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userID: String
        let origin: String
    }

    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: String; let is_anonymous: Bool }
        let access_token: String
        let refresh_token: String
        let expires_in: TimeInterval
        let user: User
    }

    private struct RunResponse: Decodable {
        let run_id: String
        let run_token: String
        let model: String
        let remaining_seconds: TimeInterval
        let phase: String
        let purpose: String
        let server_time: String
        let lease_expires_at: String
        let maximum_output_tokens: Int
    }

    private let configuration: @Sendable () -> HostedInferenceConfiguration?
    private let session: URLSession
    private let credentials: CredentialStore
    private var authentication: Task<Identity, Error>?
    private var pendingIdentity: Identity?
    private var controls: [String: (id: UUID, task: Task<Void, Error>)] = [:]

    init(configuration: @escaping @Sendable () -> HostedInferenceConfiguration? = { .current },
         session: URLSession? = nil, credentials: CredentialStore = .keychain) {
        self.configuration = configuration; self.credentials = credentials
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
            settings.requestCachePolicy = .reloadIgnoringLocalCacheData
            settings.timeoutIntervalForRequest = 12; settings.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: settings, delegate: HostedInferenceRedirectPolicy(), delegateQueue: nil)
        }
    }

    func usage() async throws -> HostedInference.Usage {
        let config = try configured()
        let response = try await authorized(config, path: "v1/usage", method: "GET")
        guard let value = try? Self.decoder().decode(HostedInference.Usage.self, from: response.data),
              value.dailyLimitSeconds > 0, value.dailyLimitSeconds.isFinite,
              value.remainingSeconds >= 0, value.remainingSeconds <= value.dailyLimitSeconds,
              value.usedSeconds >= 0, value.usedSeconds.isFinite else { throw Failure.invalidResponse }
        return value
    }

    func start(purpose: HostedInference.Purpose) async throws -> HostedInference.Run {
        try Task.checkCancellation()
        let config = try configured()
        let response = try await authorized(config, path: "v1/runs", method: "POST", body: ["purpose": purpose.rawValue])
        guard let result = try? JSONDecoder().decode(RunResponse.self, from: response.data),
              UUID(uuidString: result.run_id) != nil, result.run_token.count >= 24,
              result.run_token.count <= 8192 else { throw Failure.invalidResponse }
        // Once admission credentials are known, every later validation failure must finish
        // that run too. Authentication time precedes admission and is not part of its lease.
        let run = HostedInference.Run(id: result.run_id, gatewayURL: config.gatewayURL,
            token: result.run_token, model: result.model, remainingSeconds: result.remaining_seconds,
            purpose: purpose, client: self, deadline: 0, maximumOutputTokens: result.maximum_output_tokens)
        do {
            guard result.phase == "running", result.purpose == purpose.rawValue,
                  result.model.hasPrefix("claude-"), result.model.count <= 100,
                  result.model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
                  result.remaining_seconds.isFinite, result.remaining_seconds >= 0,
                  (1...65_536).contains(result.maximum_output_tokens) else { throw Failure.invalidResponse }
            run.renew(deadline: try Self.deadline(serverTime: result.server_time,
                expires: result.lease_expires_at, paused: false, sentAt: response.sentAt), paused: false)
            try Task.checkCancellation()
            return run
        } catch {
            await run.finish()
            throw error
        }
    }

    func control(_ run: HostedInference.Run, action: String) async throws {
        try Task.checkCancellation()
        let preceding = controls[run.id]?.task
        let id = UUID()
        let task = Task { [self] in
            // Serialize both requests and replies. An old heartbeat must never overwrite a
            // newer pause/resume acknowledgement after URLSession resumes this actor.
            if let preceding { _ = try? await preceding.value }
            try Task.checkCancellation()
            try await performControl(run, action: action)
        }
        controls[run.id] = (id, task)
        defer { if controls[run.id]?.id == id { controls.removeValue(forKey: run.id) } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func performControl(_ run: HostedInference.Run, action: String) async throws {
        guard ["heartbeat", "pause", "resume", "finish"].contains(action) else { throw Failure.invalidResponse }
        let sentAt = ProcessInfo.processInfo.systemUptime
        let data = try await request(run.gatewayURL, path: "v1/runs/\(run.id)/\(action)", method: "POST", token: run.token, body: [:])
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidResponse }
        if action != "finish" {
            guard let phase = object["phase"] as? String, ["running", "waiting_for_user"].contains(phase) else {
                throw Failure.rejected(code: "run_expired", resetAt: nil)
            }
            guard (action != "pause" || phase == "waiting_for_user"),
                  (action != "resume" || phase == "running") else { throw Failure.invalidResponse }
            if phase == "running", run.purpose == .sidekick,
               let remaining = object["remaining_seconds"] as? Double, remaining <= 0 {
                throw Failure.rejected(code: "daily_allowance_exhausted", resetAt: nil)
            }
            guard let serverTime = object["server_time"] as? String,
                  let expires = object["lease_expires_at"] as? String else { throw Failure.invalidResponse }
            run.renew(deadline: try Self.deadline(serverTime: serverTime, expires: expires,
                paused: phase == "waiting_for_user", sentAt: sentAt), paused: phase == "waiting_for_user")
        }
    }

    private func configured() throws -> HostedInferenceConfiguration {
        guard let config = configuration() else { throw Failure.notConfigured }
        return config
    }

    private func authorized(_ config: HostedInferenceConfiguration, path: String, method: String,
                            body: [String: String]? = nil) async throws -> (data: Data, sentAt: TimeInterval) {
        let first = try await identity(config)
        let sentAt = ProcessInfo.processInfo.systemUptime
        do {
            let data = try await request(config.gatewayURL, path: path, method: method, token: first.accessToken, body: body)
            return (data, sentAt)
        }
        catch Failure.rejected(let code, _) where ["authentication_required", "invalid_token", "http_401"].contains(code) {
            // A rejected JWT did not authorize work. Refresh the same principal once; never
            // enroll a replacement identity or retry an uncertain admitted request.
            let refreshed = try await identity(config, rejectedAccessToken: first.accessToken)
            let retriedAt = ProcessInfo.processInfo.systemUptime
            let data = try await request(config.gatewayURL, path: path, method: method, token: refreshed.accessToken, body: body)
            return (data, retriedAt)
        }
    }

    private func identity(_ config: HostedInferenceConfiguration, rejectedAccessToken: String? = nil) async throws -> Identity {
        if let pendingIdentity {
            try credentials.write(JSONEncoder().encode(pendingIdentity))
            self.pendingIdentity = nil
        }
        if let authentication { return try await authentication.value }
        let stored = try credentials.read()
        let existing: Identity?
        if let stored {
            guard let value = try? JSONDecoder().decode(Identity.self, from: stored),
                  value.origin == config.identityURL.absoluteString else { throw Failure.identity }
            existing = value
            if value.accessToken != rejectedAccessToken, value.expiresAt > Date().addingTimeInterval(60) { return value }
        } else { existing = nil }
        let task = Task { [self] in
            let path = existing == nil ? "auth/v1/signup" : "auth/v1/token"
            let query = existing == nil ? nil : "grant_type=refresh_token"
            let body = existing.map { ["refresh_token": $0.refreshToken] } ?? [:]
            let data: Data
            do {
                data = try await request(config.identityURL, path: path, query: query, method: "POST",
                    publicKey: config.publishableKey, body: body)
            } catch let error as Failure {
                if existing != nil, case .rejected(let code, _) = error,
                   ["authentication_required", "invalid_token", "identity_invalid", "http_400", "http_401", "http_403"].contains(code) {
                    throw Failure.identity
                }
                throw error
            }
            guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data),
                  response.user.is_anonymous, UUID(uuidString: response.user.id) != nil,
                  !response.access_token.isEmpty, !response.refresh_token.isEmpty,
                  response.expires_in.isFinite, response.expires_in > 0,
                  existing == nil || existing?.userID == response.user.id else { throw Failure.identity }
            let value = Identity(accessToken: response.access_token, refreshToken: response.refresh_token,
                expiresAt: Date().addingTimeInterval(response.expires_in), userID: response.user.id,
                origin: config.identityURL.absoluteString)
            pendingIdentity = value
            try credentials.write(JSONEncoder().encode(value))
            pendingIdentity = nil
            return value
        }
        authentication = task
        defer { authentication = nil }
        return try await task.value
    }

    private func request(_ base: URL, path: String, query: String? = nil, method: String,
                         token: String? = nil, publicKey: String? = nil,
                         body: [String: String]? = nil) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = query
        guard let url = components?.url else { throw Failure.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let publicKey { request.setValue(publicKey, forHTTPHeaderField: "apikey") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw Failure.unavailable }
        guard data.count <= 65_536, let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let code = (error?["code"] as? String) ?? (object?["code"] as? String) ?? "http_\(http.statusCode)"
            // Provider text is never promoted into UI, logs, or analytics.
            let safeCode = code.count < 80 && code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
                ? code : "request_rejected"
            let reset = ((error?["reset_at"] ?? object?["reset_at"]) as? String).flatMap(Self.date)
            throw Failure.rejected(code: safeCode, resetAt: reset)
        }
        return data
    }

    private nonisolated static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private nonisolated static func deadline(serverTime: String, expires: String,
                                              paused: Bool, sentAt: TimeInterval) throws -> TimeInterval {
        guard let now = date(serverTime), let end = date(expires) else { throw Failure.invalidResponse }
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0, seconds <= (paused ? 86_401 : 121) else { throw Failure.invalidResponse }
        // Anchor to send time, not receipt or the Mac's wall clock. A delayed response can
        // shorten a lease locally, but can never extend the server's authorization.
        let deadline = sentAt + seconds
        guard deadline > ProcessInfo.processInfo.systemUptime else {
            throw Failure.rejected(code: "lease_expired", resetAt: nil)
        }
        return deadline
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = Self.date(value) else { throw Failure.invalidResponse }
            return date
        }
        return decoder
    }
}

private nonisolated final class HostedInferenceRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private nonisolated enum HostedInferenceCredential {
    private static let service = "ai.sentient-os.hosted-inference"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }
    static func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HostedInference.Failure.keychain }
        return data
    }
    static func write(_ data: Data) throws {
        var query = query
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw HostedInference.Failure.keychain }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw HostedInference.Failure.keychain }
    }
}
