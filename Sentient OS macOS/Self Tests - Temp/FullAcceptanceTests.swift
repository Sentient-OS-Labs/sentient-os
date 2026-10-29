#if DEBUG
// FullAcceptanceTests.swift
// Temporary acceptance checks using the real cycle and vault with isolated preferences,
// an isolated store and a scratch vault. Refuses the production bundle identity.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import Foundation
import SwiftData
import os

enum FullAcceptanceTests {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        Log("\(condition ? "PASS" : "FAIL") acceptance: \(message)")
        if !condition { throw Failure(message: message) }
    }
    static func envelope(_ result: String = "OK", raw: String = "") -> CodexCLI.Envelope {
        .init(result: result, sessionID: "synthetic", numTurns: 1, durationMS: 1,
              inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, raw: raw)
    }
    static func googleReadPolicyFixtures() async throws {
        for backend in [ModelBackend.chatgpt, .claude] {
            try await ModelBackend.$runOverride.withValue(backend) {
                for slug in ["gmail", "google-calendar"] {
                    let key = slug == "gmail" ? "thread_count" : "event_count"
                    let quiet = "{\"\(key)\":0,\"notable\":false,\"has_action_items\":false,\"summary\":\"\",\"tool_failure\":\"\"}"
                    let notable = "{\"\(key)\":1,\"notable\":true,\"has_action_items\":false,\"summary\":\"A completed synthetic source summary.\",\"tool_failure\":\"\"}"
                    let abovePromptCap = notable.replacingOccurrences(of: "\"\(key)\":1", with: "\"\(key)\":301")
                    let tool = backend == .claude
                        ? (slug == "gmail" ? "mcp__claude_ai_Gmail__search_threads" : "mcp__claude_ai_Google_Calendar__list_events")
                        : (slug == "gmail" ? "gmail.search_emails" : "google_calendar.search_events")
                    func receipt(_ id: String, failed: Bool, query: String) throws -> String {
                        let args = ["query": query]
                        let payload = failed ? #"{"error":{"status":401,"message":"authentication required"}}"# : #"{"items":[]}"#
                        let events: [[String: Any]]
                        if backend == .claude {
                            events = [
                                ["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": tool, "input": args]]]],
                                ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": failed, "content": payload]]]]]
                        } else {
                            events = [["type": "item.completed", "item": ["type": "mcp_tool_call", "id": id,
                                "server": "codex_apps", "tool": tool, "status": failed ? "failed" : "completed",
                                "arguments": args, "result": ["content": [["type": "text", "text": payload]]]]]]
                        }
                        return try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
                    }
                    let failed = try receipt("old-failure", failed: true, query: "original query")
                    let replacement = try receipt("replacement", failed: false, query: "adapted query with different arguments")
                    for (label, raw) in [("without native receipts", ""), ("with changed discovery arguments", replacement),
                                         ("after a historical failure and different replacement call", failed + "\n" + replacement)] {
                        for (result, expectedCount) in [(quiet, 0), (notable, 1), (abovePromptCap, 301)] {
                            let calls = OSAllocatedUnfairLock(initialState: 0)
                            var invocation = CodexCLI.Invocation(prompt: "Read the selected source's requested window")
                            invocation.mcpReadConnectors = [slug]
                            invocation.sandbox = .readOnly
                            let request = invocation
                            let summary = try await FrontierRun.$acceptanceRun.withValue({ request in
                                try require(request.connectorOnlyRead && !request.webSearch && request.mcpActionServer == nil,
                                            "\(slug) remains a read-only source request")
                                calls.withLock { $0 += 1 }
                                return envelope(result, raw: raw)
                            }) { try await GoogleSourceRead.read(request, slug: slug, countKey: key) }
                            try require((summary?.count ?? 0) == expectedCount && calls.withLock({ $0 }) == 1,
                                        "\(backend.rawValue) \(slug) completed \(expectedCount == 0 ? "quiet" : "notable") output accepted \(label)")
                        }
                    }
                    for failure in ["auth", "other"] {
                        let result = quiet.replacingOccurrences(of: #""tool_failure":"""#, with: "\"tool_failure\":\"\(failure)\"")
                        var refused = false
                        do {
                            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in envelope(result) }) {
                                try await GoogleSourceRead.read(.init(prompt: "Synthetic source"), slug: slug, countKey: key)
                            }
                        } catch MCPSource.MCPError.connectorAuth { refused = failure == "auth" }
                        catch MCPSource.MCPError.toolFailure { refused = failure == "other" }
                        try require(refused, "\(backend.rawValue) \(slug) explicit \(failure) remains an error without receipts")
                    }
                    for malformed in ["{}", "not JSON", notable.replacingOccurrences(of: "\"\(key)\":1", with: "\"\(key)\":-1"),
                                      notable.replacingOccurrences(of: #""tool_failure":"""#, with: #""tool_failure":"unexpected""#),
                                      notable.replacingOccurrences(of: #""tool_failure":"""#, with: #""tool_failure":42"#)] {
                        var refused = false
                        do {
                            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in envelope(malformed) }) {
                                try await GoogleSourceRead.read(.init(prompt: "Synthetic source"), slug: slug, countKey: key)
                            }
                        } catch GoogleSourceRead.Failure.invalidResponse { refused = true }
                        try require(refused, "\(backend.rawValue) \(slug) malformed source output remains an error")
                    }
                }
            }
        }
    }
    @MainActor static func googleAudit() async {
        do {
            let schema = Schema([BucketPointer.self, CycleNote.self])
            let store = CycleStore(modelContainer: try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
            try await CycleStore.$acceptanceStore.withValue(store) { try await googleSource(store: store) }
            Log("GOOGLE AUDIT: PASS (isolated store)")
        } catch { Log("GOOGLE AUDIT: FAIL \(String(describing: type(of: error)))"); exit(1) }
    }

    @MainActor private static func googleSource(store: CycleStore) async throws {
        let env = ProcessInfo.processInfo.environment
        let slug = env["LAB_SLUG"] ?? "gmail"
        guard ["gmail", "calendar"].contains(slug) else { throw Failure(message: "unsupported Google source") }
        let output = try ConnectorReadAudit.outputDirectory()
        let capture: @Sendable (CodexCLI.Invocation) async throws -> CodexCLI.Envelope = { invocation in
            let result = try await FrontierRun.$acceptanceRun.withValue(nil) { try await FrontierRun.run(invocation) }
            try result.raw.write(to: output.appending(path: "trace-\(UUID().uuidString).jsonl"), atomically: true, encoding: .utf8)
            return result
        }
        if env["LAB_GOOGLE_ITERATIVE_ONLY"] == "1" {
            let since = Date().addingTimeInterval(-86_400)
            try await GoogleSourceRead.commit(bucket: slug, notes: [], through: since, origin: GoogleSourceRead.origin(bucket: slug))
            let count = try await FrontierRun.$acceptanceRun.withValue(capture) {
                slug == "gmail" ? try await GmailConnect.runIterative() : try await CalendarConnect.runIterative()
            }
            try require((await store.pointer(slug))?.order ?? 0 > since.timeIntervalSince1970,
                        "bounded Google incremental read advances its isolated checkpoint")
            try JSONEncoder().encode(await store.notes()).write(to: output.appending(path: "google-notes.json"))
            Log("Google source \(slug): bounded incremental=\(count)")
            return
        }
        let initial = try await FrontierRun.$acceptanceRun.withValue(capture) {
            slug == "gmail" ? try await GmailConnect.runInitial() : try await CalendarConnect.runInitial()
        }
        let mark = await store.pointer(slug)
        try require(mark != nil, "Google initial read saves checkpoint")
        let incremental = try await FrontierRun.$acceptanceRun.withValue(capture) {
            slug == "gmail" ? try await GmailConnect.runIterative() : try await CalendarConnect.runIterative()
        }
        try require(await store.pointer(slug) != nil, "Google incremental read preserves checkpoint")
        try JSONEncoder().encode(await store.notes()).write(to: output.appending(path: "google-notes.json"))
        Log("Google source \(slug): initial=\(initial), incremental=\(incremental)")
    }

    @MainActor static func run() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard Bundle.main.bundleIdentifier == "ai.sentientos.acceptance",
                  let path = env["SENTIENT_VAULT_ROOT"], path.hasPrefix("/private/tmp/sentient-acceptance/"),
                  let mode = env["ACCEPTANCE_MODE"] else { throw Failure(message: "isolated test app and vault required") }
            let schema = Schema([BucketPointer.self, CycleNote.self])
            let store = CycleStore(modelContainer: try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
            let defaults = UserDefaults.standard
            defaults.removePersistentDomain(forName: "ai.sentientos.acceptance")
            defaults.set(false, forKey: "dbg.gmail.connected")
            defaults.set(false, forKey: "dbg.calendar.connected")
            defaults.set(false, forKey: "mcp.outlook-calendar.kb")
            let root = VaultGenerator.vaultRoot
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await CycleStore.$acceptanceStore.withValue(store) {
                if mode == "editor-busy" {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try "# Existing knowledge\nUntouched fixture.\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
                    let original = VaultGenerator.vaultFingerprint(root)
                    let note = NoteDraft(kind: .file, sourceID: "file:/fixture.md", folder: "Fixture", itemDate: Date(),
                        text: "The user has a new synthetic project deadline.", title: "Pending fact", reminderFlagged: false)
                    _ = await store.advance(bucketKey: "fixture", note: note, to: ItemKey(order: 42, tiebreak: "fixture"))
                    defaults.set(true, forKey: CodexAuth.kbOnlyKey)
                    GiftLetter.saveLatest("Existing synthetic gift")
                    VaultActivity.shared.editorBusy = true
                    defer { VaultActivity.shared.editorBusy = false }
                    let outcome = await ProactiveCycle.shared.run { _ in }
                    try require(VaultGenerator.vaultFingerprint(root) == original, "busy editor leaves vault untouched")
                    try require(await store.notes().count == 1, "busy editor preserves pending summary for retry")
                    try require(outcome?.stage == .vault, "deferred update does not report a successful cycle")
                } else if mode == "mirror" {
                    try await MirrorAcceptanceTests.run()
                } else if mode == "command-lock" {
                    let coordinator = CommandCoordinator()
                    var stopped = 0
                    try require(coordinator.beginExternalRun(caption: "Synthetic first task") { stopped += 1 }, "first card acquires shared task lock")
                    try require(!coordinator.beginExternalRun(caption: "Synthetic second task") {}, "second card cannot overlap active task")
                    coordinator.stop()
                    try require(stopped == 1, "STOP reaches the adopted task")
                    try require(coordinator.run.isRunning, "lock remains held until cancelled task unwinds")
                    coordinator.run.completeExternal(.stopped, line: "Stopped")
                    try require(!coordinator.run.isRunning, "completion releases shared task lock")
                    coordinator.run.completeExternal(.success, line: "Late duplicate completion")
                    try require(!coordinator.run.isRunning, "late duplicate completion does not restart a task")
                    try require(coordinator.beginExternalRun(caption: "Synthetic next task") {}, "next task can acquire released lock")
                    coordinator.run.completeExternal(.success, line: "Finished")
                } else if mode == "local-ingestion" {
                    guard let model = ModelLocator.resolve() else { throw Failure(message: "local model missing") }
                    let input = root.deletingLastPathComponent().appending(path: "Local Notes")
                    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
                    for (name, text) in [
                        ("Project.md", "I maintain a project called Cedar Atlas, a catalog of public-domain botanical drawings. I work on it every Saturday and prefer writing its documentation in Markdown."),
                        ("Promotion.txt", "FLASH SALE. Click now for 30 percent off generic office supplies. Unsubscribe from marketing at any time."),
                        ("Private.txt", "My private payment card number is 4242 4242 4242 4242, expiry 09/29 and security code 123. Keep this credential private.")
                    ] { try text.write(to: input.appending(path: name), atomically: true, encoding: .utf8) }
                    let connector = FilesConnector(roots: [.custom(input)])
                    let first = await IterativeRun(modelPath: model, store: store).run([connector], mode: .auto)
                    try require(first.done == 3 && first.failed == 0 && first.parseFailures == 0, "real on-device pipeline processes every fixture")
                    try require(first.survivors >= 1 && first.sensitive >= 1 && first.junk >= 1, "local model separates useful, sensitive and promotional material")
                    let notes = await store.notes()
                    try require(!notes.contains { $0.text.contains("4242") }, "sensitive fixture leaves no stored summary")
                    let second = await IterativeRun(modelPath: model, store: store).run([connector], mode: .auto)
                    try require((await store.notes()).count == notes.count && second.done == 0, "unchanged local files are not processed twice")
                    try "I completed the Cedar Atlas import milestone and will focus next on keyboard navigation.".write(to: input.appending(path: "New milestone.md"), atomically: true, encoding: .utf8)
                    let third = await IterativeRun(modelPath: model, store: store).run([connector], mode: .auto)
                    try require(third.done == 1 && third.survivors == 1, "new local file advances iterative ingestion once")
                } else if mode == "google-malformed" {
                    try await googleReadPolicyFixtures()
                    let sensitive = try GoogleSourceRead.parse(#"{"thread_count":1,"notable":true,"has_action_items":false,"summary":"The user's private card is 4242 4242 4242 4242."}"#, countKey: "thread_count")
                    try require(sensitive == nil, "Google summary backstop discards high-risk identifiers")
                    var failures = 0
                    for slug in ["gmail", "calendar"] {
                        let before = ItemKey(order: 42, tiebreak: "fixture")
                        _ = await store.advance(bucketKey: slug, note: NoteDraft(kind: .file, sourceID: "fixture",
                            folder: "Fixture", itemDate: Date(), text: "Pending fixture", title: nil, reminderFlagged: false), to: before)
                        var refused = false
                        do {
                            _ = try await FrontierRun.$acceptanceRun.withValue({ _ in envelope("{}") }) {
                                if slug == "gmail" { return try await GmailConnect.runIterative() }
                                return try await CalendarConnect.runIterative()
                            }
                        } catch { refused = true }
                        let unchanged = await store.pointer(slug) == before
                        Log("\(refused && unchanged ? "PASS" : "FAIL") \(slug) malformed output: refused=\(refused), checkpointPreserved=\(unchanged)")
                        if !refused || !unchanged { failures += 1 }
                    }
                    try require(failures == 0, "Google source malformed responses never advance checkpoints")
                    for slug in ["gmail", "calendar"] {
                        let before = await store.pointer(slug)
                        let key = slug == "gmail" ? "thread_count" : "event_count"
                        let valid = "{\"\(key)\":1,\"notable\":true,\"has_action_items\":false,\"summary\":\"The user maintains a synthetic project.\",\"tool_failure\":\"\"}"
                        let quiet = "{\"\(key)\":0,\"notable\":false,\"has_action_items\":false,\"summary\":\"\",\"tool_failure\":\"\"}"
                        var refused = false
                        let originalNotes = Set(await store.notes().filter { $0.bucketKey == slug }.map(\.sourceID))
                        for failure in ["auth", "other"] {
                            let result = quiet.replacingOccurrences(of: #""tool_failure":"""#, with: "\"tool_failure\":\"\(failure)\"")
                            refused = false
                            do {
                                _ = try await FrontierRun.$acceptanceRun.withValue({ _ in envelope(result) }) {
                                    if slug == "gmail" { return try await GmailConnect.runIterative() }
                                    return try await CalendarConnect.runIterative()
                                }
                            } catch { refused = true }
                            try require((await store.pointer(slug)) == before && refused,
                                        "\(slug) explicit \(failure) cannot advance its checkpoint")
                            try require(Set(await store.notes().filter { $0.bucketKey == slug }.map(\.sourceID)) == originalNotes,
                                        "\(slug) explicit \(failure) preserves pending summaries")
                        }
                        // Start the explicit-refresh fixture independently of the preceding
                        // malformed automatic backfill. Gmail retries now resume their plan.
                        if slug == "gmail", let before {
                            _ = await store.commitMCPRead(bucketKey: slug, notes: [], through: before,
                                origin: GoogleSourceRead.origin(bucket: slug), replaceNotes: false)
                        }
                        let calls = OSAllocatedUnfairLock(initialState: 0)
                        refused = false
                        do {
                            _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in
                                let n = calls.withLock { $0 += 1; return $0 }
                                if n == 3 { throw CancellationError() }
                                return envelope(valid)
                            }) {
                                if slug == "gmail" { return try await GmailConnect.runInitial() }
                                return try await CalendarConnect.runInitial()
                            }
                        } catch { refused = true }
                        try require((await store.pointer(slug)) == before && refused, "\(slug) failed initial retains old checkpoint")
                        let partialNotes = await store.notes().filter { $0.bucketKey == slug }
                        try require(slug == "gmail" ? partialNotes.count > 1 : partialNotes.count == 1,
                                    "\(slug) interrupted initial retains the appropriate committed summaries")
                        await store.failNextMCPCommitForTesting()
                        refused = false
                        do {
                            _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in envelope(valid) }) {
                                if slug == "gmail" { return try await GmailConnect.runIterative() }
                                return try await CalendarConnect.runIterative()
                            }
                        } catch { refused = true }
                        try require((await store.pointer(slug)) == before && refused, "\(slug) failed save retains checkpoint")
                        try require(Set(await store.notes().filter { $0.bucketKey == slug }.map(\.sourceID)) == Set(partialNotes.map(\.sourceID)),
                                    "\(slug) failed save rolls only its uncommitted window back")
                        _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in envelope(valid) }) {
                            if slug == "gmail" { return try await GmailConnect.runInitial() }
                            return try await CalendarConnect.runInitial()
                        }
                        let count = await store.notes().filter { $0.bucketKey == slug }.count
                        try require(count == (slug == "gmail" ? 4 : 12), "\(slug) completed first analysis saves summaries without native receipts")
                        let quietBefore = ItemKey(order: Date().addingTimeInterval(-3600).timeIntervalSince1970, tiebreak: "")
                        _ = await store.commitMCPRead(bucketKey: slug, notes: [], through: quietBefore,
                            origin: GoogleSourceRead.origin(bucket: slug), replaceNotes: false)
                        let quietCalls = OSAllocatedUnfairLock(initialState: 0)
                        _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
                            quietCalls.withLock { $0 += 1 }
                            return envelope(quiet)
                        }) {
                            if slug == "gmail" { return try await GmailConnect.runIterative() }
                            return try await CalendarConnect.runIterative()
                        }
                        let quietAfter = await store.pointer(slug)
                        try require(quietCalls.withLock({ $0 }) > 0 && (quietAfter?.order ?? 0) > quietBefore.order,
                                    "\(slug) completed quiet output advances without native receipts")
                        try require(await store.notes().filter { $0.bucketKey == slug }.count == count, "\(slug) completed quiet read preserves pending notes")
                        _ = await store.commitMCPRead(bucketKey: slug, notes: [], through: ItemKey(order: 42, tiebreak: "fixture"), origin: "previous-engine", replaceNotes: false)
                        let backfillCalls = OSAllocatedUnfairLock(initialState: 0)
                        _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in
                            backfillCalls.withLock { $0 += 1 }
                            return envelope(quiet)
                        }) {
                            if slug == "gmail" { return try await GmailConnect.runIterative() }
                            return try await CalendarConnect.runIterative()
                        }
                        try require(backfillCalls.withLock { $0 } == (slug == "gmail" ? 4 : 12), "\(slug) changed provenance triggers initial coverage")
                        try require(await store.notes().filter { $0.bucketKey == slug }.count == count, "\(slug) provenance backfill preserves pending summaries")
                        let future = ItemKey(order: Date().addingTimeInterval(3600).timeIntervalSince1970, tiebreak: "")
                        _ = await store.commitMCPRead(bucketKey: slug, notes: [], through: future,
                            origin: GoogleSourceRead.origin(bucket: slug), replaceNotes: false)
                        var clockRejected = false
                        do {
                            if slug == "gmail" { _ = try await GmailConnect.runIterative() }
                            else { _ = try await CalendarConnect.runIterative() }
                        } catch MCPSource.MCPError.clockMovedBackwards { clockRejected = true }
                        try require((await store.pointer(slug)) == future && clockRejected, "\(slug) clock rollback preserves its checkpoint")
                        if slug == "gmail" {
                            let retryCalls = OSAllocatedUnfairLock(initialState: 0)
                            try await Diagnostics.withOperation("processing") {
                                let processing = Diagnostics.current!
                                let kept = try await FrontierRun.$acceptanceRun.withValue({ invocation in
                                    try await Diagnostics.withOperation("frontier_run") {
                                        try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
                                            if retryCalls.withLock({ $0 += 1; return $0 }) == 1 {
                                                throw CodexCLI.CLIError.timedOut(after: 1)
                                            }
                                            return envelope(valid)
                                        }
                                    }
                                }) { try await GmailConnect.runInitial() }
                                try require(kept == 4 && retryCalls.withLock { $0 } == 5,
                                            "Gmail recovers one typed runtime timeout and saves all four windows")
                                try require(!processing.hasFailure,
                                            "recovered Gmail timeout cannot mark its processing parent failed")
                            }
                            let exhaustedCalls = OSAllocatedUnfairLock(initialState: 0)
                            try await Diagnostics.withOperation("processing") {
                                let processing = Diagnostics.current!
                                var rejected = false
                                do {
                                    _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
                                        try await Diagnostics.withOperation("frontier_run") {
                                            try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
                                                exhaustedCalls.withLock { $0 += 1 }
                                                throw CodexCLI.CLIError.timedOut(after: 1)
                                            }
                                        }
                                    }) { try await GmailConnect.runInitial() }
                                } catch GmailConnect.GmailError.incomplete {
                                    rejected = true
                                }
                                try require(rejected && exhaustedCalls.withLock { $0 } == 8,
                                            "Gmail exhausts exactly one runtime-timeout retry per window")
                                try require(processing.hasFailure,
                                            "exhausted Gmail retries still mark their processing parent failed")
                            }
                        }
                    }
                } else if mode == "google-source" {
                    try await googleSource(store: store)
                } else if mode == "vault-faults" {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let readme = root.appending(path: "README.md")
                    try "# Original fixture\n".write(to: readme, atomically: true, encoding: .utf8)
                    let note = CloudNote(kind: .file, sourceID: "fixture", folder: "Fixture", title: "Fixture", text: "A synthetic fact.", itemDate: Date())
                    let original = VaultGenerator.vaultFingerprint(root)
                    var rejected = false
                    do { _ = try await FrontierRun.$acceptanceRun.withValue({ _ in envelope() }) { try await VaultCloud().create(notes: [note]) } }
                    catch { rejected = true }
                    try require(rejected && VaultGenerator.vaultFingerprint(root) == original, "empty creation cannot replace existing knowledge")
                    rejected = false
                    do {
                        _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in
                            try "Unfinished".write(to: URL(fileURLWithPath: invocation.cwd!).appending(path: "Partial.md"), atomically: true, encoding: .utf8)
                            throw CancellationError()
                        }) { try await VaultCloud().update(notes: [note]) }
                    } catch { rejected = true }
                    try require(rejected && VaultGenerator.vaultFingerprint(root) == original, "cancelled update leaves live knowledge untouched")
                    let late = Task {
                        try await FrontierRun.$acceptanceRun.withValue({ invocation in
                            try "# Should never be committed\n".write(to: URL(fileURLWithPath: invocation.cwd!).appending(path: "Late.md"), atomically: true, encoding: .utf8)
                            withUnsafeCurrentTask { $0?.cancel() }
                            return envelope()
                        }) { try await VaultCloud().update(notes: [note]) }
                    }
                    rejected = false
                    do { _ = try await late.value } catch is CancellationError { rejected = true }
                    try require(rejected && VaultGenerator.vaultFingerprint(root) == original, "late cancellation is checked before atomic swap")
                    rejected = false
                    do {
                        _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
                            try "# User edit retained\n".write(to: readme, atomically: true, encoding: .utf8)
                            return envelope()
                        }) { try await VaultCloud().update(notes: [note]) }
                    } catch VaultCloud.CloudError.vaultChanged { rejected = true }
                    try require(rejected && (try String(contentsOf: readme, encoding: .utf8)).contains("User edit retained"), "concurrent edit rejects stale update with a retryable failure")
                    let edited = VaultGenerator.vaultFingerprint(root)
                    rejected = false
                    do {
                        _ = try await FrontierRun.$acceptanceRun.withValue({ _ in
                            throw CodexCLI.CLIError.usageLimit(message: "Synthetic limit", sessionID: "synthetic-resume")
                        }) { try await VaultCloud().update(notes: [note]) }
                    } catch VaultCloud.CloudError.usageLimit { rejected = true }
                    try require(rejected && VaultGenerator.vaultFingerprint(root) == edited, "usage limit preserves live knowledge")
                    try require(defaults.data(forKey: "vault.update.resume") != nil, "usage limit persists resumable staging")
                    _ = try await FrontierRun.$acceptanceRun.withValue({ invocation in
                        guard invocation.resumeSessionID == "synthetic-resume" else { throw Failure(message: "resume session missing") }
                        try "# Resumed fixture\n".write(to: URL(fileURLWithPath: invocation.cwd!).appending(path: "Resumed.md"), atomically: true, encoding: .utf8)
                        return envelope()
                    }) { try await VaultCloud().update(notes: [note]) }
                    try require(FileManager.default.fileExists(atPath: root.appending(path: "Resumed.md").path), "new vault actor resumes staged update")
                    try require(defaults.data(forKey: "vault.update.resume") == nil, "successful resume removes saved handle")
                    let parts = CorpusSlicer.slice(Array(repeating: note, count: 10), budget: 250)
                    try require(parts.count > 1 && parts.flatMap { $0 }.count == 10, "corpus batching preserves every entry")
                } else if mode == "vault-cycle" {
                    defaults.set(false, forKey: CodexAuth.kbOnlyKey)
                    let notes = [
                        "The user maintains a fictional project called Cedar Atlas. Its purpose is cataloguing public-domain botanical drawings. The project's release checklist is the user's own responsibility.",
                        "The user writes documentation in Markdown, prefers concise factual summaries and plans each project in weekly milestones.",
                        "The Cedar Atlas prototype has passed its import checks. The user explicitly committed to completing its accessibility checklist tomorrow; this commitment remains unresolved.",
                        "An external contributor proposed adding audio descriptions to Cedar Atlas. The user has not agreed to implement the proposal."
                    ]
                    for (index, text) in notes.enumerated() {
                        _ = await store.advance(bucketKey: "fixture", note: NoteDraft(kind: .file,
                            sourceID: "file:/fixture-\(index).md", folder: "User notes", itemDate: Date(),
                            text: text, title: "Cedar Atlas \(index)", reminderFlagged: index == 2),
                            to: ItemKey(order: Double(index), tiebreak: "fixture"))
                    }
                    let failure = await FrontierRun.$acceptanceRun.withValue({ invocation in
                        var isolated = invocation
                        isolated.mcpReadConnectors = []
                        isolated.includeUserConfig = false
                        return try await FrontierRun.$acceptanceRun.withValue(nil) { try await FrontierRun.run(isolated) }
                    }) {
                        await ProactiveCycle.shared.run { phase in Log("Acceptance cycle phase: \(phase)") }
                    }
                    try require(failure == nil, "full creation, welcome and proactive cycle succeeds")
                    try require(await store.notes().isEmpty, "successful cycle consumes its input summaries")
                    try require(await store.pointer("fixture") != nil, "successful cycle retains ingestion checkpoint")
                    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
                    let markdown = files.filter { $0.pathExtension == "md" }
                    try require(!markdown.isEmpty, "creation writes real Markdown knowledge")
                    try require(GiftLetter.latest() != nil, "welcome letter produced")
                    let result = ProactiveResearch.latest()
                    try require(result != nil && (result?.ready.count ?? 99) <= 5, "proactive deck is bounded and persisted in test preferences")
                    let before = VaultGenerator.vaultFingerprint(root)
                    let update = CloudNote(kind: .file, sourceID: "file:/fixture-update.md", folder: "User notes",
                        title: "Cedar Atlas milestone completed", text: "The user completed the Cedar Atlas accessibility checklist today. It is no longer an unresolved commitment. The new internal version codename is Maple Comet.", itemDate: Date())
                    try require(try await VaultCloud.shared.update(notes: [update]) == 1, "incremental vault update consumes new summary")
                    try require(VaultGenerator.vaultFingerprint(root) != before, "incremental update changes vault")
                    let updated = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
                    let corpus = updated.filter { $0.pathExtension == "md" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
                    try require(corpus.localizedCaseInsensitiveContains("Maple Comet"), "new supported fact reaches updated knowledge")
                    try require(!FileManager.default.fileExists(atPath: root.appending(path: ".sentient-corpus.json").path), "staging corpus does not enter final vault")
                } else { throw Failure(message: "unknown mode") }
            }
            Log("FULL ACCEPTANCE: PASS")
        } catch {
            Log("FULL ACCEPTANCE: FAIL \(String(describing: type(of: error)))")
            if let error = error as? Failure { Log(error.message) }
            exit(1)
        }
    }
}
#endif
