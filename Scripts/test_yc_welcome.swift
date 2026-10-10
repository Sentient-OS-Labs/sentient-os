// Offline checks of the production welcome parser and transport. Compile with MailAccount.swift,
// MailAccountCloudConfiguration.swift, YCCompanyWelcome.swift and YCWelcomeClient.swift.
import Foundation

private func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "WelcomeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class WelcomeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data("null".utf8)
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var hold = false
    nonisolated(unsafe) private static var mime = "application/json"
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var stopped = 0
    static func configure(_ text: String, status: Int = 200, hold: Bool = false,
                          mime: String = "application/json") {
        lock.withLock { body = Data(text.utf8); self.status = status; self.hold = hold; self.mime = mime }
    }
    static var count: Int { lock.withLock { requests.count } }
    static var cancellations: Int { lock.withLock { stopped } }
    static var last: URLRequest? { lock.withLock { requests.last } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.requests.append(request)
            return (Self.body, Self.status, Self.hold, Self.mime)
        }
        if reply.2 { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.1, httpVersion: nil,
                                       headerFields: ["Content-Type": reply.3])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
}

@main private enum WelcomeChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WelcomeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = YCWelcomeClient(session: session, lookupTimeout: .milliseconds(100))
        let valid = #"{"company_name":"Fixture Company","welcome_line":"Keep customer follow-ups moving.","logo_path":"fixture/v1.png","content_version":1}"#

        for address in ["bad", "a@gmail.com", "a@outlook.com", "a@localhost", "a@-company.ai", "a@company.ai/"] {
            let count = WelcomeProtocol.count
            let result = await client.lookup(email: address)
            try check(result == nil && WelcomeProtocol.count == count, "Malformed/shared email made a request")
        }
        try check(YCCompanyWelcome.domain(from: "  Reader+tag@Company.co.uk  ") == "company.co.uk", "Normalization damaged domain")
        try check(YCCompanyWelcome.domain(from: "reader@sub.company.ai") == "sub.company.ai", "Subdomain was silently collapsed")

        WelcomeProtocol.configure(valid)
        let welcome = await client.lookup(email: "private-person@fixture.example")
        try check(welcome?.companyName == "Fixture Company", "Valid welcome not decoded")
        try check(welcome?.displayAttributionLine == nil, "Older response invented an attribution")
        try check(welcome?.logoURL?.host == MailAccountCloudConfiguration.url.host, "Logo leaves curated host")
        guard let request = WelcomeProtocol.last else { fatalError("Missing request") }
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; data.append(buffer, count: n)
            }
        }
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: String]
        try check(payload == ["email_domain": "fixture.example"], "Lookup sends more than the domain")
        try check(request.httpMethod == "POST" && request.url?.query == nil, "Domain exposed in URL")
        try check(request.value(forHTTPHeaderField: "Authorization") == nil, "Lookup links an installation identity")
        print("PASS: domain-only lookup, exact domain normalization, shared-provider early exit")

        let fixture = try JSONSerialization.jsonObject(with: Data(valid.utf8)) as! [String: Any]
        for attribution in ["Created by the fixture team", String(repeating: "a", count: 140)] {
            var response = fixture
            response["attribution_line"] = attribution
            let body = try JSONSerialization.data(withJSONObject: response)
            WelcomeProtocol.configure(String(decoding: body, as: UTF8.self))
            let result = await client.lookup(email: "reader@fixture.example")
            try check(result?.displayAttributionLine == attribution, "Server attribution not decoded")
        }
        for attribution: Any in [NSNull(), "", " padded ", String(repeating: "a", count: 141),
                                 "Hidden\nline", "Hidden\u{202e}line", "Hidden\u{2066}line"] {
            var response = fixture
            response["attribution_line"] = attribution
            let body = try JSONSerialization.data(withJSONObject: response)
            WelcomeProtocol.configure(String(decoding: body, as: UTF8.self))
            let result = await client.lookup(email: "reader@fixture.example")
            try check(result?.companyName == "Fixture Company" && result?.displayAttributionLine == nil,
                      "Missing or unsafe attribution damaged welcome or reached the display")
        }
        print("PASS: remote attribution, older responses, null/unsafe footer fallback")

        for response in ["null", "{}", "not JSON", valid.replacingOccurrences(of: "Fixture Company", with: ""),
                         valid.replacingOccurrences(of: "\"content_version\":1", with: "\"content_version\":0"),
                         valid.replacingOccurrences(of: "Fixture Company", with: String(repeating: "a", count: 101)),
                         String(repeating: "x", count: 9_000)] {
            WelcomeProtocol.configure(response)
            let result = await client.lookup(email: "reader@fixture.example")
            try check(result == nil, "Invalid, absent or oversized payload accepted")
        }
        WelcomeProtocol.configure(valid, status: 503)
        let unavailable = await client.lookup(email: "reader@fixture.example")
        try check(unavailable == nil, "Server failure did not fall back")
        for path in ["../private.png", "https://tracker.example/logo.png", "fixture/%2e%2e.png", "fixture/a.svg"] {
            let model = YCCompanyWelcome(companyName: "Fixture", welcomeLine: "Hello.", logoPath: path, contentVersion: 1)
            try check(model.logoURL == nil, "Untrusted logo path accepted")
        }
        print("PASS: malformed payloads, missing deployment/server failure, bounded body, trusted logo paths")

        guard let welcome else { fatalError("Missing valid logo fixture") }
        WelcomeProtocol.configure("image bytes", mime: "image/png")
        let logo = await client.logoData(for: welcome)
        try check(logo == Data("image bytes".utf8), "Allowed image transport rejected")
        try check(WelcomeProtocol.last?.url?.path == "/storage/v1/object/public/yc-company-logos/fixture/v1.png",
                  "Logo request escaped the curated bucket")
        WelcomeProtocol.configure("not an image", mime: "text/html")
        let html = await client.logoData(for: welcome)
        try check(html == nil, "Non-image logo accepted")
        WelcomeProtocol.configure(String(repeating: "x", count: 1_048_577), mime: "image/png")
        let oversizedLogo = await client.logoData(for: welcome)
        try check(oversizedLogo == nil, "Oversized image accepted")
        print("PASS: curated logo transport, image content type and streamed image size bound")

        WelcomeProtocol.configure(valid, hold: true)
        let start = ContinuousClock.now
        let timedOut = await client.lookup(email: "reader@fixture.example")
        try check(timedOut == nil && start.duration(to: .now) < .seconds(1), "Lookup exceeded total deadline")
        try check(WelcomeProtocol.cancellations > 0, "Deadline left network request running")
        let task = Task { await client.lookup(email: "reader@fixture.example") }
        task.cancel()
        let cancelled = await task.value
        try check(cancelled == nil, "Cancelled lookup delivered a welcome")
        print("PASS: total deadline cancels transport; cancelled lookups cannot deliver late welcomes")
    }
}
