// AppleMailMIME.swift
// Bounded, inert MIME extraction. Decodes body text only; attachments and embedded messages
// never reach a decoder or model. Doc: Sources/Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md

import Foundation

nonisolated enum AppleMailMIME {
    enum Failure: Error { case malformed, unavailable, unsupported, excluded, noText, incompleteMessage, missingBodyPart, incompleteMultipart, invalidTransferEncoding, invalidText }
    struct Message: Sendable {
        let headers: [String: String]
        let text: String
        var truncated = false
    }
    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumText = 24_000

    /// The decimal prefix counts RFC822 bytes, excluding the trailing Apple property list.
    static func read(_ url: URL, expectedMessageID: String? = nil, includeJunkPreview: Bool = false, preserveContext: Bool = false) throws -> Message {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 64) ?? Data()
        guard let end = prefix.firstIndex(of: 10), end < 24,
              let size = Int(String(decoding: prefix[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              size > 0, size <= maximumBytes else { throw Failure.unsupported }
        try handle.seek(toOffset: UInt64(end + 1))
        guard let data = try handle.read(upToCount: size), data.count == size else { throw Failure.incompleteMessage }
        return try parse(data, expectedMessageID: expectedMessageID, includeJunkPreview: includeJunkPreview, preserveContext: preserveContext)
    }

    static func parse(_ data: Data, expectedMessageID: String? = nil, includeJunkPreview: Bool = false, preserveContext: Bool = false) throws -> Message {
        guard data.count <= maximumBytes else { throw Failure.unsupported }
        let (headers, body) = try split(data)
        // Validate the locator before making ANY policy decision, including a rejection.
        // A stale row-number match must not let another message's headers suppress this row.
        if let expectedMessageID {
            func normalized(_ value: String) -> String {
                value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            }
            let expected = normalized(expectedMessageID)
            guard !expected.isEmpty,
                  normalized(headers["message-id", default: ""]) == expected else {
                throw AppleMailError.missingBody
            }
        }
        guard includeJunkPreview || !excluded(headers) else { throw Failure.excluded }
        var parts = 0, truncated = false
        let text = try extract(headers, body, depth: 0, parts: &parts, truncated: &truncated, preserveContext: preserveContext)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.noText }
        return Message(headers: headers, text: bounded(text, truncated: &truncated), truncated: truncated)
    }

    private static func bounded(_ text: String, truncated: inout Bool) -> String {
        if text.count > maximumText { truncated = true }
        return String(text.prefix(maximumText))
    }

    /// Header-only research indexing avoids decoding every body in a mailbox. Never renders HTML.
    static func readHeaders(_ url: URL, expectedMessageID: String) throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 64) ?? Data()
        guard let end = prefix.firstIndex(of: 10), end < 24,
              let size = Int(String(decoding: prefix[..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              size > 0, size <= maximumBytes else { throw Failure.unsupported }
        try handle.seek(toOffset: UInt64(end + 1))
        var data = Data()
        let limit = min(size, 128 * 1_024)
        while data.count < limit {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(4_096, limit - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil || data.range(of: Data("\n\n".utf8)) != nil { break }
        }
        let (headers, _) = try split(data)
        func normalized(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
        guard !expectedMessageID.isEmpty, normalized(headers["message-id", default: ""]) == normalized(expectedMessageID) else {
            throw AppleMailError.missingBody
        }
        guard !excluded(headers) else { throw Failure.excluded }
        return headers
    }

    static func excluded(_ h: [String: String]) -> Bool {
        if h["list-unsubscribe"] != nil || h["list-id"] != nil { return true }
        let precedence = h["precedence", default: ""].lowercased()
        if ["bulk", "list", "junk"].contains(where: { precedence.contains($0) }) { return true }
        for key in ["x-spam-flag", "x-spam-status", "x-junk", "x-spam"] {
            let value = h[key, default: ""].trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("yes") || value == "true" || value == "1" { return true }
        }
        return false
    }

    private static func split(_ data: Data) throws -> ([String: String], Data) {
        let limit = data.prefix(128 * 1_024)
        let separator = limit.range(of: Data([13, 10, 13, 10])) ?? limit.range(of: Data([10, 10]))
        guard let separator else { throw Failure.malformed }
        let raw = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !lines.isEmpty else { throw Failure.malformed }
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else { lines.append(line) }
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformed }
            let name = line[..<colon].lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Duplicate structural headers are ambiguous and must not bypass attachment policy.
            if headers[name] != nil && ["content-type", "content-transfer-encoding", "content-disposition"].contains(name) {
                throw Failure.malformed
            }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        return (headers, Data(data[separator.upperBound...]))
    }

    /// Semicolon parameters with quoted/escaped values; parameter names include RFC2231 suffixes.
    static func parameters(_ value: String) -> (type: String, params: [String: String]) {
        var fields: [String] = [], current = "", quoted = false, escaped = false
        for c in value {
            if escaped { current.append(c); escaped = false }
            else if c == "\\" && quoted { escaped = true }
            else if c == "\"" { quoted.toggle() }
            else if c == ";" && !quoted { fields.append(current); current = "" }
            else { current.append(c) }
        }
        fields.append(current)
        var params: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let eq = field.firstIndex(of: "=") else { continue }
            params[field[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                String(field[field.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (fields[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), params)
    }

    private static func extract(_ h: [String: String], _ body: Data, depth: Int, parts: inout Int, truncated: inout Bool, preserveContext: Bool) throws -> String {
        parts += 1
        guard depth < 16, parts <= 256 else { throw Failure.unsupported }
        let content = parameters(h["content-type"] ?? "text/plain")
        let disposition = parameters(h["content-disposition"] ?? "")
        let named = Array(content.params.keys) + Array(disposition.params.keys)
        // Includes inline files, RFC2231 extended/continued filenames, and attached emails.
        guard disposition.type.isEmpty || disposition.type == "inline" else { return "" }
        guard
              !named.contains(where: { $0 == "name" || $0.hasPrefix("name*") || $0 == "filename" || $0.hasPrefix("filename*") }),
              !content.type.hasPrefix("message/") else { return "" }
        if content.type.hasPrefix("multipart/") {
            guard ["multipart/mixed", "multipart/alternative", "multipart/related", "multipart/signed"].contains(content.type),
                  let boundary = content.params["boundary"], !boundary.isEmpty, boundary.utf8.count <= 200,
                  !boundary.contains("\n"), !boundary.contains("\r") else { throw Failure.unsupported }
            // Boundaries match complete lines only; base64 attachment payloads are never decoded.
            let marker = Data(("--" + boundary).utf8)
            var segments: [Data] = [], start: Int?, offset = body.startIndex, closed = false
            while offset < body.endIndex {
                let end = body[offset...].firstIndex(of: 10) ?? body.endIndex
                var line = body[offset..<end]
                while let last = line.last, last == 13 || last == 32 || last == 9 { line = line.dropLast() }
                let closing = line == marker + Data([45, 45])
                if line == marker || closing {
                    if let start { segments.append(Data(body[start..<offset])) }
                    start = min(end + 1, body.endIndex)
                    if closing { closed = true; break }
                }
                offset = min(end + 1, body.endIndex)
            }
            guard closed else { throw Failure.incompleteMultipart }
            // related's root is the first part unless Content-Type names it by Content-ID.
            // Other related parts (including unnamed inline resources) are not message bodies.
            if content.type == "multipart/related" || content.type == "multipart/signed" {
                let rootID = content.params["start"]
                for (index, segment) in segments.enumerated() {
                    let (ph, pb) = try split(segment)
                    if let rootID {
                        guard ph["content-id"] == rootID else { continue }
                    } else if index != 0 { continue }
                    return try extract(ph, pb, depth: depth + 1, parts: &parts, truncated: &truncated, preserveContext: preserveContext)
                }
                throw Failure.missingBodyPart
            }
            var extracted: [(type: String, text: String)] = []
            var alternativeError: Error?
            for segment in segments {
                let (ph, pb) = try split(segment)
                do {
                    let text = try extract(ph, pb, depth: depth + 1, parts: &parts, truncated: &truncated, preserveContext: preserveContext)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { extracted.append((parameters(ph["content-type"] ?? "text/plain").type, text)) }
                } catch {
                    // Alternatives are representations of the same body. An unavailable plain
                    // part must not hide readable HTML (or vice versa). Mixed message sections
                    // are not interchangeable: keep failures there retryable, never silently omit.
                    guard content.type == "multipart/alternative", depth < 15, parts < 256,
                          error as? Failure != .malformed else { throw error }
                    alternativeError = error
                }
            }
            if content.type == "multipart/alternative" {
                if let text = extracted.first(where: { $0.type == "text/plain" })?.text ?? extracted.last?.text { return text }
                if let alternativeError { throw alternativeError }
                return ""
            }
            return bounded(extracted.map(\.text).joined(separator: "\n"), truncated: &truncated)
        }
        guard content.type == "text/plain" || content.type == "text/html" else { return "" }
        if let length = h["x-apple-content-length"].flatMap(Int.init), length > 0,
           body.allSatisfy({ [9, 10, 13, 32].contains($0) }) { throw Failure.unavailable }
        let decoded: Data
        switch h["content-transfer-encoding", default: "7bit"].lowercased() {
        case "base64":
            let clean = body.filter { ![9, 10, 13, 32].contains($0) }
            guard let bytes = Data(base64Encoded: clean) else { throw Failure.invalidTransferEncoding }
            decoded = bytes
        case "quoted-printable": decoded = try quotedPrintable(body)
        case "7bit", "8bit", "binary": decoded = body
        default: throw Failure.unsupported
        }
        let charset = content.params["charset", default: "utf-8"].lowercased()
        let encoding: String.Encoding
        switch charset {
        case "utf-8", "utf8", "us-ascii", "ascii": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cf != kCFStringEncodingInvalidId else { throw Failure.unsupported }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        guard let text = String(data: decoded, encoding: encoding) else { throw Failure.invalidText }
        let result = bounded(content.type == "text/html" ? htmlText(text, preserveContext: preserveContext) : text, truncated: &truncated)
        return result
    }

    private static func quotedPrintable(_ data: Data) throws -> Data {
        let bytes = Array(data); var result = Data(), i = 0
        func hex(_ n: UInt8) -> UInt8? {
            switch n { case 48...57: return n - 48; case 65...70: return n - 55; case 97...102: return n - 87; default: return nil }
        }
        while i < bytes.count {
            if bytes[i] != 61 { result.append(bytes[i]); i += 1; continue }
            if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
            if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
            guard i + 2 < bytes.count, let a = hex(bytes[i + 1]), let b = hex(bytes[i + 2]) else { throw Failure.invalidTransferEncoding }
            result.append(a * 16 + b); i += 3
        }
        return result
    }

    /// RFC2047 attribution headers, decoded locally without touching identity/header policy.
    /// Invalid encoded words stay as supplied; never guess their charset or fetch anything.
    static func decodedHeader(_ value: String) -> String {
        var text = value.replacingOccurrences(of: #"(?<=\?=)[ \t]+(?==\?)"#, with: "", options: .regularExpression)
        let pattern = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)
        let raw = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: raw.length)).reversed() {
            let charset = raw.substring(with: match.range(at: 1))
            let mode = raw.substring(with: match.range(at: 2)).lowercased()
            let value = raw.substring(with: match.range(at: 3))
            let data = mode == "b" ? Data(base64Encoded: value)
                : try? quotedPrintable(Data(value.replacingOccurrences(of: "_", with: " ").utf8))
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard let data, cf != kCFStringEncodingInvalidId,
                  let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))),
                  let range = Range(match.range, in: text) else { continue }
            text.replaceSubrange(range, with: decoded)
        }
        // Encoded words cannot introduce extra attribution-header lines.
        return text.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Truncate on a Unicode scalar boundary; byte slicing must not invent replacement characters.
    static func prefixUTF8(_ text: String, limit: Int) -> String {
        let bytes = text.utf8
        guard bytes.count > limit else { return text }
        var end = bytes.index(bytes.startIndex, offsetBy: max(0, limit))
        while end > bytes.startIndex, bytes[end] & 0xC0 == 0x80 { end = bytes.index(before: end) }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// No WebKit, attributed-string importer, image fetches, CSS, or JavaScript execution.
    /// Research retains quoted context and link destinations; ingestion keeps its existing text.
    static func htmlText(_ html: String, preserveContext: Bool = false) -> String {
        var text = html
        var patterns = ["(?is)<!--.*?-->", "(?is)<(script|style|head|template)\\b[^>]*>.*?</\\1\\s*>"]
        if !preserveContext { patterns.append("(?is)<blockquote\\b[^>]*>.*?</blockquote\\s*>") }
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        if preserveContext {
            text = text.replacingOccurrences(of: #"(?is)<a\b[^>]*\bhref\s*=\s*(['"])((?:https?://|mailto:)[^'"]{1,8192})\1[^>]*>(.*?)</a\s*>"#,
                with: "$3 ($2)", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?is)<[^>]*>", with: " ", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
