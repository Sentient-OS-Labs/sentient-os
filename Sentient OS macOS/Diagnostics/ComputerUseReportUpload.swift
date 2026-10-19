// User-initiated support upload. A separate anonymous identity never links reports to invite or mail accounts.
// No queue, automatic upload, free-text attachment, cross-host redirect or response-body logging.
import Foundation

nonisolated final class SupportReportRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

actor ComputerUseReportUpload {
    static let shared = ComputerUseReportUpload()
    enum Failure: Error { case busy, unavailable, rejected, invalidReport }
    private struct Session { let access: String; let refresh: String; let expires: Date }
    private struct AuthReply: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
        struct User: Decodable { let is_anonymous: Bool }
    }
    private struct Receipt: Decodable { let id: UUID }
    private struct Envelope: Encodable { let p_report: ComputerUseCheckReport }
    private let transport: URLSession
    private let base: URL
    private let key: String
    private var session: Session?
    private var sending = false

    init(transport: URLSession? = nil,
         base: URL = MailAccountCloudConfiguration.url, key: String = MailAccountCloudConfiguration.publishableKey) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false; config.urlCache = nil
        self.transport = transport ?? URLSession(configuration: config, delegate: SupportReportRedirectPolicy(), delegateQueue: nil)
        self.base = base; self.key = key
    }

    func send(_ report: ComputerUseCheckReport) async throws -> UUID {
        guard !sending else { throw Failure.busy }
        guard report.outcome != .running, report.finishedAt != nil, report.schemaVersion == 1,
              report.steps.count <= 8, report.recentEvents.count <= 16 else { throw Failure.invalidReport }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(Envelope(p_report: report))
        guard body.count <= 96_000 else { throw Failure.invalidReport }
        sending = true; defer { sending = false }
        var credential = try await authenticate()
        var response = try await request("rest/v1/rpc/submit_computer_use_report", body: body, access: credential.access)
        if response.1 == 401 {
            credential = try await authenticate(refresh: true)
            response = try await request("rest/v1/rpc/submit_computer_use_report", body: body, access: credential.access)
        }
        guard response.1 == 200, let receipt = try? JSONDecoder().decode(Receipt.self, from: response.0),
              receipt.id == report.id else { throw Failure.rejected }
        return receipt.id
    }

    private func authenticate(refresh: Bool = false) async throws -> Session {
        if !refresh, let session, session.expires.timeIntervalSinceNow > 60 { return session }
        let path = session == nil ? "auth/v1/signup" : "auth/v1/token?grant_type=refresh_token"
        let body = try JSONSerialization.data(withJSONObject: session.map { ["refresh_token": $0.refresh] } ?? [:])
        let (data, status) = try await request(path, body: body, access: nil)
        guard status == 200 || status == 201,
              let value = try? JSONDecoder().decode(AuthReply.self, from: data), value.user.is_anonymous,
              !value.access_token.isEmpty, !value.refresh_token.isEmpty,
              value.expires_in.isFinite, value.expires_in > 0 else { throw Failure.unavailable }
        let credential = Session(access: value.access_token, refresh: value.refresh_token,
                                 expires: Date().addingTimeInterval(value.expires_in))
        session = credential
        return credential
    }

    private func request(_ path: String, body: Data, access: String?) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: base.appendingPathComponent("/")),
              url.scheme == "https", url.host == base.host else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let access { request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await transport.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, data.count < 128_000 else { throw Failure.unavailable }
            return (data, http.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure.unavailable }
    }
}
