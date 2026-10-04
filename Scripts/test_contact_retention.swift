// Offline regression checks for the real MailAccountCloud actor. URLProtocol intercepts every
// request; only uniquely named test Keychain entries are touched. No live Supabase calls.
// Compile with MailAccount.swift, MailAccountCloud.swift and MailAccountCloudConfiguration.swift.

import Foundation
import Security

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

private final class ContactServer: @unchecked Sendable {
    enum Reply { case json([String: Any]), offline, hold }
    private let lock = NSLock()
    private var paths: [String] = []
    private var retained: Set<String> = []
    private var offline = false
    private var holdWrites = false
    private var completions: [@Sendable () -> Void] = []
    private var payloads: [[String: Any]] = []

    func configure(offline: Bool = false, holdWrites: Bool = false) {
        lock.withLock { self.offline = offline; self.holdWrites = holdWrites }
    }
    var requestCount: Int { lock.withLock { paths.count } }
    var writeIsHeld: Bool { lock.withLock { !completions.isEmpty } }
    var contactPayloads: [[String: Any]] { lock.withLock { payloads } }
    func hold(_ completion: @escaping @Sendable () -> Void) { lock.withLock { completions.append(completion) } }
    func releaseWrites() {
        let ready = lock.withLock {
            holdWrites = false
            let ready = completions; completions.removeAll(); return ready
        }
        for completion in ready { completion() }
    }
    var deletionRequests: Int { lock.withLock { paths.filter { $0.contains("delete") }.count } }
    func contains(_ email: String) -> Bool { lock.withLock { retained.contains(email) } }

    func reply(to request: URLRequest) -> Reply {
        lock.withLock {
            let path = request.url!.path
            paths.append(path)
            if offline { return .offline }
            if path == "/auth/v1/signup" || path == "/auth/v1/token" {
                return .json([
                    "access_token": "offline-test-access", "refresh_token": "offline-test-refresh",
                    "expires_in": 3600,
                    "user": ["id": "10000000-0000-0000-0000-000000000001", "is_anonymous": true]
                ])
            }
            if path == "/rest/v1/rpc/add_feedback_emails" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 2048)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(buffer, count: count)
                    }
                }
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                if let json {
                    payloads.append(json)
                    for email in json["emails"] as? [String] ?? [] { retained.insert(email) }
                }
                // Simulate an accepted server write whose response is still in flight.
                if holdWrites { return .hold }
                return .json([:])
            }
            return .json([:])
        }
    }
}

private final class ContactProtocol: URLProtocol, @unchecked Sendable {
    static let server = ContactServer()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.server.reply(to: request) {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .hold:
            Self.server.hold { [self] in respond([:]) }
        case .json(let payload):
            respond(payload)
        }
    }
    private let deliveryLock = NSLock()
    private var stopped = false
    private func respond(_ payload: [String: Any]) {
        deliveryLock.withLock {
            guard !stopped else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { deliveryLock.withLock { stopped = true } }
}

@main private enum ContactRetentionChecks {
    static func main() async throws {
        let server = ContactProtocol.server
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContactProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let prefix = "privacy-retention-test." + UUID().uuidString
        let keys = ["saved", "pending", "inflight", "legacy-synced", "legacy-pending", "concurrent"].map { prefix + "." + $0 }
        defer {
            for key in keys {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "ai.sentient-os.connected-email",
                               kSecAttrAccount as String: key] as CFDictionary)
            }
        }

        func address(_ name: String) -> String { name + "@example.invalid" }
        func identity(_ key: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: "ai.sentient-os.connected-email", kSecAttrAccount as String: key]
        }
        func stored(_ key: String) throws -> [String: Any] {
            var query = identity(key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [:] }
            try check(status == errSecSuccess, "Could not read the fixture Keychain item")
            return try JSONSerialization.jsonObject(with: result as! Data) as! [String: Any]
        }
        func seed(_ key: String, _ state: [String: Any]) throws {
            var item = identity(key)
            item[kSecValueData as String] = try JSONSerialization.data(withJSONObject: state)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil) == errSecSuccess, "Could not seed fixture state")
        }
        func expectEmailQueue(_ key: String, _ emails: [String]) throws {
            let state = try stored(key)
            try check(Set(state.keys).isSubset(of: ["pendingEmails", "auth"]), "Connector metadata survived in local state")
            try check(state["pendingEmails"] as? [String] == emails.sorted(), "Unexpected email-only retry queue")
        }

        // A saved contact survives local cleanup, including while the network is unavailable.
        let saved = MailAccountCloud(session: session, storageKey: keys[0])
        let savedEmail = address("saved")
        let synced = try await saved.save([" SAVED@example.invalid ", savedEmail])
        try check(synced && server.contains(savedEmail), "Initial contact did not reach the simulated server")
        let recreated = MailAccountCloud(session: session, storageKey: keys[0])
        let before = try await recreated.hasPendingSync()
        try check(!before, "Successful contact remained queued after relaunch")
        try expectEmailQueue(keys[0], [])
        server.configure(offline: true)
        let requestsBeforeForget = server.requestCount
        try await saved.forgetLocalState()
        try await saved.forgetLocalState()
        let after = MailAccountCloud(session: session, storageKey: keys[0])
        let pendingAfterForget = try await after.hasPendingSync()
        try check(!pendingAfterForget && stored(keys[0]).isEmpty, "Local Keychain state survived cleanup")
        try check(server.requestCount == requestsBeforeForget, "Cleanup attempted a network call")
        try check(server.contains(savedEmail), "Cleanup removed a retained server contact")
        print("PASS: saved contacts retained remotely; local cleanup is offline and idempotent")

        // An offline pending save must not restart its retry loop after cleanup.
        let pending = MailAccountCloud(session: session, storageKey: keys[1])
        let queued = try await pending.save([address("pending")])
        let isPending = try await pending.hasPendingSync()
        try check(!queued && isPending, "Offline save was not queued")
        try expectEmailQueue(keys[1], [address("pending")])
        try await pending.forgetLocalState()
        let requestsAfterCleanup = server.requestCount
        try await Task.sleep(for: .milliseconds(5300))
        try check(server.requestCount == requestsAfterCleanup, "A canceled retry made another request")
        let pendingAfter = try await pending.hasPendingSync()
        try check(!pendingAfter, "Pending state survived cleanup")
        print("PASS: queued retry stopped and local pending state cleared")

        // Cancel a write after the server accepted it, before a response can persist credentials.
        server.configure(holdWrites: true)
        let inflight = MailAccountCloud(session: session, storageKey: keys[2])
        let inflightEmail = address("inflight")
        let save = Task { try await inflight.save([inflightEmail]) }
        let deadline = Date().addingTimeInterval(3)
        while !server.writeIsHeld && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(server.writeIsHeld, "No in-flight write was observed")
        try await inflight.forgetLocalState()
        _ = try await save.value
        let fresh = MailAccountCloud(session: session, storageKey: keys[2])
        let freshPending = try await fresh.hasPendingSync()
        try check(!freshPending && stored(keys[2]).isEmpty, "Late request recreated local credentials")
        try check(server.contains(inflightEmail), "In-flight cleanup removed a server contact")
        try check(server.deletionRequests == 0, "Contact deletion RPC was called")
        print("PASS: in-flight cleanup preserves the accepted contact and clears local state")

        server.releaseWrites()

        // Rewrite either legacy state (already synced or offline) without retaining metadata.
        for (key, wasPending) in [(keys[3], false), (keys[4], true)] {
            server.configure(offline: true)
            let legacyEmail = address(wasPending ? "legacy-pending" : "legacy-synced")
            try seed(key, ["accounts": [["email": legacyEmail, "engine": "claude", "provider": "gmail",
                "connection_key": "private-connector-id", "reported_via": "sent_mail_metadata", "consent_version": 1]],
                "pending": wasPending, "revision": 4, "remoteDeleted": false,
                "auth": ["accessToken": "offline-test-access", "refreshToken": "offline-test-refresh",
                         "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970,
                         "userID": "10000000-0000-0000-0000-000000000001"]])
            let migrated = MailAccountCloud(session: session, storageKey: key)
            let queuedLegacy = try await migrated.hasPendingSync()
            try check(queuedLegacy, "Migration dropped a previously collected address")
            try expectEmailQueue(key, [legacyEmail])
            server.configure()
            await migrated.retryPendingSync()
            try check(server.contains(legacyEmail), "Legacy address was not retried")
            try expectEmailQueue(key, [])
            try await migrated.forgetLocalState()
        }
        print("PASS: both legacy states migrate to email-only retries and clear old local metadata")

        // A second save during an in-flight request must survive the first acknowledgement.
        server.configure(holdWrites: true)
        let concurrent = MailAccountCloud(session: session, storageKey: keys[5])
        let first = Task { try await concurrent.save([address("first")]) }
        let firstDeadline = Date().addingTimeInterval(3)
        while !server.writeIsHeld && Date() < firstDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(server.writeIsHeld, "First concurrent write was not held")
        let second = Task { try await concurrent.save([address("second")]) }
        let queueDeadline = Date().addingTimeInterval(3)
        while (try stored(keys[5])["pendingEmails"] as? [String])?.contains(address("second")) != true
                && Date() < queueDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try expectEmailQueue(keys[5], [address("first"), address("second")])
        server.releaseWrites()
        let firstSynced = try await first.value
        let secondSynced = try await second.value
        try check(firstSynced && secondSynced && server.contains(address("first")) && server.contains(address("second")),
                  "Concurrent save lost an address")
        try expectEmailQueue(keys[5], [])
        let requestsBeforeInvalid = server.requestCount
        do {
            _ = try await concurrent.save([address("must-not-save"), "invalid"])
            throw CheckFailure.failed("Mixed invalid batch was accepted")
        } catch MailAccountError.invalidAddress {}
        try check(server.requestCount == requestsBeforeInvalid, "Invalid batch reached the network")
        try expectEmailQueue(keys[5], [])
        try await concurrent.forgetLocalState()
        print("PASS: concurrent saves preserve both addresses; invalid batches are rejected atomically")

        // Assert the actual wire payload, including retries and upgraded state, contains only emails.
        for payload in server.contactPayloads {
            try check(Set(payload.keys) == ["emails"], "Contact payload contains metadata fields")
            guard let emails = payload["emails"] as? [String] else { throw CheckFailure.failed("Non-string contact value") }
            try check(!emails.isEmpty && emails.count <= 32 && Set(emails).count == emails.count,
                      "Contact batch is not bounded and deduplicated")
            try check(emails.allSatisfy { MailAccount.normalizedEmail($0) == $0 }, "Unnormalized contact address")
        }
        print("PASS: every intercepted contact request sends email strings only")

        // Verify the destructive app entry points are wired to the tested retention policy.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reset = try String(contentsOf: root.appendingPathComponent("Sentient OS macOS/Ingestion/FactoryReset.swift"), encoding: .utf8)
        let uninstall = try String(contentsOf: root.appendingPathComponent("Sentient OS macOS/System/Uninstall.swift"), encoding: .utf8)
        try check(!reset.contains("MailAccountCloud.shared."), "Reset changes the retained contact identity")
        try check(uninstall.contains("MailAccountCloud.shared.forgetLocalState()"), "Uninstall does not clear local contact state")
        try check(!uninstall.contains("MailAccountCloud.shared.erase()"), "Uninstall deletes remote contacts")
        print("PASS: Reset retains contact state; Uninstall performs local-only contact cleanup")
    }
}
