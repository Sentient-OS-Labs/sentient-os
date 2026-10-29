import Foundation
import os

nonisolated enum ModelBackend: Sendable {
    case sentient, claude
    @TaskLocal static var current = Self.sentient
}
nonisolated final class SidekickInteraction: Sendable {
    @TaskLocal static var current: SidekickInteraction?
    let attached = OSAllocatedUnfairLock<HostedInference.Run?>(initialState: nil)
    func attachHostedRun(_ run: HostedInference.Run?) { attached.withLock { $0 = run } }
}

nonisolated final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var requests: [URLRequest] = []
        var handler: @Sendable (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.state.withLock { state in state.requests.append(request); return state.handler }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

nonisolated final class MemoryCredentials: Sendable {
    struct State { var data: Data?; var failRead = false; var failWrite = false; var writes = 0 }
    let state = OSAllocatedUnfairLock(initialState: State())
    var store: HostedInferenceClient.CredentialStore {
        .init(read: { [self] in try state.withLock {
            if $0.failRead { throw HostedInference.Failure.keychain }; return $0.data
        } }, write: { [self] data in try state.withLock {
            if $0.failWrite { throw HostedInference.Failure.keychain }; $0.data = data; $0.writes += 1
        } })
    }
}

@main struct HostedClientTests {
    static let count = OSAllocatedUnfairLock(initialState: 0)
    static let userID = "5C420A59-A169-4B8B-8018-DA459FF4CC32"
    static let runID = "F280999B-C9B0-4360-A71D-2205827EFB5F"
    static let config = HostedInferenceConfiguration(gatewayURL: URL(string: "https://gateway.test")!,
        identityURL: URL(string: "https://identity.test")!, publishableKey: "public-fixture-key")
    static func check(_ condition: Bool, _ message: String) { count.withLock { $0 += 1 }; if !condition { fatalError(message) } }
    static func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static var auth: Data { data(["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600,
                                 "user": ["id": userID, "is_anonymous": true]]) }
    static var usage: Data { data(["daily_limit_seconds": 3600, "used_seconds": 120, "remaining_seconds": 3480,
                                  "reset_at": "2026-10-30T00:00:00.000Z", "policy_version": "v1"]) }
    static var run: Data { data(["run_id": runID, "run_token": String(repeating: "t", count: 48),
        "model": "claude-sonnet-5-5", "remaining_seconds": 3480, "phase": "running", "purpose": "sidekick",
        "server_time": "2099-10-30T00:00:00Z", "lease_expires_at": "2099-10-30T00:00:45Z", "maximum_output_tokens": 4096]) }
    static func success(_ request: URLRequest) throws -> (Int, Data) {
        switch request.url!.path {
        case "/auth/v1/signup", "/auth/v1/token": return (200, auth)
        case "/v1/usage": return (200, usage)
        case "/v1/runs": return (200, run)
        default: return (200, data(["phase": request.url!.path.hasSuffix("pause") ? "waiting_for_user" : "running", "remaining_seconds": 3480,
            "server_time": "2099-10-30T00:00:00Z", "lease_expires_at": "2099-10-30T00:00:45Z"]))
        }
    }
    static func reset(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data) = success) {
        FixtureProtocol.state.withLock { $0.requests = []; $0.handler = handler }
    }
    static var paths: [String] { FixtureProtocol.state.withLock { $0.requests.map { $0.url!.path } } }
    static func client(_ credentials: MemoryCredentials = MemoryCredentials(), configured: Bool = true) -> HostedInferenceClient {
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [FixtureProtocol.self]
        return HostedInferenceClient(configuration: { configured ? config : nil }, session: URLSession(configuration: settings), credentials: credentials.store)
    }
    static func failure(_ expected: HostedInference.Failure, _ operation: @Sendable () async throws -> Void) async {
        do { try await operation(); check(false, "Expected \(expected)") }
        catch let actual as HostedInference.Failure { check(actual == expected, "Wrong failure: \(actual)") }
        catch { check(false, "Unexpected failure type: \(type(of: error))") }
    }
    static func stored(expires: Date, user: String = userID, origin: String = config.identityURL.absoluteString) -> Data {
        data(["accessToken": "saved-access", "refreshToken": "saved-refresh", "expiresAt": expires.timeIntervalSinceReferenceDate,
              "userID": user, "origin": origin])
    }
    static func main() async throws {
        for value in ["https://gateway.test", "https://gateway.test/base", "http://127.0.0.1:4123"] {
            check(HostedInferenceConfiguration.validEndpoint(URL(string: value)!), "Rejected supported endpoint")
        }
        for value in ["http://remote.test", "https://user:pass@gateway.test", "https://gateway.test?secret=1", "https://gateway.test/#fragment", "file:///tmp/gateway"] {
            check(!HostedInferenceConfiguration.validEndpoint(URL(string: value)!), "Accepted unsafe endpoint")
        }
        reset()
        await failure(.notConfigured) { _ = try await client(configured: false).usage() }
        check(paths.isEmpty, "Unconfigured client contacted network")

        reset()
        let memory = MemoryCredentials(), service = client(memory)
        async let one = service.usage(); async let two = service.usage()
        let results = try await [one, two]
        check(results.allSatisfy { $0.remainingSeconds == 3480 }, "Incorrect usage decode")
        check(paths.filter { $0 == "/auth/v1/signup" }.count == 1, "Concurrent calls enrolled twice")
        check(memory.state.withLock { $0.writes } == 1, "Identity was not durably stored exactly once")
        let requests = FixtureProtocol.state.withLock { $0.requests }
        check(requests.first?.value(forHTTPHeaderField: "apikey") == "public-fixture-key", "Missing public enrollment key")
        check(requests.filter { $0.url!.host == "gateway.test" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access" }, "Wrong gateway auth")
        check(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" }, "Credential response may be cached")

        reset()
        let corrupt = MemoryCredentials(); corrupt.state.withLock { $0.data = Data("broken".utf8) }
        await failure(.identity) { _ = try await client(corrupt).usage() }
        check(paths.isEmpty, "Corrupt identity silently replaced")
        corrupt.state.withLock { $0.failRead = true }
        await failure(.keychain) { _ = try await client(corrupt).usage() }
        check(paths.isEmpty, "Locked keychain silently reset identity")

        reset()
        let failedSave = MemoryCredentials(); failedSave.state.withLock { $0.failWrite = true }
        let saveClient = client(failedSave)
        await failure(.keychain) { _ = try await saveClient.usage() }
        failedSave.state.withLock { $0.failWrite = false }
        _ = try await saveClient.usage()
        check(paths.filter { $0 == "/auth/v1/signup" }.count == 1, "Retry after failed save created a second identity")

        reset()
        let expired = MemoryCredentials(); expired.state.withLock { $0.data = stored(expires: .distantPast) }
        _ = try await client(expired).usage()
        check(paths.first == "/auth/v1/token" && !paths.contains("/auth/v1/signup"), "Expired identity did not refresh in place")
        check(FixtureProtocol.state.withLock { $0.requests.first?.url?.query } == "grant_type=refresh_token", "Refresh grant missing")
        reset { request in
            if request.url!.path == "/auth/v1/token" { return (200, data(["access_token": "new", "refresh_token": "new", "expires_in": 3600, "user": ["id": UUID().uuidString, "is_anonymous": true]])) }
            return try success(request)
        }
        expired.state.withLock { $0.data = stored(expires: .distantPast) }
        await failure(.identity) { _ = try await client(expired).usage() }
        check(!paths.contains("/auth/v1/signup"), "Changed refresh identity caused reenrollment")

        reset { request in
            if request.url!.path == "/v1/usage", request.value(forHTTPHeaderField: "Authorization") == "Bearer saved-access" {
                return (401, data(["error": ["code": "authentication_required"]]))
            }
            return try success(request)
        }
        let revoked = MemoryCredentials(); revoked.state.withLock { $0.data = stored(expires: .distantFuture) }
        _ = try await client(revoked).usage()
        check(paths.filter { $0 == "/auth/v1/token" }.count == 1, "Rejected JWT did not refresh exactly once")
        check(!paths.contains("/auth/v1/signup"), "Rejected JWT replaced the principal")
        check(paths.filter { $0 == "/v1/usage" }.count == 2, "Unauthorized request was not retried once")

        reset { request in request.url!.path == "/v1/usage" ? (429, data(["error": ["code": "daily_time_exhausted", "message": "secret-provider-text"]])) : try success(request) }
        await failure(.rejected(code: "daily_time_exhausted", resetAt: nil)) { _ = try await client(memory).usage() }
        check(HostedInference.Failure.rejected(code: "daily_time_exhausted", resetAt: nil).isUsageLimit, "Quota code not classified")
        check(!HostedInference.Failure.rejected(code: "daily_time_exhausted", resetAt: nil).localizedDescription.contains("secret"), "Provider text leaked")
        reset { request in request.url!.path == "/v1/usage" ? (500, data(["error": ["code": "sk-ant-private\nvalue"]])) : try success(request) }
        await failure(.rejected(code: "request_rejected", resetAt: nil)) { _ = try await client(memory).usage() }
        reset { request in request.url!.path == "/v1/usage" ? (200, Data(repeating: 32, count: 65_537)) : try success(request) }
        await failure(.invalidResponse) { _ = try await client(memory).usage() }
        reset { request in request.url!.path == "/v1/runs" ? (200, data(["run_id": runID, "run_token": "short", "model": "claude-sonnet-5-5", "remaining_seconds": 1, "phase": "running", "purpose": "sidekick"])) : try success(request) }
        await failure(.invalidResponse) { _ = try await client(memory).start(purpose: .sidekick) }

        reset()
        let interaction = SidekickInteraction()
        let answer = try await HostedInference.$clientOverride.withValue(client(memory)) {
            try await SidekickInteraction.$current.withValue(interaction) {
                try await HostedInference.withRun(purpose: .sidekick) {
                    check(HostedInference.currentRun != nil, "Missing task scoped lease")
                    check(interaction.attached.withLock { $0 != nil }, "Interaction did not attach lease")
                    try await HostedInference.currentRun!.pause()
                    try await HostedInference.currentRun!.pause()
                    try await HostedInference.currentRun!.resume()
                    return try await HostedInference.withRun(purpose: .background) { 42 }
                }
            }
        }
        check(answer == 42, "Scope lost result")
        check(paths.filter { $0 == "/v1/runs" }.count == 1, "Nested work admitted second run")
        check(paths.filter { $0.hasSuffix("/pause") }.count == 1, "Duplicate pause")
        check(paths.filter { $0.hasSuffix("/resume") }.count == 1, "Missing resume")
        check(paths.filter { $0.hasSuffix("/finish") }.count == 1, "Missing finish")
        check(interaction.attached.withLock { $0 == nil }, "Completed interaction retained credential")
        check(HostedInference.currentRun == nil, "Credential escaped scope")
        reset()
        enum TestError: Error { case expected }
        do { try await HostedInference.$clientOverride.withValue(client(memory)) {
            try await HostedInference.withRun(purpose: .sidekick) { throw TestError.expected }
        } } catch TestError.expected { check(true, "") }
        check(paths.filter { $0.hasSuffix("/finish") }.count == 1, "Failure left run active")
        reset()
        let cancellation = Task { try await HostedInference.$clientOverride.withValue(client(memory)) {
            try await HostedInference.withRun(purpose: .sidekick) { try await Task.sleep(for: .seconds(30)) }
        } }
        while !paths.contains("/v1/runs") { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20)); cancellation.cancel()
        do { try await cancellation.value; check(false, "Cancellation succeeded") } catch is CancellationError { check(true, "") }
        check(paths.filter { $0.hasSuffix("/finish") }.count == 1, "Cancellation skipped cleanup")
        reset { request in
            if request.url!.path == "/v1/runs" {
                var body = try JSONSerialization.jsonObject(with: run) as! [String: Any]
                body["lease_expires_at"] = "2099-10-30T00:00:00.100Z"
                return (200, data(body))
            }
            return try success(request)
        }
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let began = ProcessInfo.processInfo.systemUptime
        await failure(.rejected(code: "lease_expired", resetAt: nil)) {
            try await HostedInference.$clientOverride.withValue(client(memory)) {
                try await HostedInference.withRun(purpose: .sidekick) {
                    defer { stopped.withLock { $0 = true } }
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }
        check(stopped.withLock { $0 }, "Lease expiry did not drain owned operation")
        check(ProcessInfo.processInfo.systemUptime - began < 2, "Cutoff waited for the eight-second heartbeat")
        check(paths.filter { $0.hasSuffix("/finish") }.count == 1, "Deadline skipped server cleanup")
        reset()
        let bypass = try await ModelBackend.$current.withValue(.claude) { try await HostedInference.withRun(purpose: .sidekick) { 7 } }
        check(bypass == 7 && paths.isEmpty, "Subscription provider consumed hosted allowance")
        print("PASS: \(count.withLock { $0 }) production hosted auth, identity persistence, quota, and lifecycle checks")
    }
}
