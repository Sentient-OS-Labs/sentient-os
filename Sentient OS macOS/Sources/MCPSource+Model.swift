//
// MCPSource+Model.swift
// Runs tool-free selection and summarization for native connector readers, with shared metering.
// Doc: Documentation - Sources - Cloud (Gmail, Calendar).md
//

import Foundation
import os

extension MCPSource {
    static func model(prompt: String, schema: String, slug: String,
                      claudeModel: ClaudeCLI.Model?) async throws -> CodexCLI.Envelope {
        let invocation = modelInvocation(prompt: prompt, schema: schema, claudeModel: claudeModel)
        let result = try await FrontierRun.run(invocation)
        meter.withLock { values in
            var total = values[slug] ?? (0, 0)
            total.tokensIn += result.inputTokens ?? 0
            total.tokensOut += result.outputTokens ?? 0
            values[slug] = total
        }
        return result
    }

    static func modelInvocation(prompt: String, schema: String, claudeModel: ClaudeCLI.Model?) -> CodexCLI.Invocation {
        var invocation = CodexCLI.Invocation(prompt: prompt)
        invocation.feature = "mcp-read"
        invocation.model = .gpt6luna
        invocation.claudeModel = claudeModel
        invocation.effort = .medium
        invocation.sandbox = .readOnly
        invocation.includeUserConfig = false
        invocation.toolsDisabled = true
        invocation.webSearch = false
        invocation.timeout = 300
        invocation.outputSchema = schema
        return invocation
    }
}
