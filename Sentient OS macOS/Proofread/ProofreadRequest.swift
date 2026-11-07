// Matches explicit proofreading commands, leaving mentions, negations and compound tasks alone.
// Doc: Documentation - Proofread.md
import Foundation
nonisolated enum ProofreadRequest {
    static func matches(_ text: String) -> Bool {
        guard text.utf8.count <= 1_000 else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:(?:hey\s+)?sentient[,\s]+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?proof\s?read(?:\s+(?:this|that|it|(?:this|the|my)\s+(?:selected\s+)?text|(?:the|my)\s+selection))?(?:\s+for\s+me)?(?:[,\s]+please)?[.!?]*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
