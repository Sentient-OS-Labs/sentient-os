//
// MailQuoteStripper.swift
// Reduces a sent email body to the user's own words for writingstyle.md: the quoted thread is
// cut at its first boundary and client-inserted sign-offs are dropped. ownText(of:) is pure.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

/// A sent reply carries the whole earlier conversation under the user's text, and no mail API
/// hands back the new part alone. The boundary is found the way mail products find it: scan from
/// the top and cut at the first sign of quoted material. Ambiguity resolves toward cutting, since
/// losing a sentence of the user's costs nothing while another person's words would poison the
/// samples. A body with no boundary and no sign-off comes back unchanged apart from line endings.
nonisolated enum MailQuoteStripper {

    /// The user's own words from a sent body, or nil when nothing of theirs remains.
    static func ownText(of body: String) -> String? {
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cut = false
        if let boundary = firstBoundary(in: lines) {
            lines.removeSubrange(boundary...)
            cut = true
        }
        if let dash = lines.indices.first(where: { matches(lines[$0], signatureDash) }) {
            lines.removeSubrange(dash...)
            cut = true
        }
        while let last = lines.lastIndex(where: { !isBlank($0) }), matches(lines[last], deviceSignature) {
            lines.removeSubrange(last...)
            cut = true
        }
        let text = lines.joined(separator: "\n")
        guard let end = text.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        return cut ? String(text[...end]) : text
    }

    // MARK: - Boundaries

    private static func firstBoundary(in lines: [String]) -> Int? {
        lines.indices.first { index in
            matches(lines[index], separators) || isHeaderBlock(lines, at: index)
                || attribution(lines, at: index) != nil || startsQuoteRun(lines, at: index)
        }
    }

    /// Outlook's "From: … Sent: … To: … Subject:" block. One label alone is ordinary prose;
    /// a From line with a second label close under it is a quoted header.
    private static func isHeaderBlock(_ lines: [String], at index: Int) -> Bool {
        guard matches(lines[index], fromLabel) else { return false }
        return lines[(index + 1)..<min(index + 5, lines.count)].contains { matches($0, headerLabel) }
    }

    /// "On DATE, NAME <ADDRESS> wrote:" and its localizations, returned as one rejoined line.
    /// Gmail wraps long attribution lines, so up to three lines are rejoined, without a space
    /// after an opening bracket. Only rules anchored to an opening word may match a rejoined
    /// candidate; otherwise the user's own lines above the attribution would be glued onto it
    /// and cut away with it.
    private static func attribution(_ lines: [String], at index: Int) -> String? {
        guard !isBlank(lines[index]) else { return nil }
        var candidate = ""
        for position in index..<min(index + 3, lines.count) {
            let line = lines[position].trimmingCharacters(in: .whitespaces)
            if position == index {
                candidate = line
            } else {
                guard !line.isEmpty else { return nil }
                let opensBracket = candidate.last.map { "<([{\"'".contains($0) } ?? false
                candidate += opensBracket ? line : " " + line
            }
            let matched = matches(candidate, anchoredAttributions)
                || (position == index && matches(candidate, looseAttributions))
            if matched, hasAttributionEvidence(candidate) { return candidate }
        }
        return nil
    }

    /// Who a reply answered, read from its attribution line: the address in angle brackets and
    /// the name written before it. The name is the run of words before the bracket, stopped by
    /// the date, the time, or the line's own wording ("at", "PM", "schrieb"), since every client
    /// puts the name last. Nil when the reply has no attribution or it names no address.
    static func attributedAuthor(in body: String) -> (name: String?, address: String)? {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let index = firstBoundary(in: lines), let candidate = attribution(lines, at: index),
              let open = candidate.lastIndex(of: "<"), let close = candidate[open...].firstIndex(of: ">") else { return nil }
        let address = candidate[candidate.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return nil }
        var words: [String] = []
        for token in candidate[..<open].split(whereSeparator: \.isWhitespace).reversed() {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;:\"'“”"))
            guard !word.isEmpty, !word.contains(where: \.isNumber), !nameStopWords.contains(word.lowercased()),
                  words.count < 5 else { break }
            words.append(word)
        }
        return (words.isEmpty ? nil : words.reversed().joined(separator: " "), address)
    }

    /// Words that end the name when read backwards from the address.
    private static let nameStopWords: Set<String> = [
        "on", "at", "am", "pm", "uhr", "um", "à", "le", "el", "em", "il", "op", "den", "på", "vào",
        "wrote", "schrieb", "écrit", "a", "escribió", "escreveu", "scritto", "ha", "schreef", "skrev",
        "napisał", "pisze", "użytkownik", "пишет", "написал", "kirjoitti", "写道", "user", "via", "from", "de",
    ]

    /// Prose can end in "wrote:" too; a real attribution names a date or an address.
    private static func hasAttributionEvidence(_ candidate: String) -> Bool {
        candidate.contains { $0.isNumber || $0 == "@" } || (candidate.contains("<") && candidate.contains(">"))
    }

    /// A lone ">" can open a wrapped link or a markdown quote; quoted mail comes in runs.
    private static func startsQuoteRun(_ lines: [String], at index: Int) -> Bool {
        index + 1 < lines.count && matches(lines[index], quoted) && matches(lines[index + 1], quoted)
    }

    // MARK: - Rules

    private static func rule(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static func matches(_ line: String, _ rule: NSRegularExpression) -> Bool {
        rule.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
    private static func matches(_ line: String, _ rules: [NSRegularExpression]) -> Bool {
        rules.contains { matches(line, $0) }
    }
    private static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    /// Whole-line dividers that clients draw above quoted or forwarded mail.
    private static let separators = [
        // Outlook desktop's original-message banner and the Gmail, Apple Mail and Thunderbird
        // forward banners, in their common localizations.
        rule(#"(?i)^\s*[-–—_]{2,}\s*(original message|reply message|forwarded message|message original|message d['’]origine|message transféré|ursprüngliche nachricht|antwort nachricht|weitergeleitete nachricht|mensaje original|mensaje reenviado|mensagem original|mensagem encaminhada|messaggio originale|messaggio inoltrato|oorspronkelijk bericht|origineel bericht|doorgestuurd bericht|oprindelig besked|oprindelig meddelelse|videresendt besked|ursprungligt meddelande|vidarebefordrat meddelande|alkuperäinen viesti|wiadomość oryginalna|przekazana wiadomość|исходное сообщение|пересылаемое сообщение)\s*[-–—_]*\s*$"#),
        rule(#"(?i)^\s*(begin forwarded message|anfang der weitergeleiteten e-mail|début du message réexpédié|inicio del mensaje reenviado|inizio messaggio inoltrato|begin doorgestuurd bericht|início da mensagem reencaminhada)\s*:?\s*$"#),
        // Zoho, Android and BlackBerry frame the attribution in dashes.
        rule(#"(?i)^\s*[-–—]{2,}\s*.{0,400}?\b(wrote|schrieb|a écrit|escribió|escreveu|ha scritto|schreef|skrev|napisał|пишет|написал)\b\s*[-–—]{2,}\s*$"#),
        // Outlook web rules a line of underscores above the quoted header.
        rule(#"^\s*_{8,}\s*$"#),
    ]

    private static let fromLabel = rule(#"(?i)^\s*[>*]{0,4}\s*(from|von|de|da|van|fra|från|lähettäjä|nadawca|от кого|от|отправитель|发件人|寄件者|差出人|보낸\s?사람)\s*\*?\s*:"#)
    private static let headerLabel = rule(#"(?i)^\s*[>*]{0,4}\s*(from|sent|date|to|cc|bcc|subject|reply-to|von|gesendet|an|betreff|datum|de|envoyé|enviado|para|pour|à|objet|asunto|assunto|data|oggetto|van|verzonden|aan|onderwerp|da|fra|sendt|til|emne|dato|från|skickat|till|ämne|lähettäjä|lähetetty|vastaanottaja|aihe|nadawca|wysłano|temat|от кого|от|отправлено|кому|тема|дата|发件人|发送时间|收件人|主题|寄件者|差出人|送信日時|宛先|件名|보낸\s?사람|보낸\s?날짜|받는\s?사람|제목)\s*\*?\s*:"#)

    private static let quoted = rule(#"^ ?>"#)

    /// Attribution lines that open with a known word, so a wrapped line can be rejoined safely.
    private static let anchoredAttributions = [
        rule(#"^\s*(>\s*)*On\s.{1,500}\bwrote\s*:\s*$"#),                                                 // English
        rule(#"^\s*(>\s*)*Le\s.{1,500}\ba\s+écrit\s*:\s*$"#),                                             // French
        rule(#"^\s*(>\s*)*El\s.{1,500}\bescribió\s*:\s*$"#),                                              // Spanish
        rule(#"^\s*(>\s*)*Em\s.{1,500}\bescreveu\s*:\s*$"#),                                              // Portuguese
        rule(#"^\s*(>\s*)*(Il|In\s+data)\s.{1,500}\b(ha\s+)?scritto\s*:\s*$"#),                           // Italian
        rule(#"^\s*(>\s*)*Am\s.{1,500}\bschrieb\b.{0,200}:\s*$"#),                                       // German
        rule(#"^\s*(>\s*)*Op\s.{1,500}\b(schreef|verzond|geschreven)\b.{0,200}:\s*$"#),                   // Dutch
        rule(#"^\s*(>\s*)*(W\s+dniu|Dnia)\s.{1,500}\b(pisze|napisał(\(a\))?)\s*:\s*$"#),                  // Polish
        rule(#"^\s*(>\s*)*((Den|På)\s.{1,500}\bskrev\b.{0,200}|[a-zA-Zæøåäö]{2,4}\.\s.{1,500}\sskrev\s.{0,200}):\s*$"#), // Scandinavian
        rule(#"^\s*(>\s*)*Vào\s.{1,500}\bđã\s+viết\s*:\s*$"#),                                            // Vietnamese
        rule(#"^\s*(>\s*)*(在|於).{1,500}(写道|寫道)\s*[：:]\s*$"#),                                         // Chinese
        rule(#"^\s*(>\s*)*(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[./]\d{1,2}[./]\d{2,4}).{0,300}<[^<>\s]+@[^<>\s]+>\s*:?\s*$"#), // date first
    ]

    /// Attribution lines recognized by their ending alone, so they are tested on single lines only.
    private static let looseAttributions = [
        rule(#"(?i)^.{0,500}\bwrote\s*:\s*$"#),                                                           // English, any client
        rule(#"^.{1,300}<[^<>]+>\s*schrieb\s*:\s*$"#),                                                    // German, name first
        rule(#"^.{1,500}\bkirjoitti\s*:\s*$"#),                                                           // Finnish
        rule(#"^.{1,500}\b(написал\(а\)|написал|пишет|пише)\s*:\s*$"#),                                   // Russian, Ukrainian
        rule(#"^.{1,500}(のメッセージ|さんは書きました)\s*[：:]\s*$"#),                                        // Japanese
        rule(#"^.{1,500}(작성|님이\s*쓴\s*글)\s*[：:]\s*$"#),                                                // Korean
    ]

    /// Lines a phone or mail app appends on its own. Real sign-offs are the user's voice and stay.
    private static let deviceSignature = rule(#"(?i)^\s*(sent from my (iphone|ipad|ipod|galaxy|samsung|android|blackberry|windows phone|huawei|pixel|phone|mobile)\b.{0,40}|sent from (outlook|mail for windows|yahoo mail|proton mail|protonmail|gmail|superhuman|spark|front|hey|canary)\b.{0,60}|sent via (superhuman|spark|front|mixmax)\b.{0,60}|get outlook for (ios|android).{0,80}|<?https?://aka\.ms/\S*>?|envoyé de mon .{0,40}|envoyé depuis .{0,40}|envoyé à partir de .{0,40}|télécharger outlook pour .{0,40}|enviado desde .{0,40}|enviado do meu .{0,40}|von meinem .{0,40} gesendet|gesendet von .{0,60}|verzonden vanaf .{0,40}|verstuurd vanaf .{0,40}|sendt fra .{0,40}|skickat från .{0,40}|lähetetty .{0,40}|inviato da .{0,40})\s*$"#)

    /// The RFC 3676 signature separator: everything under a "-- " line is a configured signature.
    private static let signatureDash = rule(#"^-- ?$"#)
}
