//
//  PIIScan.swift
//  Sentient OS macOS  ·  Engine/
//
//  Deterministic PII backstop for on-device triage. The triage prompt tells the model to omit
//  high-risk identifiers from summaries, but a small on-device model can slip — so `Triage.decide()`
//  runs this over any would-be survivor and, on a hit, drops the whole item as `.sensitive` (nothing
//  stored, zero trace, never sent to the cloud). Tuned to favour catching the three the prompt names
//  — US SSN · credit-card number (Luhn-checked) · passport number — over sparing a summary: dropping
//  a good summary is cheap, leaking a card number is not. Patterns verified against a positive/
//  negative suite before shipping.
//
//  Key method: `containsHighRiskPII(_:)`.
//

import Foundation

enum PIIScan {

    /// True if the text contains a US SSN, a Luhn-valid card number, or a passport number.
    static func containsHighRiskPII(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return matches(ssn, text) || containsCardNumber(text) || matches(passport, text)
    }

    // 3-2-4 digits with a dash/space separator, skipping the invalid SSN ranges (area 000/666/9xx,
    // group 00, serial 0000). Requires separators — a bare 9-digit run is too false-positive-prone.
    private static let ssn = re(#"\b(?!000|666|9\d\d)\d{3}[ -](?!00)\d{2}[ -](?!0000)\d{4}\b"#)

    // A 13–19 digit run (single space/dash separators allowed), then validated by Luhn below —
    // random 13–19 digit strings almost never pass Luhn, so this rarely fires on a real order number.
    private static let cardCandidate = re(#"\b\d(?:[ -]?\d){12,18}\b"#)

    // "passport" followed within a short gap by a 6–9 char alphanumeric code containing a digit.
    // Context-gated so it never nukes a summary that merely mentions a passport with no number.
    private static let passport = re(#"(?i)passport\b.{0,24}?\b(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{6,9}\b"#)

    private static func containsCardNumber(_ text: String) -> Bool {
        let ns = text as NSString
        for m in cardCandidate.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let digits = ns.substring(with: m.range).filter(\.isNumber)
            if (13...19).contains(digits.count), luhnValid(digits) { return true }
        }
        return false
    }

    private static func luhnValid(_ digits: String) -> Bool {
        var sum = 0, alt = false
        for ch in digits.reversed() {
            guard let d = ch.wholeNumberValue else { return false }
            let v = alt ? (d * 2 > 9 ? d * 2 - 9 : d * 2) : d
            sum += v
            alt.toggle()
        }
        return sum % 10 == 0
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
}
