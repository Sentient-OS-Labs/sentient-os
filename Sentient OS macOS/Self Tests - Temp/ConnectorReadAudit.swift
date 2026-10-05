#if DEBUG
//
// ConnectorReadAudit.swift
// Exports complete production prompts and accepted KB summaries for connector taste reviews.
// Reads default to an isolated store; LAB_USE_LIVE_STORE=1 explicitly selects the user's store.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation
import SwiftData
import os

enum ConnectorReadAudit {
    struct Receipt: Codable, Sendable {
        let prompt: String
        let operation: String
        let attempt: Int
        let validResult: Bool
        let itemCount: Int?
        let notable: Bool
        let hasActionItems: Bool
        let summary: String
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let durationMS: Int?
        let observedToolCalls: [String: Int]
        let nativeToolCalls: [String: Int]
    }

    private struct Report: Codable {
        let revision: String
        let slug: String
        let engine: String
        let cliVersion: String?
        let model: String
        let mode: String
        let seededSince: String?
        let startedAt: Date
        let durationSeconds: Double
        let succeeded: Bool
        let errorKind: String?
        let storePath: String
        let checkpoint: Double?
        let readOrigin: String?
        let sourceScope: [String]?
        let receipts: [Receipt]
        let notes: [CycleNoteItem]
    }

    static func outputDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["LAB_OUTPUT_DIR"]
            ?? FileManager.default.temporaryDirectory.appending(path: "sentient-drive-review-\(UUID().uuidString)").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    static func exportPrompts() async {
        do {
            let output = try outputDirectory()
            let now = Date()
            let slug = ProcessInfo.processInfo.environment["LAB_SLUG"] ?? "google-drive"
            for backend in [ModelBackend.claude, .chatgpt] {
                for mode in [MCPSource.ReadMode.initial, .iterative] {
                    let windows = try MCPSource.windows(slug: slug, mode: mode,
                                                        since: now.addingTimeInterval(-86_400), now: now)
                    let prompt = MCPSource.prompt(slug: slug, name: ConnectorRegistry.displayName(slug: slug),
                                                  backend: backend, mode: mode, window: windows[0])
                    try prompt.write(to: output.appending(path: "\(backend.rawValue)-\(mode.rawValue).txt"),
                                     atomically: true, encoding: .utf8)
                }
            }
            Log("Full prompts exported: \(output.path)")
        } catch { Log("Prompt export failed: \(ErrorLabel(error))") }
    }

    static func read(slug explicitSlug: String? = nil) async {
        let env = ProcessInfo.processInfo.environment
        guard env["LAB_PROMPT"] == nil else {
            Log("REFUSED: kbread uses the production prompt builder; LAB_PROMPT is unsupported")
            return
        }
        guard let mode = MCPSource.ReadMode(rawValue: env["LAB_MODE"] ?? "iterative") else {
            Log("REFUSED: LAB_MODE must be initial or iterative")
            return
        }
        let slug = explicitSlug ?? env["LAB_SLUG"] ?? "google-drive"
        let backend = ModelBackend.current
        let modelName = env["LAB_CLAUDE_MODEL"]
        guard modelName == nil || (backend == .claude && ["haiku", "sonnet"].contains(modelName!)) else {
            Log("REFUSED: LAB_CLAUDE_MODEL is haiku or sonnet on the Claude engine only")
            exit(1)
        }
        let claudeModel: ClaudeCLI.Model? = modelName.map { $0 == "sonnet" ? .sonnet : .haiku }
        let started = Date()
        do {
            let output = try outputDirectory()
            let store: CycleStore
            let storePath: String
            if env["LAB_USE_LIVE_STORE"] == "1" {
                guard env["LAB_STORE_PATH"] == nil else {
                    Log("REFUSED: choose LAB_STORE_PATH or LAB_USE_LIVE_STORE, not both")
                    return
                }
                store = .shared
                storePath = URL.sentientSupport.appending(path: "IterativeCycle.store").path
            } else {
                let path = env["LAB_STORE_PATH"] ?? output.appending(path: "review.store").path
                let url = URL(fileURLWithPath: path)
                guard url.resolvingSymlinksInPath().standardizedFileURL != URL.sentientSupport.appending(path: "IterativeCycle.store").resolvingSymlinksInPath().standardizedFileURL else {
                    Log("REFUSED: the live store requires LAB_USE_LIVE_STORE=1")
                    return
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let schema = Schema([BucketPointer.self, CycleNote.self])
                let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
                store = CycleStore(modelContainer: container)
                storePath = url.path
            }
            let receipts = OSAllocatedUnfairLock(initialState: [Receipt]())
            let observer: MCPSource.ReceiptObserver = { envelope, outcome, attempt, usedPrompt, operation, nativeCalls in
                    if env["LAB_CAPTURE_RAW"] == "1", let envelope {
                        try? envelope.raw.write(to: output.appending(path: "trace-\(operation)-\(UUID().uuidString).jsonl"),
                                                atomically: true, encoding: .utf8)
                    }
                    receipts.withLock { $0.append(Receipt(prompt: usedPrompt, operation: operation, attempt: attempt,
                        validResult: outcome != nil || operation == "identity" || operation == "selection"
                            || (operation.hasPrefix("native_") && operation != "native_incomplete"),
                        itemCount: outcome?.itemCount, notable: outcome?.result != nil,
                        hasActionItems: outcome?.result?.hasActionItems ?? false,
                        summary: outcome?.result?.summary ?? "", inputTokens: envelope?.inputTokens,
                        cachedInputTokens: envelope?.cachedInputTokens, outputTokens: envelope?.outputTokens,
                        durationMS: envelope?.durationMS,
                        observedToolCalls: envelope.map { toolCounts($0.raw) } ?? [:], nativeToolCalls: nativeCalls)) }
            }
            if let since = env["LAB_SINCE"] {
                guard env["LAB_USE_LIVE_STORE"] != "1", mode == .iterative,
                      try await store.mcpCheckpoint(MCPSource.bucketKey(slug)) == nil else {
                    Log("REFUSED: LAB_SINCE only seeds a new isolated iterative review store")
                    exit(1)
                }
                let formatter = ISO8601DateFormatter()
                guard let date = formatter.date(from: since), date < started else {
                    Log("REFUSED: LAB_SINCE must be an earlier RFC3339 date")
                    exit(1)
                }
                let identity = try await MCPSource.readIdentity(slug: slug, onReceipt: observer)
                let origin = MCPSource.checkpointOrigin(slug: slug, backend: backend, fingerprint: identity,
                    fallback: ConnectorRegistry.readOrigin(slug: slug, backend: backend))
                let saved = await store.commitMCPRead(bucketKey: MCPSource.bucketKey(slug), notes: [],
                    through: ItemKey(order: date.timeIntervalSince1970, tiebreak: ""),
                    origin: origin, replaceNotes: false)
                guard saved == .saved else { throw MCPSource.MCPError.storageFailure }
            }
            let reader: MCPSource.Reader = { slug, prompt, mode, window in
                try await MCPSource.read(slug: slug, prompt: prompt, mode: mode, window: window, claudeModel: claudeModel, onReceipt: observer)
            }
            var succeeded = false
            var errorKind: String?
            do {
                let count = try await MCPSource.run(slug: slug, mode: mode, store: store, now: started,
                    reader: reader, identityReader: { try await MCPSource.readIdentity(slug: $0, onReceipt: observer) }) { event in
                        switch event {
                        case let .windowStart(step, total, label, _): Log("Window \(step)/\(total) reading: \(label)")
                        case let .windowDone(step, total, _, _, items, kept):
                            Log("Window \(step)/\(total) saved: considered=\(items), kept=\(kept)")
                        case let .failed(_, message): Log("Read failed: \(message)")
                        }
                    }
                succeeded = true
                Log("kbread: saved \(count) summary(ies)")
            } catch {
                errorKind = String(describing: type(of: error))
                Log("kbread failed: \(ErrorLabel(error))")
            }
            let notes = await store.notes().filter { $0.bucketKey == MCPSource.bucketKey(slug) }
            let checkpoint = try await store.mcpCheckpoint(MCPSource.bucketKey(slug))
            let version = backend == .claude ? await ClaudeCLI.installedVersion() : await CodexCLI.installedVersion()
            let report = Report(revision: MCPSource.promptRevision(slug: slug), slug: slug, engine: backend.rawValue,
                cliVersion: version, model: backend == .claude ? (modelName ?? (GranolaSource.isGranola(slug)
                    ? GranolaSource.defaultClaudeModel.rawValue : (["google-drive", "slack", OutlookMailConnector.slug, OutlookCalendarConnector.slug].contains(slug) ? "sonnet" : "haiku"))) : "gpt-6-luna",
                mode: mode.rawValue, seededSince: env["LAB_SINCE"], startedAt: started,
                durationSeconds: Date().timeIntervalSince(started), succeeded: succeeded, errorKind: errorKind,
                storePath: storePath, checkpoint: checkpoint?.mark.order, readOrigin: checkpoint?.origin,
                sourceScope: GranolaSource.curationNoteIDs?.sorted(),
                receipts: receipts.withLock { $0 }, notes: notes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: output.appending(path: "report.json"), options: .atomic)
            let current = report.receipts.filter { $0.validResult && $0.notable }.map(\.summary).joined(separator: "\n\n")
            let review = !succeeded ? "The read did not complete successfully. Existing stored summaries were preserved. See report.json.\n"
                : (current.isEmpty ? "This read succeeded and found no new summary to retain.\n" : current)
            try review
                .write(to: output.appending(path: "summaries.md"), atomically: true, encoding: .utf8)
            let stored = notes.map { "**\($0.title ?? "Summary")**\n\n\($0.text)" }.joined(separator: "\n\n")
            try stored.write(to: output.appending(path: "stored-summaries.md"), atomically: true, encoding: .utf8)
            for (i, receipt) in receipts.withLock({ $0 }).enumerated() {
                try receipt.prompt.write(to: output.appending(path: "prompt-\(i + 1).txt"), atomically: true, encoding: .utf8)
            }
            Log("Full accepted summaries and run evidence: \(output.path)")
            if !succeeded { exit(1) }
        } catch { Log("Read audit failed: \(ErrorLabel(error))"); exit(1) }
    }

    /// Counts only. Missing trace events remain missing evidence, not proof no calls occurred.
    static func toolCounts(_ raw: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if event["type"] as? String == "item.completed",
               let item = event["item"] as? [String: Any], item["type"] as? String == "mcp_tool_call",
               let name = item["tool"] as? String { counts[name, default: 0] += 1 }
            if event["type"] as? String == "assistant",
               let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "tool_use" {
                    if let name = block["name"] as? String { counts[name, default: 0] += 1 }
                }
            }
        }
        return counts
    }
}

#endif
