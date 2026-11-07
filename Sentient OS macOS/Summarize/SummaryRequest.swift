// Recognizes explicit requests about the visible screen before ordinary Sidekick submission.
// match() deliberately leaves quoted mentions, negation, files, history and compound actions alone.
// Doc: Documentation - Summarize.md
import Foundation

nonisolated enum SummaryRequest {
    static func match(_ text: String) -> String? {
        guard text.utf8.count <= 1_000 else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "’", with: "'")
        // Full-sentence grammar, not a keyword search. Modifiers describe only summary format.
        let prefix = #"(?:(?:hey\s+)?sentient[,\s]+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?summari[sz]e"#
        let target = #"(?:\s+(?:this(?:\s+(?:screen|page|article|email|message|document|chart|conversation|code))?|that|it|(?:my|the)\s+(?:current\s+)?screen|what(?:'s|\s+is)\s+on\s+(?:(?:my|the)\s+)?screen|what\s+i(?:'m|\s+am)\s+looking\s+at))?"#
        let format = #"(?:\s+(?:briefly|concisely|simply|quickly|in\s+(?:(?:[1-9]|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:short\s+)?(?:bullets?|bullet\s+points?|sentences?|paragraphs?)|plain\s+english|simple\s+terms|english|spanish|french|german|hindi|japanese|chinese|korean|portuguese|arabic)))?"#
        let pattern = "^" + prefix + target + #"(?:\s+for\s+me)?"# + format + #"(?:\s+for\s+me)?"# + #"(?:[,\s]+please)?[.!?]*$"#
        guard normalized.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
