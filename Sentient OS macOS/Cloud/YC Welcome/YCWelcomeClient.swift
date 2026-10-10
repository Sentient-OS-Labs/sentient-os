// YCWelcomeClient.swift
// Bounded, domain-only lookup of a published welcome. Missing deployments, offline use and
// invalid responses all mean ordinary onboarding. Logos are fetched only from curated storage.
// Doc: ../../Views/Onboarding/Documentation - Onboarding.md

import Foundation

nonisolated struct YCWelcomeClient: Sendable {
    static let shared = YCWelcomeClient()
    private let session: URLSession
    private let lookupTimeout: Duration

    init(session: URLSession? = nil, lookupTimeout: Duration = .milliseconds(1500)) {
        self.lookupTimeout = lookupTimeout
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 1.5
            configuration.timeoutIntervalForResource = 2
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: WelcomeRedirectPolicy(), delegateQueue: nil)
        }
    }

    func lookup(email: String) async -> YCCompanyWelcome? {
        guard let domain = YCCompanyWelcome.domain(from: email), !Task.isCancelled else { return nil }
        // A total deadline, not an inactivity timeout. Cancel URLSession when the deadline wins.
        return await withTaskGroup(of: YCCompanyWelcome?.self) { group in
            group.addTask { await fetch(domain: domain) }
            group.addTask {
                try? await Task.sleep(for: lookupTimeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return Task.isCancelled ? nil : result
        }
    }

    private func fetch(domain: String) async -> YCCompanyWelcome? {
        var request = URLRequest(url: MailAccountCloudConfiguration.url
            .appendingPathComponent("rest/v1/rpc/resolve_yc_company_welcome"))
        request.httpMethod = "POST"
        request.setValue(MailAccountCloudConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["email_domain": domain])
        do {
            let data = try await read(request, maximumBytes: 8_192)
            let welcome = try JSONDecoder().decode(YCCompanyWelcome?.self, from: data)
            return welcome?.isValid == true && !Task.isCancelled ? welcome : nil
        } catch {
            // No response bodies, company names, domains or email addresses in diagnostics.
            return nil
        }
    }

    func logoData(for welcome: YCCompanyWelcome) async -> Data? {
        guard let url = welcome.logoURL else { return nil }
        return try? await read(URLRequest(url: url), maximumBytes: 1_048_576, image: true)
    }

    @concurrent private func read(_ request: URLRequest, maximumBytes: Int, image: Bool = false) async throws -> Data {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= maximumBytes,
              !image || ["image/png", "image/jpeg", "image/webp"].contains(response.mimeType ?? "")
        else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
}

/// Curated endpoints are direct. Do not follow a storage redirect to a third-party tracker.
private final class WelcomeRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
