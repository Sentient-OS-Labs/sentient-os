// Sends only the selected text to Luna Fast through the covered relay. A completed, strictly
// decoded correction is required; partial JSON, refusals and truncated responses never edit text.
// decode() puts the selection's own boundary whitespace and line breaks back mechanically.
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
        let passage = String(original.dropFirst(leading.count).dropLast(trailing.count))
        guard let body = restoringLineBreaks(of: passage, in: corrected.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Failure.rejected }
        let result = leading + body + trailing
        let originalBreaks = original.unicodeScalars.filter { CharacterSet.newlines.contains($0) }
        guard result.unicodeScalars.filter({ CharacterSet.newlines.contains($0) }).elementsEqual(originalBreaks) else { throw Failure.rejected }
        guard result.utf8.count <= maximumOutputBytes else { throw Failure.incomplete }
        return result
    }

    /// Line breaks belong to the selection too. A correction may normalize blank lines or CRLF
    /// while keeping every line in place; when it has the same number of line boundaries, the
    /// original break runs go back unchanged. Merged, dropped or added lines are refused.
    nonisolated private static func restoringLineBreaks(of original: String, in corrected: String) -> String? {
        let newline = #"(?:\r\n|[\n\u000B\u000C\r\u0085\u2028\u2029])"#
        // One boundary is a run of line breaks, including whitespace-only lines inside it.
        guard let boundary = try? NSRegularExpression(pattern: newline + #"(?:[ \t]*"# + newline + ")*") else { return nil }
        let source = original as NSString, target = corrected as NSString
        let kept = boundary.matches(in: original, range: NSRange(location: 0, length: source.length))
        let found = boundary.matches(in: corrected, range: NSRange(location: 0, length: target.length))
        guard kept.count == found.count else { return nil }
        var result = "", cursor = 0
        for (run, match) in zip(kept, found) {
            result += target.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += source.substring(with: run.range)
            cursor = NSMaxRange(match.range)
        }
        return result + target.substring(from: cursor)
    }

    nonisolated enum Failure: LocalizedError {
        /// `incomplete`: no usable answer arrived. `rejected`: a complete answer changed which
        /// lines exist. Both leave the text untouched; logs can tell them apart.
        case unavailable, limit, tooLarge, incomplete, rejected
        var errorDescription: String? {
            switch self {
            case .unavailable: "Proofread is temporarily unavailable. Please try again later."
            case .limit: "The proofreading allowance has been reached. Please try again later."
            case .tooLarge: "Select a shorter passage to proofread."
            case .incomplete, .rejected: "The correction couldn’t finish. Your text hasn’t been changed."
            }
        }
    }
}
