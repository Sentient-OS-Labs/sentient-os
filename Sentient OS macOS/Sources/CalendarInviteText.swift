// CalendarInviteText.swift
// Removes Microsoft Teams join blocks and Outlook link annotations from calendar notes before
// projection. Meeting IDs, passcodes and dial-in boilerplate never reach the model or its budget.
// Doc: Documentation - Sources - Local (Files, WhatsApp, iMessage, Notes).md

import Foundation

nonisolated enum CalendarInviteText {
    /// Outlook draws invitation sections between long underscore rules.
    private static let rule = try! NSRegularExpression(pattern: #"^\s*_{20,}\s*$"#)
    /// Outlook's plain-text form of a hyperlink: the visible label followed by `<https://…>`.
    private static let linkAnnotation = try! NSRegularExpression(pattern: #"<https?://[^\s<>]*>"#)
    private static let joinMarkers = ["teams.microsoft.com", "microsoft teams", "aka.ms/jointeamsmeeting"]

    /// Drops every closed rule-to-rule section that mentions Teams, and the rules around it.
    /// Text before the first rule and after the last one is the organizer's own and is kept.
    static func readable(_ notes: String) -> String {
        var lines = notes.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rules = lines.indices.filter { isRule(lines[$0]) }
        var dropped = IndexSet()
        for (start, end) in zip(rules, rules.dropFirst()) {
            let section = lines[start..<end].joined(separator: "\n").lowercased()
            guard joinMarkers.contains(where: section.contains) else { continue }
            dropped.insert(integersIn: start...end)
        }
        if !dropped.isEmpty {
            lines = lines.indices.filter { !dropped.contains($0) && !isRule(lines[$0]) }.map { lines[$0] }
        }
        var text = lines.joined(separator: "\n")
        text = linkAnnotation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = text.replacingOccurrences(of: #"\n[ \t]*(\n[ \t]*)+\n"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRule(_ line: String) -> Bool {
        rule.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
