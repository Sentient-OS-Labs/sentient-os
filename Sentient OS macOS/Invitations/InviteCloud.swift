// InviteCloud.swift
// Supabase invitation RPCs and a dedicated anonymous Auth session, persisted in Keychain.
// Only server-confirmed redemptions grant lifetime access; refresh never replaces an identity.
// Schema: supabase/migrations/ (repository root).

import Foundation
import Security

nonisolated struct InviteSnapshot: Codable, Equatable, Sendable {
    let code: String?
    let campaignActive: Bool
    let endsAt: Double?
    let redeemedAt: Double?
    let redemptionCount: Int
    var lateUse: InviteLateUse? = nil
    var lifetimeUpgrade: InviteLifetimeUpgrade? = nil

    var hasLifetimeAccess: Bool { redeemedAt != nil }
    var hasRecordedGift: Bool { hasLifetimeAccess || lateUse != nil }
    var showsLateGift: Bool { !hasLifetimeAccess && lateUse != nil }
    var canShare: Bool {
        campaignActive && code != nil && (endsAt.map { $0 > Date().timeIntervalSince1970 } ?? true)
    }

    static func normalize(_ code: String) -> String {
        // Preserve custom spelling and separators. Supabase owns case-insensitive lookup
        // and compatibility with previously shared, formatted codes.
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidCode(_ code: String) -> Bool {
        !normalize(code).isEmpty
    }
}

nonisolated struct InviteLifetimeUpgrade: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let upgradedAt: Double
    var seenAt: Double? = nil
    var notificationClaimedAt: Double? = nil

    var isValid: Bool {
        upgradedAt.isFinite && upgradedAt > 0
            && (seenAt.map { $0.isFinite && $0 > 0 } ?? true)
            && (notificationClaimedAt.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

/// An acknowledgement of using a closed code, deliberately separate from an access grant.
nonisolated struct InviteLateUse: Codable, Equatable, Sendable {
    static let code = "FINAL_1000"
    static let message = "This code is at capacity, unfortunately. But we're still happy to give you a couple of weeks of free unlimited Sidekick :)"
    let code: String
    let recordedAt: Double
    let email: String

    static func matches(_ code: String) -> Bool { InviteSnapshot.normalize(code).uppercased() == Self.code }
    var isValid: Bool {
        code == Self.code && recordedAt.isFinite && recordedAt > 0
            && MailAccount.normalizedEmail(email) == email
    }
}

actor InviteCloud {
    static let shared = InviteCloud()
    static let projectURL = URL(string: "https://hjqedlalhfoxwehxhton.supabase.co")!
    // Publishable, never a service-role key. Auth + the RPCs enforce ownership.
    static let publishableKey = "sb_publishable_MFHS0LDzdAW1lGyEf1MUig_BzqObIr9"

    nonisolated enum Failure: Error, LocalizedError {
        case keychain, identity, unavailable, response, rejected(String)
        var errorDescription: String? {
            switch self {
            case .keychain: return "Unlock your Mac and try again. Your invite couldn't be saved securely."
            case .identity: return "Your saved invite access couldn't be restored. Please contact Sentient support."
            case .unavailable: return "Couldn't reach Sentient. Check your connection and try again."
            case .response: return "Couldn't verify the invite. Please try again."
            case .rejected(let code):
                switch code {
                case "invalid_code": return "That invite code wasn't found. Check it and try again."
                case "own_code": return "That's your own invite code. Share it with a friend."
                case "offer_ended": return "This invite offer has ended."
                case "email_required": return "Enter a valid email so we can save your gift."
                case "rate_limited": return "Too many attempts. Please try again in an hour."
                default: return "Couldn't redeem this invite. Please try again."
                }
            }
        }
    }

    private nonisolated struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
        let userID: UUID
    }
    private nonisolated struct AuthResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
        struct User: Decodable { let id: UUID; let is_anonymous: Bool }
    }
    private var pendingSession: Session?
    private let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    // Main-actor InviteProgram serializes operations, including token rotation.
    func fetch(redeeming code: String? = nil, acknowledgingUpgrade id: UUID? = nil) async throws -> InviteSnapshot {
        let name = id != nil ? "acknowledge_invite_upgrade" : code == nil ? "invite_status" : "redeem_invite"
        let body = id.map { ["p_notice_id": $0.uuidString] }
            ?? code.map { ["p_code": InviteSnapshot.normalize($0)] } ?? [:]
        let data = try await rpc(name, body: body)
        let snapshot = try Self.verifiedSnapshot(from: data, redeeming: code)
        if let id {
            guard snapshot.lifetimeUpgrade?.id == id, snapshot.lifetimeUpgrade?.seenAt != nil else { throw Failure.response }
        }
        return snapshot
    }

    func claimUpgradeNotification(_ id: UUID) async throws -> Bool {
        struct Claim: Decodable { let claimed: Bool }
        let data = try await rpc("claim_invite_upgrade_notification", body: ["p_notice_id": id.uuidString])
        guard let claim = try? JSONDecoder().decode(Claim.self, from: data) else { throw Failure.response }
        return claim.claimed
    }

    private func rpc(_ name: String, body: [String: String]) async throws -> Data {
        var session = try await authenticatedSession()
        let path = "rest/v1/rpc/" + name
        var result = try await request(path, body: body, token: session.accessToken)
        if result.1 == 401 {
            session = try await authenticatedSession(forceRefresh: true)
            result = try await request(path, body: body, token: session.accessToken)
        }
        guard result.1 == 200 else { throw Failure.unavailable }
        if let error = try? JSONDecoder().decode(RPCError.self, from: result.0) {
            throw Failure.rejected(error.error)
        }
        return result.0
    }

    nonisolated static func verifiedSnapshot(from data: Data, redeeming code: String?) throws -> InviteSnapshot {
        guard let snapshot = try? JSONDecoder().decode(InviteSnapshot.self, from: data) else { throw Failure.response }
        if let late = snapshot.lateUse, !late.isValid { throw Failure.response }
        if let upgrade = snapshot.lifetimeUpgrade, !upgrade.isValid || !snapshot.hasLifetimeAccess { throw Failure.response }
        if let code {
            // An existing grant alone does not validate the code just entered. The RPC
            // must confirm that exact code before onboarding can reveal its gift.
            guard snapshot.hasLifetimeAccess,
                  let confirmation = try? JSONDecoder().decode(RedemptionConfirmation.self, from: data),
                  confirmation.validatedCode == InviteSnapshot.normalize(code).uppercased()
            else { throw Failure.response }
        }
        return snapshot
    }
    private nonisolated struct RPCError: Decodable { let error: String }
    private nonisolated struct RedemptionConfirmation: Decodable { let validatedCode: String }

    private func authenticatedSession(forceRefresh: Bool = false) async throws -> Session {
        if let pendingSession {
            try InviteCredential.write("session", data: JSONEncoder().encode(pendingSession))
            self.pendingSession = nil
        }
        let stored = try InviteCredential.read("session")
        let existing: Session?
        if let stored {
            guard let session = try? JSONDecoder().decode(Session.self, from: stored) else { throw Failure.identity }
            existing = session
            if !forceRefresh && session.expiresAt > Date().timeIntervalSince1970 + 60 { return session }
        } else { existing = nil }
        let path = existing == nil ? "auth/v1/signup" : "auth/v1/token?grant_type=refresh_token"
        let body = existing.map { ["refresh_token": $0.refreshToken] } ?? [:]
        let (data, status) = try await request(path, body: body)
        guard (200...299).contains(status) else {
            if existing != nil && (status == 400 || status == 401 || status == 403) { throw Failure.identity }
            throw Failure.unavailable
        }
        guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data),
              response.user.is_anonymous, !response.access_token.isEmpty, !response.refresh_token.isEmpty,
              existing == nil || existing?.userID == response.user.id else { throw Failure.response }
        let session = Session(accessToken: response.access_token, refreshToken: response.refresh_token,
                              expiresAt: Date().timeIntervalSince1970 + response.expires_in, userID: response.user.id)
        pendingSession = session
        try InviteCredential.write("session", data: JSONEncoder().encode(session))
        pendingSession = nil
        return session
    }

    private func request(_ path: String, body: [String: String], token: String? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: Self.projectURL.appendingPathComponent("/")) else { throw Failure.response }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await transport.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count < 128_000 else { throw Failure.response }
            return (data, response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let failure as Failure { throw failure }
        catch { throw Failure.unavailable }
    }
}

// Distinguish a locked/inaccessible item from a missing one: never mint a replacement
// identity because Keychain was temporarily unavailable. Reset deliberately preserves it.
nonisolated enum InviteCredential {
    private static let service = "ai.sentient-os.invitations"
    static func read(_ account: String) throws -> Data? {
        var query = identity(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw InviteCloud.Failure.keychain }
        return data
    }
    static func write(_ account: String, data: Data) throws {
        var query = identity(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw InviteCloud.Failure.keychain }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw InviteCloud.Failure.keychain }
    }
    private static func identity(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
