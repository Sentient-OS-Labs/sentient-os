//
//  EMLXParser.swift
//  Sentient OS macOS
//
//  Extracts the human-readable body text from a Mail.app `.emlx` file. Pure static
//  functions with NO I/O, so the format logic is testable in isolation — same shape as
//  NotesSource.decodeBody (gunzip → protobuf walk) and iMessageSource.typedstreamText.
//
//  The `.emlx` layout (reverse-engineered, corroborated by the Library of Congress
//  format description fdd000615 and the PyPI `emlx` package):
//
//      <bytecount>\n            ← decimal ASCII on the first line
//      <bytecount bytes>        ← the full RFC 5322 / MIME message
//      <?xml … plist …>         ← Apple's metadata trailer (flags, subject, …)
//
//  The bytecount makes extraction UNAMBIGUOUS: read the first line as the count, then
//  take exactly that many bytes as the message — no need to hunt for the plist marker
//  (which would be ambiguous if a message body itself contained "<?xml").
//
//  Bodies vary enormously (7bit / 8bit / quoted-printable / base64, nested multipart,
//  HTML-only, encrypted, …), so everything here is FAIL-CLOSED: any step that can't be
//  decoded returns nil and the caller falls back to envelope-metadata-only triage — the
//  same philosophy as the other DB sources (an undecodable note is skipped, never fed
//  garbled to the model). The envelope alone already yields a strong keeper/junk call
//  (it's all the Gmail connector works from), so a missing body is a graceful degrade.
//

import Foundation

nonisolated enum EMLXParser {

    /// Max body characters handed to the triage model (same order of magnitude as
    /// NotesSource.maxContentChars). Keeps the prompt under the KV cache.
    static let maxBodyChars = 6_000

    /// The full plain-text body of a `.emlx` file, or nil if the file can't be decoded
    /// (unreadable, truncated, encrypted, or no recoverable text part).
    static func bodyText(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let message = messageBytes(in: data) else { return nil }
        return plainText(fromMIME: message)
    }

    // MARK: - Bytecount framing

    /// The message portion of a `.emlx` file: the first line is a decimal byte count,
    /// and the next `count` bytes are the RFC 5322 message. nil if the framing is invalid
    /// or the file is truncated.
    static func messageBytes(in data: Data) -> Data? {
        // The bytecount is ASCII on the first line; find the first newline.
        guard let nl = data.firstIndex(of: 0x0A) else { return nil }
        let firstLine = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let count = Int(firstLine), count > 0 else { return nil }
        let start = nl + 1
        let end = start + count
        guard end <= data.endIndex else { return nil }   // truncated
        return data[start..<end]
    }

    // MARK: - MIME → plain text

    /// Extract readable text from a full RFC 5322 / MIME message. Prefers `text/plain`,
    /// falls back to de-tagged `text/html`, walks nested multiparts. nil when nothing
    /// textual can be recovered (encrypted, image-only, …).
    static func plainText(fromMIME message: Data) -> String? {
        // Split headers from body at the first blank line (CRLF or LF tolerant).
        let (headers, body) = splitHeaderBody(message)
        let contentType = headerValue("content-type", in: headers) ?? "text/plain"
        let cte = headerValue("content-transfer-encoding", in: headers) ?? "7bit"

        return extract(from: body, contentType: contentType, cte: cte)
    }

    /// Recursive extractor: given a body blob + its Content-Type + transfer encoding,
    /// return the best text. Depth-capped so a pathological nested multipart can't recurse
    /// forever.
    private static func extract(from body: Data, contentType: String, cte: String,
                                depth: Int = 0) -> String? {
        guard depth < 12 else { return nil }
        let lowered = contentType.lowercased()

        if lowered.hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType),
                  let boundaryData = boundary.data(using: .utf8) else { return nil }
            return extractMultipart(body, boundary: boundaryData, depth: depth)
        }

        if lowered.hasPrefix("text/plain") {
            let decoded = decodeTransfer(body, encoding: cte)
            let charset = parameter("charset", in: contentType) ?? "utf-8"
            return cleanBody(stringInCharset(decoded, charset: charset))
        }

        if lowered.hasPrefix("text/html") {
            let decoded = decodeTransfer(body, encoding: cte)
            let charset = parameter("charset", in: contentType) ?? "utf-8"
            guard let html = stringInCharset(decoded, charset: charset) else { return nil }
            return cleanBody(stripHTML(html))
        }

        if lowered.hasPrefix("multipart/alternative") { return nil }  // handled by multipart path
        return nil   // attachments, images, etc. — no text
    }

    /// Split a multipart body on its boundary, then collect text from the parts — preferring
    /// a `text/plain` part, else the first `text/html` part. (multipart/alternative lists the
    /// SAME content in increasing fidelity, so plain wins when present.)
    private static func extractMultipart(_ body: Data, boundary: Data, depth: Int) -> String? {
        let parts = splitOnBoundary(body, boundary: boundary)
        var htmlFallback: String?
        for part in parts {
            let (headers, partBody) = splitHeaderBody(part)
            let type = headerValue("content-type", in: headers) ?? "text/plain"
            let partCTE = headerValue("content-transfer-encoding", in: headers) ?? "7bit"
            // Skip attachment parts (they carry a filename) — we only want inline text.
            if type.lowercased().contains("name=") ||
               headerValue("content-disposition", in: headers)?.lowercased().contains("attachment") == true {
                continue
            }
            if let text = extract(from: partBody, contentType: type, cte: partCTE, depth: depth + 1),
               !text.isEmpty {
                if type.lowercased().hasPrefix("text/plain") { return text }   // plain wins immediately
                if htmlFallback == nil { htmlFallback = text }
            }
        }
        return htmlFallback
    }

    /// Split a multipart body into its raw part blobs. A boundary appears as
    /// `--<boundary>` on its own line; the closing delimiter is `--<boundary>--`.
    private static func splitOnBoundary(_ body: Data, boundary: Data) -> [Data] {
        var dashBoundary = Data("--".utf8); dashBoundary.append(boundary)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?

        while searchStart < body.endIndex {
            guard let range = body.range(of: dashBoundary, in: searchStart..<body.endIndex) else { break }
            if let start = partStart {
                // Capture everything between the previous boundary line and this one.
                var slice = body[start..<range.lowerBound]
                trimTrailingNewlines(&slice)
                if !slice.isEmpty { parts.append(slice) }
            }
            // Move past this boundary line. If it's the closing `--`, we're done.
            let afterBoundary = range.upperBound
            if afterBoundary + 2 <= body.endIndex,
               body[afterBoundary] == 0x2D, body[afterBoundary + 1] == 0x2D { break }
            // Skip to the end of the boundary line. the part begins on the next line.
            if let lineEnd = body[afterBoundary...].firstIndex(of: 0x0A) {
                partStart = lineEnd + 1
                searchStart = lineEnd + 1
            } else { break }
        }
        return parts
    }

    // MARK: - Transfer encodings

    /// Decode a Content-Transfer-Encoding (7bit/8bit/binary → as-is; quoted-printable and
    /// base64 → decoded). Unknown encodings pass through unchanged (fail-open to raw bytes).
    private static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        switch encoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "quoted-printable": return decodeQuotedPrintable(data)
        case "base64":           return Data(base64Encoded: stripBase64Noise(data)) ?? data
        default:                 return data   // 7bit / 8bit / binary
        }
    }

    /// Quoted-printable: `=XX` hex escapes and soft line breaks (`=\n` / `=\r\n`).
    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        while i < data.endIndex {
            let b = data[i]
            if b == 0x3D /* '=' */ {
                // Soft line break: '=' immediately followed by newline.
                if i + 1 < data.endIndex, data[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < data.endIndex, data[i + 1] == 0x0D, data[i + 2] == 0x0A { i += 3; continue }
                // Hex escape =XX.
                if i + 2 < data.endIndex,
                   let hi = hexVal(data[i + 1]), let lo = hexVal(data[i + 2]) {
                    out.append(UInt8(hi << 4 | lo)); i += 3; continue
                }
                // Malformed escape — emit the '=' and move on.
                out.append(b); i += 1; continue
            }
            out.append(b); i += 1
        }
        return out
    }

    private static func stripBase64Noise(_ data: Data) -> Data {
        // base64 ignores whitespace/newlines; Data(base64Encoded:) is strict, so strip them.
        Data(data.filter { !([0x0A, 0x0D, 0x20, 0x09] as [UInt8]).contains($0) })
    }

    private static func hexVal(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41) + 10
        case 0x61...0x66: return Int(b - 0x61) + 10
        default:          return nil
        }
    }

    // MARK: - Charset + cleanup

    /// Decode bytes in the given MIME charset (utf-8 / iso-8859-* / us-ascii / windows-1252 …).
    /// Falls back to a lossy UTF-8 decode, then to Latin-1, so we always return *something*
    /// readable rather than nil for an odd charset.
    private static func stringInCharset(_ data: Data, charset: String) -> String? {
        let cs = charset.lowercased().trimmingCharacters(in: .whitespaces)
        let enc: String.Encoding
        switch cs {
        case "utf-8", "utf8":                      enc = .utf8
        case "us-ascii", "ascii":                  enc = .ascii
        case "iso-8859-1", "latin1", "latin-1":    enc = .isoLatin1
        case "iso-8859-2", "latin2":               enc = .isoLatin2
        case "windows-1252", "cp1252":             enc = .windowsCP1252
        case "utf-16":                             enc = .utf16
        case "shift_jis", "shift-jis":             enc = .shiftJIS
        case "iso-2022-jp":                        enc = .iso2022JP
        case "euc-jp":                             enc = .japaneseEUC
        case "gb2312", "gbk", "gb18030":           enc = .iso2022JP   // best-effort; rare
        default:                                   enc = .utf8
        }
        if let s = String(data: data, encoding: enc) { return s }
        return String(decoding: data, as: UTF8.self)   // lossy UTF-8 — never nil
    }

    /// Strip HTML down to readable text: drop script/style blocks, convert <br>/<p>/block
    /// closers to newlines, remove remaining tags, then collapse whitespace and decode the
    /// common named entities. Deliberately a lightweight regex pass, not a real HTML parser.
    private static func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<head[^>]*>.*?</head>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)   // HTML comments
        s = s.replacingOccurrences(of: "(?i)<br[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|tr|h[1-6]|table|blockquote)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return s
    }

    /// Decode the handful of named/numeric entities that dominate email HTML, then let the
    /// whitespace collapse in cleanBody do the rest.
    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&mdash;": "\u{2014}",
            "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&copy;": "\u{00A9}",
            "&reg;": "\u{00AE}", "&trade;": "\u{2122}",
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities: &#123; and &#xABC;
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let numStr = ns.substring(with: m.range(at: 2))
                let scalar: UInt32? = hex ? UInt32(strtoul(numStr, nil, 16)) : UInt32(numStr)
                if let sc = scalar, let u = Unicode.Scalar(sc) { result.append(Character(u)) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    /// Normalize a decoded body: strip a trailing signature block, remove zero-width
    /// tracking characters, collapse blank-line runs, trim, and cap to maxBodyChars.
    /// nil if empty.
    private static func cleanBody(_ s: String?) -> String? {
        guard var s else { return nil }
        if let sigRange = s.range(of: "\n-- \n") { s = String(s[..<sigRange.lowerBound]) }
        // Strip zero-width / invisible Unicode (tracking pixels, BOM, directional marks).
        s = s.replacingOccurrences(of: "[\u{200B}-\u{200F}\u{2028}-\u{202F}\u{FEFF}\u{034F}]",
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count > maxBodyChars { s = String(s.prefix(maxBodyChars)) + "…" }
        return s
    }

    // MARK: - Header helpers (operate on the raw header blob)

    /// Split a message/part blob into (header bytes, body bytes) at the first blank line,
    /// tolerating CRLF and LF.
    private static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        // CRLF blank line first.
        if let r = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
            return (data[data.startIndex..<r.lowerBound], data[r.upperBound...])
        }
        if let r = data.range(of: Data([0x0A, 0x0A])) {
            return (data[data.startIndex..<r.lowerBound], data[r.upperBound...])
        }
        return (data, Data())   // headers only
    }

    /// Unfolded value of a header (case-insensitive), with RFC 2047 encoded-words decoded
    /// enough to be readable. Headers can span multiple lines (continuation lines start
    /// with whitespace) — unfold them first.
    private static func headerValue(_ name: String, in headers: Data) -> String? {
        let text = String(decoding: headers, as: UTF8.self)
        let lines = unfold(text)
        let needle = name.lowercased()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == needle {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return decodeEncodedWords(value)
            }
        }
        return nil
    }

    /// A named parameter from a structured header, e.g. `boundary="----=_Part"` or
    /// `charset=utf-8` out of a Content-Type value. Handles quoted and unquoted values.
    private static func parameter(_ name: String, in headerValue: String) -> String? {
        let needle = name.lowercased() + "="
        let lower = headerValue.lowercased()
        guard let r = lower.range(of: needle) else { return nil }
        var rest = headerValue[r.upperBound...]
        var value = ""
        if rest.first == "\"" {
            rest = rest.dropFirst()
            value = String(rest.prefix(while: { $0 != "\"" }))
        } else {
            value = String(rest.prefix(while: { $0 != ";" && $0 != " " && $0 != "\t" && $0 != "\r" && $0 != "\n" }))
        }
        return value.isEmpty ? nil : value
    }

    /// Unfold RFC 5322 headers: a CRLF/ LF followed by whitespace is a continuation of the
    /// previous logical line. Uses `components(separatedBy:)` (UTF-16 level via NSString)
    /// rather than `split(separator:)` — in Swift, CRLF is a single grapheme cluster, so
    /// `split(separator: "\n")` would never match the LF inside a `\r\n` pair and headers
    /// would never separate.
    private static func unfold(_ text: String) -> [String] {
        var logical: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }
            if let first = line.first, first == " " || first == "\t" {
                // Continuation — append to the previous logical line.
                if !logical.isEmpty {
                    logical[logical.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            logical.append(line)
        }
        return logical
    }

    /// Decode RFC 2047 encoded-words like `=?utf-8?Q?Hello?= ` / `=?iso-8859-1?B?…?=` so
    /// subjects/from-names with non-ASCII read correctly. Words separated by whitespace are
    /// joined per the RFC. Best-effort — leaves anything it can't decode as-is.
    private static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        guard let re = try? NSRegularExpression(
            pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let kind = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            var decoded: Data?
            if kind == "B" {
                decoded = Data(base64Encoded: payload)
            } else { // Q — quoted-printable with '_' meaning space
                let qp = payload.replacingOccurrences(of: "_", with: " ")
                decoded = decodeQuotedPrintable(Data(qp.utf8))
            }
            if let d = decoded, let str = stringInCharset(d, charset: charset) {
                result += str
            } else {
                result += ns.substring(with: m.range)   // leave as-is
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func trimTrailingNewlines(_ data: inout Data) {
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
    }
}
