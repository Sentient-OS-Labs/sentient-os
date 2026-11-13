// Matches explicit proofreading commands, leaving mentions, negations and compound tasks alone.
// Doc: Documentation - Proofread.md
import Foundation
nonisolated enum ProofreadRequest {
    static func matches(_ text: String) -> Bool {
        guard text.utf8.count <= 1_000 else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = #"^(?:(?:hey\s+)?(?:sentient|sidekick)[,\s]+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:just\s+)?"#
        let target = #"(?:this|that|it|(?:this|the|my)\s+(?:selected\s+)?text|(?:the|my)\s+selection)"#
        let action = #"(?:proof\s?read(?:\s+"# + target + #")?|(?:fix|correct)\s+(?:the\s+)?(?:grammar|spelling|typos)(?:\s+(?:in|of)\s+"# + target + ")?)"
        let pattern = prefix + action + #"(?:\s+for\s+me)?(?:[,\s]+please)?[.!?]*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
