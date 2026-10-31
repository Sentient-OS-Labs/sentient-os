// Decodes bounded MCP result envelopes consistently for account and native content readers.
// Objects are not merged: each reader must reject ambiguous or conflicting provider evidence.
// Doc: Documentation - Connectors (Direct MCP).md

import Foundation
import CoreFoundation

nonisolated enum DirectMCPResult {
    static func hasValidStructuredContent(_ result: [String: Any]) -> Bool {
        ["structuredContent", "structured_content"].allSatisfy {
            result[$0] == nil || result[$0] is [String: Any]
        }
    }

    /// Nil is malformed status, distinct from a tool's explicit failed result.
    static func errorState(_ result: [String: Any]) -> Bool? {
        var failed = false
        for key in ["isError", "is_error"] {
            guard let value = result[key] else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            failed = failed || number.boolValue
        }
        return failed
    }

    static func textBlocks(_ result: [String: Any]) -> [String] {
        guard let blocks = result["content"] as? [[String: Any]], blocks.count <= 32 else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
    }

    /// Structured data and its JSON text mirror are one payload. Independent objects remain
    /// separate so a consumer cannot accidentally choose between different accounts or notes.
    static func objects(_ result: [String: Any]) -> [[String: Any]] {
        var values: [[String: Any]] = []
        for key in ["structuredContent", "structured_content"] {
            if let value = result[key] as? [String: Any] { values.append(value) }
        }
        values += textBlocks(result).compactMap { text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
        var seen = Set<Data>()
        return values.filter { value in
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return false }
            return seen.insert(data).inserted
        }
    }
}
