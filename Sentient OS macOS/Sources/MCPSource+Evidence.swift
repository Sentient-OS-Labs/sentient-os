//
// MCPSource+Evidence.swift
// Native Codex result extraction used to read account identity.
// Knowledge summaries do not require a separate proof of successful tool calls.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

extension MCPSource {
    static func successfulCodexMCPResults(raw: String) -> [(server: String?, tool: String, result: [String: Any])] {
        MCPCallEvidence.codex(raw: raw)
    }
}
