//
// DirectMCPStore.swift
// Stores non-secret connection state in preferences and complete grants in a dedicated Keychain
// service. Per-grant file locks serialize refresh and deletion across the app and header helpers.
//
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import Security
import os
import Darwin

nonisolated enum DirectMCPStore {
    static let preferencesKey = "mcp.connectors.direct"
    private static let service = "ai.sentient-os.app.direct-mcp.v1"
    // Serialize read-modify-write transactions only. UI readers must not take this lock:
    // UserDefaults.set synchronously notifies SwiftUI, which may already be rendering a reader.
    private static let indexWriteLock = OSAllocatedUnfairLock()
    static let changed = Notification.Name("DirectMCPConnectionsChanged")

    static func connections() -> [DirectMCPConnection] {
        // UserDefaults is thread-safe; each Data value is a complete encoded snapshot.
        // Reading it directly also keeps helper processes on the persisted source of truth.
        readIndex()
    }
    private static func readIndex() -> [DirectMCPConnection] {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey) else { return [] }
        return (try? JSONDecoder().decode([DirectMCPConnection].self, from: data)) ?? []
    }
    static func connection(_ slug: String) -> DirectMCPConnection? {
        let parts = slug.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let base = parts.first,
              let connection = connections().first(where: { $0.slug == base }) else { return nil }
        if parts.count == 2, parts[1] != connection.generation.uuidString.lowercased() { return nil }
        return connection
    }
    static func connection(id: UUID) -> DirectMCPConnection? { connections().first { $0.id == id } }

    static func save(_ connection: DirectMCPConnection) throws {
        try indexWriteLock.withLock {
            var list = readIndex()
            list.removeAll { $0.id == connection.id }
            list.append(connection)
            UserDefaults.standard.set(try JSONEncoder().encode(list), forKey: preferencesKey)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func removeIndex(id: UUID) {
        indexWriteLock.withLock {
            let list = readIndex().filter { $0.id != id }
            if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: preferencesKey) }
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    static func readGrant(_ id: UUID) throws -> DirectMCPGrant {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { throw DirectMCPError.reconnectRequired }
        guard status == errSecSuccess else { throw DirectMCPError.keychain(status) }
        guard let data = value as? Data, let grant = try? JSONDecoder().decode(DirectMCPGrant.self, from: data),
              grant.connectionID == id else { throw DirectMCPError.invalidResponse }
        return grant
    }
    static func optionalGrant(_ id: UUID) throws -> DirectMCPGrant? {
        do { return try readGrant(id) }
        catch DirectMCPError.reconnectRequired { return nil }
    }
    /// Replace the complete access/refresh pair without deleting the old value first.
    static func saveGrant(_ grant: DirectMCPGrant) throws {
        let data = try JSONEncoder().encode(grant)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(query(grant.connectionID) as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(grant.connectionID)
            q.removeValue(forKey: kSecUseAuthenticationUI as String)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DirectMCPError.keychain(status) }
    }
    static func deleteGrant(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DirectMCPError.keychain(status) }
    }
    /// Does not depend on the preferences index, so orphan grants are included in cleanup.
    static func grantIDs() throws -> [UUID] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let records = result as? [[String: Any]] else {
            throw DirectMCPError.keychain(status)
        }
        return records.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }

    static func withGrantLock<T: Sendable>(_ id: UUID,
        operation: @Sendable () async throws -> T) async throws -> T {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/SentientOS/Direct MCP Locks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: id.uuidString + ".lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw DirectMCPError.busy }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw DirectMCPError.busy }
            guard ContinuousClock.now < deadline else { throw DirectMCPError.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
