//
// MCPSource+Evidence.swift
// Verifies a real successful Drive read before accepting a model's summary or quiet result.
// Matches Claude tool calls to results; Codex supplies completed MCP-call events directly.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation

extension MCPSource {
    static func hasDriveReadEvidence(raw: String, backend: ModelBackend,
                                     requiresDiscovery: Bool) -> Bool {
        let reads: Set<String>
        let discovery: Set<String>
        switch backend {
        case .claude:
            let names = ConnectorRegistry.pack(forSlug: "google-drive")?.readTools ?? []
            let prefix = ConnectorRegistry.pack(forSlug: "google-drive")?.claudeToolPrefix ?? ""
            reads = Set(names.flatMap { [$0, prefix + $0] })
            discovery = Set(["search_files", "list_recent_files"].flatMap { [$0, prefix + $0] })
        case .chatgpt:
            let names = ConnectorRegistry.pack(forSlug: "google-drive")?.codexReadTools ?? []
            reads = Set(names.filter { $0 != "get_profile" }.flatMap { ["google_drive." + $0, "gdrive." + $0] })
            discovery = Set(["search", "recent_documents"].flatMap { ["google_drive." + $0, "gdrive." + $0] })
        case .custom:
            return false
        }
        let required = requiresDiscovery ? discovery : reads
        if backend == .chatgpt {
            return successfulCodexMCPResults(raw: raw).contains { required.contains($0.tool) }
        }
        return !successfulClaudeMCPToolNames(raw: raw).isDisjoint(with: required)
    }

    static func hasDirectReadEvidence(raw: String, connection: DirectMCPConnection, backend: ModelBackend,
                                     requiredNames: Set<String>? = nil) -> Bool {
        let reads = (connection.provider?.reviewedReads ?? []).intersection(requiredNames ?? connection.provider?.reviewedReads ?? [])
        if backend == .claude {
            return !successfulClaudeMCPToolNames(raw: raw).isDisjoint(with: Set(reads.map { connection.toolPrefix + $0 }))
        }
        return successfulCodexMCPResults(raw: raw).contains {
            $0.server == connection.serverName && reads.contains($0.tool)
        }
    }

    static func successfulClaudeMCPToolNames(raw: String) -> Set<String> {
        MCPCallEvidence.claude(raw: raw)
    }

    static func successfulCodexMCPResults(raw: String) -> [(server: String?, tool: String, result: [String: Any])] {
        MCPCallEvidence.codex(raw: raw)
    }
}
