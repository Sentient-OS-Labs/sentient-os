// Sends only the selected text to Luna Fast through the covered relay. A completed, strictly
// decoded correction is required; partial JSON, refusals and truncated responses never edit text.
// Doc: Documentation - Proofread.md
import Foundation

enum ProofreadInference {
    nonisolated static let maximumInputBytes = 12_000
    nonisolated static let maximumOutputBytes = 24_000

    static func correct(_ text: String) async throws -> String {
        guard let base = ScreenRelay.url else { throw Failure.unavailable }
        let request = try request(base: base, text: text, identity: ScreenRelay.identity())
        do {
            let result = try await ScreenRelayResponse.text(for: request, maximumTextBytes: 160_000, onText: { _ in })
            return try decode(result, original: text)
        } catch let error as ScreenRelayResponse.Failure {
            switch error {
            case .http(429): throw Failure.limit
            case .http(404), .http(503): throw Failure.unavailable
            default: throw Failure.incomplete
            }
        }
    }

    static func request(base: URL, text: String, identity: String) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumInputBytes else { throw Failure.tooLarge }
        var request = URLRequest(url: base.appendingPathComponent("v1/proofread"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("Bearer \(identity)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("SentientOS-Proofread/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") (macOS)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        return request
    }

    nonisolated static func decode(_ response: String, original: String? = nil) throws -> String {
        guard response.utf8.count <= 160_000,
              let value = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              Set(value.keys) == ["corrected_text"], let corrected = value["corrected_text"] as? String,
              !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              corrected.utf8.count <= maximumOutputBytes, !corrected.contains("\0") else { throw Failure.incomplete }
        guard let original else { return corrected }
        // Boundary whitespace belongs to the selection, not the model. Preserve it mechanically.
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let result = leading + corrected.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
        let originalBreaks = original.unicodeScalars.filter { CharacterSet.newlines.contains($0) }
        guard result.unicodeScalars.filter({ CharacterSet.newlines.contains($0) }).elementsEqual(originalBreaks),
              result.utf8.count <= maximumOutputBytes else { throw Failure.incomplete }
        return result
    }

    nonisolated enum Failure: LocalizedError {
        case unavailable, limit, tooLarge, incomplete
        var errorDescription: String? {
            switch self {
            case .unavailable: "Proofread is temporarily unavailable. Please try again later."
            case .limit: "The proofreading allowance has been reached. Please try again later."
            case .tooLarge: "Select a shorter passage to proofread."
            case .incomplete: "The correction couldn’t finish. Your text hasn’t been changed."
            }
        }
    }
}
