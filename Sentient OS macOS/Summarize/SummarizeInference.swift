// Sends primary document text plus a supporting image to the covered OpenAI relay. The bounded SSE parser requires a completed
// response; incomplete text stays available to the reading window with an honest error.
// Doc: Documentation - Summarize.md
import Foundation

enum SummarizeInference {
    nonisolated static let maximumImageBytes = 4_500_000
    nonisolated static let deadline: Duration = .seconds(50)

    nonisolated struct SourceInfo: Sendable {
        enum Kind: String, Sendable { case youtube = "youtube-transcript", accessibility, screenshot }
        let kind: Kind
        let truncated: Bool
        var label: String {
            switch kind {
            case .youtube: "Fetched video transcript"
            case .accessibility: "Read text"
            case .screenshot: "Screen snapshot"
            }
        }
    }

    static func stream(image: Data, preference: String,
                       onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        try await stream(source: SummarySource(image: image), preference: preference, onText: onText)
    }

    static func stream(source: SummarySource, preference: String,
                       onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        try await streamWithSource(source: source, preference: preference, onSource: { _ in }, onText: onText)
    }

    static func streamWithSource(source: SummarySource, preference: String,
                       onSource: @escaping @MainActor @Sendable (SourceInfo) -> Void,
                       onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        guard let base = ScreenRelay.url else { throw Failure.unavailable }
        let request = try request(base: base, source: source, preference: preference, identity: ScreenRelay.identity())
        do { return try await ScreenRelayResponse.text(for: request, onResponse: { response in
            guard let raw = response.value(forHTTPHeaderField: "x-summary-source"),
                  let kind = SourceInfo.Kind(rawValue: raw) else { return }
            onSource(SourceInfo(kind: kind, truncated: response.value(forHTTPHeaderField: "x-summary-truncated") == "true"))
        }, onText: onText) }
        catch let failure as ScreenRelayResponse.Failure {
            switch failure {
            case .http(let status): throw Failure.http(status)
            case .incomplete: throw Failure.incomplete
            case .empty: throw Failure.empty
            case .invalidResponse: throw Failure.invalidResponse
            }
        }
    }

    static func request(base: URL, image: Data, preference: String, identity: String) throws -> URLRequest {
        try request(base: base, source: SummarySource(image: image), preference: preference, identity: identity)
    }

    static func request(base: URL, source: SummarySource, preference: String, identity: String) throws -> URLRequest {
        guard !source.text.isEmpty || source.image?.isEmpty == false,
              source.text.utf8.count <= SummaryAccessibility.maximumTextBytes,
              (source.image?.count ?? 0) <= maximumImageBytes,
              source.title.utf8.count <= 1_000, source.application.utf8.count <= 200,
              (source.url?.utf8.count ?? 0) <= 2_000, source.scope.utf8.count <= 200,
              preference.utf8.count <= 1_000 else { throw Failure.invalidRequest }
        var request = URLRequest(url: base.appendingPathComponent("v1/summarize"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("SentientOS-Summarize/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (macOS)",
                         forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = ["preference": preference]
        if !source.text.isEmpty {
            body["text"] = source.text; body["title"] = source.title; body["application"] = source.application
            body["scope"] = source.scope; body["truncated"] = source.truncated
        }
        if let url = source.url { body["url"] = url }
        if let image = source.image { body["image"] = image.base64EncodedString() }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case unavailable, invalidRequest, invalidResponse, incomplete, empty, timedOut, http(Int)
        var errorDescription: String? {
            switch self {
            case .http(401), .http(403): "Sentient couldn’t connect with its saved access. Try again."
            case .http(424): "The video’s original transcript isn’t available. Try another video."
            case .http(429): "The summary allowance has been reached. Please try again later."
            case .http(404), .http(503), .unavailable: "Summarize is temporarily unavailable. Please try again later."
            case .timedOut: "The summary took too long. Try again."
            case .incomplete: "The summary was interrupted. You can read the available text or try again."
            case .empty: "No summary came back. Try again."
            case .invalidRequest: "This screen couldn’t be prepared for a summary. Try again."
            case .invalidResponse, .http: "The summary couldn’t finish. Try again."
            }
        }
    }
}
