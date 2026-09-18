#if DEBUG
//
// ConnectorCurationTests.swift
// Exercises strict read outcomes, real SwiftData transactions, origin backfills, prompt
// variants, classification validation and connector status handling using isolated fixtures.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation
import SwiftData
import os

enum ConnectorCurationTests {
    @MainActor static func run() async {
        await ModelBackend.$runOverride.withValue(.chatgpt) { await checks() }
    }

    @MainActor private static func checks() async {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            Log("\(condition ? "PASS" : "FAIL")  \(message)")
            if !condition { failures += 1 }
        }
        let inventoryPrefix = "mcp__claude_ai_Fixture__"
        let inventoryNames = [inventoryPrefix + "read_item", inventoryPrefix + "create_item"]
        func inventory(_ status: String = "connected", tools: [String]? = nil, server: String = "claude.ai Fixture") -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: [
                "type": "system", "subtype": "init", "mcp_servers": [["name": server, "status": status]],
                "tools": tools ?? (inventoryNames + ["StructuredOutput", "WaitForMcpServers", "mcp__Other__read"])
            ]), as: UTF8.self)
        }
        func observed(_ raw: String) -> [String]? {
            ConnectorClassifier.nativeInventory(raw: raw, prefix: inventoryPrefix, serverName: "claude.ai Fixture")
        }
        check(observed(inventory()) == inventoryNames.sorted(), "native connected inventory excludes other namespaces and builtins")
        check(observed(inventory("pending")) == nil, "pending server cannot certify native inventory")
        check(observed(inventory(server: "claude.ai Other")) == nil, "wrong server cannot certify native inventory")
        check(observed(inventory(tools: [])) == nil, "empty native tool surface is not complete")
        check(observed(inventory(tools: inventoryNames + [inventoryNames[0]])) == nil, "duplicate native names are rejected")
        check(observed(inventory(tools: [inventoryPrefix + "bad name"])) == nil, "malformed native names are rejected")
        let modelOnly = #"{"type":"result","structured_output":{"tools":["mcp__claude_ai_Fixture__read_item"]}}"#
        check(observed(modelOnly) == nil, "model-produced inventory cannot replace native evidence")
        check(observed(inventory() + "\n" + modelOnly) == inventoryNames.sorted(), "model omission cannot shrink native inventory")

        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let slug = "google-drive"
        var fixture = saved
        fixture["mcp.connectors.chatgpt"] = try! JSONEncoder().encode([
            ConnectorCensus.DetectedConnector(slug: slug, displayName: "Google Drive", origin: .chatgpt,
                serverURL: nil, catalogID: "connector_5f3c8c41a1e54ad7a76272c89e2554fa", iconPath: nil,
                healthy: true, lastSeen: Date())])
        fixture["mcp.connectors.claude"] = try! JSONEncoder().encode([
            ConnectorCensus.DetectedConnector(slug: "asana", displayName: "Asana", origin: .claude,
                serverURL: "https://mcp.asana.com/v2/mcp", catalogID: nil, iconPath: nil, healthy: true, lastSeen: Date()),
            ConnectorCensus.DetectedConnector(slug: "linear", displayName: "Linear", origin: .claude,
                serverURL: "https://mcp.linear.app/mcp", catalogID: nil, iconPath: nil, healthy: true, lastSeen: Date())])
        fixture[ConnectorRegistry.readGenerationKey(slug, "chatgpt")] = 0
        fixture[ConnectorRegistry.readGenerationKey(slug, "claude")] = 0
        defaults.setVolatileDomain(fixture, forName: UserDefaults.argumentDomain)

        let good = #"{"item_count":1,"notable":true,"has_action_items":true,"summary":"The user has a confirmed project deadline.\n\nACTION ITEMS\nFinish the agreed draft.","tool_failure":""}"#
        let quiet = #"{"item_count":3,"notable":false,"has_action_items":false,"summary":"","tool_failure":""}"#
        func refuses(_ json: String) -> Bool {
            do { _ = try MCPSource.parse(json, slug: slug); return false } catch { return true }
        }
        do {
            check(try MCPSource.parse(good, slug: slug).result?.hasActionItems == true, "notable result preserves action items")
            check(try MCPSource.parse(quiet, slug: slug) == .quiet(itemCount: 3), "valid quiet result keeps its considered count")
            check(try MCPSource.parse("```json\n" + good + "\n```", slug: slug).result != nil, "fenced valid JSON remains compatible")
            check(refuses(good.replacingOccurrences(of: "ACTION ITEMS", with: "BACKGROUND")), "action flag requires its actual section")
            check(refuses(good.replacingOccurrences(of: "The user", with: "You")), "Drive summary cannot address the reader")
            check(refuses(good.replacingOccurrences(of: "confirmed project", with: "$500K project")), "Drive summary rejects an exact currency amount")
            check(try MCPSource.parse(good.replacingOccurrences(of: "deadline", with: "deadline September 8—10"), slug: slug)
                .result?.summary.contains("September 8-10") == true, "typography normalization preserves a date range without another read")
            for bad in ["", "not json", "{}", good.replacingOccurrences(of: "\"item_count\":1,", with: ""),
                        good.replacingOccurrences(of: "\"item_count\":1", with: "\"item_count\":-1"),
                        good.replacingOccurrences(of: "\"notable\":true", with: "\"notable\":1"),
                        good.replacingOccurrences(of: "\"item_count\":1", with: "\"item_count\":1.5"),
                        quiet.replacingOccurrences(of: "\"has_action_items\":false", with: "\"has_action_items\":true"),
                        quiet.replacingOccurrences(of: "\"notable\":false", with: "\"notable\":true"),
                        quiet.replacingOccurrences(of: "\"summary\":\"\"", with: "\"summary\":\"filler\""),
                        quiet.replacingOccurrences(of: "\"tool_failure\":\"\"", with: "\"tool_failure\":\"unknown\"") ] {
                check(refuses(bad), "invalid or inconsistent response refuses the read")
            }
            for health in ["auth", "other"] {
                check(refuses(quiet.replacingOccurrences(of: "\"tool_failure\":\"\"", with: "\"tool_failure\":\"\(health)\"")),
                      "reported \(health) failure cannot pass as quiet")
            }
            let sensitive = #"{"item_count":1,"notable":true,"has_action_items":false,"summary":"Synthetic card fixture: 4111 1111 1111 1111","tool_failure":""}"#
            check(try MCPSource.parse(sensitive, slug: slug) == .quiet(itemCount: 0), "high-risk text is dropped before observation or storage")

            func codexReadTrace(_ name: String, failed: Bool = false, completed: Bool = true) throws -> String {
                let value: [String: Any] = ["type": "item.completed", "item": [
                    "type": "mcp_tool_call", "tool": name, "status": completed ? "completed" : "failed",
                    "error": NSNull(), "result": ["isError": failed, "content": []]]]
                return String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
            }
            func claudeReadTrace(_ name: String, failed: Bool = false, resultID: String = "read1") throws -> String {
                let call: [String: Any] = ["type": "assistant", "message": ["content": [[
                    "type": "tool_use", "id": "read1", "name": name]]]]
                let result: [String: Any] = ["type": "user", "message": ["content": [[
                    "type": "tool_result", "tool_use_id": resultID, "is_error": failed,
                    "content": [["type": "text", "text": "{\"files\":[]}"]]]]]]
                return try [call, result].map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n")
            }
            check(!MCPSource.hasDriveReadEvidence(raw: #"{"type":"item.completed","item":{"type":"agent_message","text":"I checked Drive and found nothing"}}"#,
                backend: .chatgpt, requiresDiscovery: true), "model prose is not evidence for a quiet checkpoint")
            check(try MCPSource.hasDriveReadEvidence(raw: codexReadTrace("google_drive.search"),
                backend: .chatgpt, requiresDiscovery: true), "successful empty discovery permits a quiet result")
            check(try !MCPSource.hasDriveReadEvidence(raw: codexReadTrace("google_drive.search", failed: true),
                backend: .chatgpt, requiresDiscovery: true), "failed discovery cannot establish quiet success")
            check(try !MCPSource.hasDriveReadEvidence(raw: codexReadTrace("google_drive.search", completed: false),
                backend: .chatgpt, requiresDiscovery: true), "incomplete tool calls are not successful reads")
            check(try !MCPSource.hasDriveReadEvidence(raw: codexReadTrace("google_drive.fetch"),
                backend: .chatgpt, requiresDiscovery: true), "one fetched file cannot establish a quiet discovery window")
            check(try MCPSource.hasDriveReadEvidence(raw: codexReadTrace("gdrive.fetch"),
                backend: .chatgpt, requiresDiscovery: false), "successful content reads can support notable results")
            check(try !MCPSource.hasDriveReadEvidence(raw: codexReadTrace("gmail.search"),
                backend: .chatgpt, requiresDiscovery: true), "another connector cannot establish Drive read evidence")
            let search = "mcp__claude_ai_Google_Drive__search_files"
            check(try MCPSource.hasDriveReadEvidence(raw: claudeReadTrace(search),
                backend: .claude, requiresDiscovery: true), "Claude discovery requires a paired successful tool result")
            check(try !MCPSource.hasDriveReadEvidence(raw: claudeReadTrace(search, failed: true),
                backend: .claude, requiresDiscovery: true), "Claude permission denials cannot advance a quiet checkpoint")
            check(try !MCPSource.hasDriveReadEvidence(raw: claudeReadTrace(search, resultID: "unrelated"),
                backend: .claude, requiresDiscovery: true), "unmatched Claude tool results are not read evidence")
            check(try !MCPSource.hasDriveReadEvidence(raw: claudeReadTrace("ToolSearch"),
                backend: .claude, requiresDiscovery: true), "discovering tool names is not reading Drive")

            let schema = Schema([BucketPointer.self, CycleNote.self])
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            let store = CycleStore(modelContainer: container)
            let oldTime = Date(timeIntervalSince1970: 1_700_000_000)
            let now = oldTime.addingTimeInterval(86_400)
            let bucket = MCPSource.bucketKey(slug)
            let origin = ConnectorRegistry.readOrigin(slug: slug, backend: .chatgpt)
            let oldNote = NoteDraft(kind: .mcp, sourceID: "fixture-old", folder: "Google Drive", itemDate: oldTime,
                                    text: "Existing pending summary", title: "Fixture", reminderFlagged: false)
            check(await store.commitMCPRead(bucketKey: bucket, notes: [oldNote],
                through: ItemKey(order: oldTime.timeIntervalSince1970, tiebreak: ""), origin: origin,
                replaceNotes: true) == .saved, "baseline note and origin are committed together")
            let notable = try MCPSource.parse(good, slug: slug)
            let observed = OSAllocatedUnfairLock(initialState: [String]())
            let reader: MCPSource.Reader = { _, prompt, _, _ in
                observed.withLock { $0.append(prompt) }
                return notable
            }
            let kept = try await MCPSource.run(slug: slug, mode: .iterative, store: store, now: now, reader: reader)
            let afterDaily = await store.notes()
            check(kept == 1 && afterDaily.count == 2, "daily read appends an accepted note")
            check(try await store.mcpCheckpoint(bucket)?.mark.order == now.timeIntervalSince1970, "daily read advances to its captured end")
            check(observed.withLock { $0.last?.contains("DAILY READ") == true }, "matching origin uses the daily prompt")

            let failureReader: MCPSource.Reader = { _, _, _, _ in throw MCPSource.MCPError.invalidResponse(slug: "google-drive") }
            do {
                _ = try await MCPSource.run(slug: slug, mode: .initial, store: store,
                                           now: now.addingTimeInterval(10), reader: failureReader)
                check(false, "invalid initial result must throw")
            } catch { check(true, "invalid initial result throws") }
            let afterFailedRead = try await store.mcpCheckpoint(bucket)
            check((await store.notes()).count == 2 && afterFailedRead?.mark.order == now.timeIntervalSince1970,
                  "failed initial read preserves pending notes and marker")

            await store.failNextMCPCommitForTesting()
            do {
                _ = try await MCPSource.run(slug: slug, mode: .initial, store: store,
                                           now: now.addingTimeInterval(20), reader: reader)
                check(false, "disk-full transaction must throw")
            } catch { check(true, "disk-full transaction is surfaced") }
            let afterFailedSave = try await store.mcpCheckpoint(bucket)
            check((await store.notes()).count == 2 && afterFailedSave?.mark.order == now.timeIntervalSince1970,
                  "failed replacement transaction rolls back deletions and insertions")

            _ = try await MCPSource.run(slug: slug, mode: .initial, store: store,
                                       now: now.addingTimeInterval(30), reader: reader)
            check((await store.notes()).count == 1, "successful explicit initial read replaces previous notes")
            let quietReader: MCPSource.Reader = { _, _, _, _ in .quiet(itemCount: 2) }
            _ = try await MCPSource.run(slug: slug, mode: .iterative, store: store,
                                       now: now.addingTimeInterval(40), reader: quietReader)
            let afterQuiet = try await store.mcpCheckpoint(bucket)
            check((await store.notes()).count == 1 && afterQuiet?.mark.order == now.addingTimeInterval(40).timeIntervalSince1970,
                  "successful quiet read advances without erasing pending summaries")

            _ = await store.commitMCPRead(bucketKey: bucket, notes: [],
                through: ItemKey(order: now.timeIntervalSince1970, tiebreak: ""), origin: "v1:claude:0", replaceNotes: false)
            _ = try await MCPSource.run(slug: slug, mode: .iterative, store: store,
                                       now: now.addingTimeInterval(50), reader: reader)
            let afterBackfill = await store.notes()
            check(observed.withLock { $0.last?.contains("FIRST READ") == true } && afterBackfill.count == 2,
                  "origin change backfills while preserving pending summaries")

            let legacyBucket = MCPSource.bucketKey("gmail")
            _ = await store.setPointer(legacyBucket, ItemKey(order: oldTime.timeIntervalSince1970, tiebreak: ""))
            check(try await store.mcpCheckpoint(legacyBucket)?.origin == nil, "legacy checkpoints retain unknown provenance")
            let cancellationReader: MCPSource.Reader = { _, _, _, _ in throw CancellationError() }
            do {
                _ = try await MCPSource.run(slug: slug, mode: .initial, store: store,
                                           now: now.addingTimeInterval(60), reader: cancellationReader)
                check(false, "cancellation must propagate")
            } catch is CancellationError { check(true, "cancellation propagates without saving") }
            check(try await store.mcpCheckpoint(bucket)?.mark.order == now.addingTimeInterval(50).timeIntervalSince1970,
                  "cancellation preserves the prior checkpoint")

            for backend in [ModelBackend.claude, .chatgpt] {
                for mode in [MCPSource.ReadMode.initial, .iterative] {
                    let windows = try MCPSource.windows(slug: slug, mode: mode, since: oldTime, now: now)
                    let prompt = MCPSource.prompt(slug: slug, name: "Google Drive", backend: backend, mode: mode, window: windows[0])
                    check(prompt.contains(MCPSource.timestamp(now)) && !prompt.contains("—"), "prompt has exact upper bound and house style")
                    check(prompt.contains(mode == .initial ? "at most 8 times" : "at most 4 times"), "content-read budget matches mode")
                    check(prompt.contains(backend == .claude ? "GOOGLE DRIVE TOOLS ON CLAUDE" : "GOOGLE DRIVE TOOLS ON CODEX"), "tool instructions match engine")
                    check(prompt.utf8.count < 20_000, "prompt stays comfortably inside the CLI input limit")
                }
            }
            for (testSlug, count) in [("gmail", 4), ("google-calendar", 12)] {
                let windows = try MCPSource.windows(slug: testSlug, mode: .initial, since: nil, now: now)
                check(windows.count == count && windows[0].upper == now, "windowed adapter keeps its count and excludes the future")
                check(zip(windows, windows.dropFirst()).allSatisfy { $0.lower == $1.upper }, "windowed adapter boundaries are contiguous")
            }
            check(ConnectorRegistry.kbEligible(slug, backend: .chatgpt) && ConnectorRegistry.kbEligible(slug, backend: .claude), "Drive is eligible on both verified hosted engines")
            check(!ConnectorRegistry.kbEligible(slug, backend: .custom) && !ConnectorRegistry.kbEligible("notion", backend: .claude), "unsupported provider and uncurated pack are ineligible")

            func identityTrace(_ id: String) throws -> String {
                let payload = String(data: try JSONSerialization.data(withJSONObject: ["result": ["id": id, "email": "fixture@example.invalid"]]), encoding: .utf8)!
                return String(data: try JSONSerialization.data(withJSONObject: ["type": "item.completed", "item": [
                    "type": "mcp_tool_call", "tool": "google_drive.get_profile", "status": "completed", "error": NSNull(),
                    "result": ["content": [["type": "text", "text": payload]], "isError": false]]]), encoding: .utf8)!
            }
            let identityA = try MCPSource.profileFingerprint(raw: identityTrace("account-a"))
            let identityB = try MCPSource.profileFingerprint(raw: identityTrace("account-b"))
            check(identityA?.count == 64 && identityA != identityB, "account identity is a stable local fingerprint")
            func structuredProfile(_ workspace: Any, extra: Bool = false) throws -> String {
                var profile: [String: Any] = ["id": "account-a", "name": "Fixture", "email": "fixture@example.invalid",
                    "nickname": NSNull(), "picture": NSNull(), "workspace_id": workspace, "workspace_name": NSNull()]
                if extra { profile["unexpected_scope"] = "unknown" }
                return String(data: try JSONSerialization.data(withJSONObject: ["type": "item.completed", "item": [
                    "type": "mcp_tool_call", "tool": "google_drive.get_profile", "status": "completed", "error": NSNull(),
                    "result": ["content": [["type": "text", "text": "Action completed."]], "structured_content": profile]]]), encoding: .utf8)!
            }
            check(try MCPSource.profileFingerprint(raw: structuredProfile(NSNull())) == identityA, "current Drive profile with null workspace preserves account fingerprint")
            check(try MCPSource.profileFingerprint(raw: structuredProfile("workspace-a")) != MCPSource.profileFingerprint(raw: structuredProfile("workspace-b")), "Drive workspace changes alter checkpoint identity")
            do { _ = try MCPSource.profileFingerprint(raw: structuredProfile(42)); check(false, "malformed workspace must fail") }
            catch { check(true, "malformed Drive workspace is rejected") }
            do { _ = try MCPSource.profileFingerprint(raw: structuredProfile(NSNull(), extra: true)); check(false, "unknown profile shape must fail") }
            catch { check(true, "unreviewed Drive profile fields remain rejected") }
            do { _ = try MCPSource.profileFingerprint(raw: identityTrace("account-a") + "\n" + identityTrace("account-b")); check(false, "mixed identities must fail") }
            catch { check(true, "mixed successful profile identities are rejected") }
            do { _ = try MCPSource.profileFingerprint(raw: #"{"type":"item.completed","item":{"type":"agent_message","text":"account-a"}}"#); check(false, "model identity claims must fail") }
            catch { check(true, "model prose cannot establish account identity") }
            let identityCalls = OSAllocatedUnfairLock(initialState: 0)
            let changingIdentity: MCPSource.IdentityReader = { _ in
                identityCalls.withLock { count in count += 1; return count == 1 ? identityA : identityB }
            }
            let beforeIdentityChange = try await store.mcpCheckpoint(bucket)
            do {
                _ = try await MCPSource.run(slug: slug, mode: .iterative, store: store, now: now.addingTimeInterval(70),
                                           reader: reader, identityReader: changingIdentity)
                check(false, "account switch during a read must fail")
            } catch { check(true, "account switch during a read aborts the commit") }
            check(try await store.mcpCheckpoint(bucket)?.mark == beforeIdentityChange?.mark, "account switch preserves previous progress")

            let exactSchema = try JSONSerialization.jsonObject(with: Data(ConnectorClassifier.classificationSchema(inventory: inventoryNames).utf8)) as! [String: Any]
            let props = exactSchema["properties"] as! [String: Any]
            let array = props["tools"] as! [String: Any]
            let items = array["items"] as! [String: Any]
            let fields = items["properties"] as! [String: Any]
            let nameField = fields["name"] as! [String: Any]
            check(array["minItems"] as? Int == inventoryNames.count && array["maxItems"] as? Int == inventoryNames.count, "classification schema pins the native tool count")
            check(Set(nameField["enum"] as? [String] ?? []) == Set(inventoryNames), "classification schema prohibits invented or old alias names")
            // Replays the observed unsafe classifications without executing connector tools.
            for (service, prefix, names) in [
                ("asana", "mcp__claude_ai_Asana__", ["update_tasks", "update_project", "save_project_changes_confirm", "save_task_changes_confirm", "delete_task", "create_project_confirm_populate"]),
                ("linear", "mcp__claude_ai_Linear__", ["unshare_issue", "merge_diff", "update_diff", "save_document", "save_comment", "save_issue", "save_project", "save_release", "save_release_note", "save_status_update"]) ] {
                for name in names {
                    let good = [ConnectorRegistry.ClassifiedTool(name: prefix + name, category: .destructive)]
                    try ConnectorClassifier.validate(good, slug: service, inventory: good.map(\.name))
                    for category in [ConnectorRegistry.ToolCategory.read, .write] {
                        let unsafe = [ConnectorRegistry.ClassifiedTool(name: prefix + name, category: category)]
                        do { try ConnectorClassifier.validate(unsafe, slug: service, inventory: unsafe.map(\.name)); check(false, "\(service) \(name) cannot be downgraded") }
                        catch { check(true, "\(service) \(name) blocks \(category.rawValue) verdict") }
                        let capture = ConnectorRegistry.Classification(tools: unsafe, cliVersion: "fixture", capturedAt: now, verifiedInventory: unsafe.map(\.name))
                        check(!ConnectorClassifier.isFresh(capture, slug: service, version: "fixture", now: now), "old unsafe cache invalidated for \(service) \(name)")
                    }
                }
            }
            let prefix = "mcp__claude_ai_Google_Drive__"
            let reads = ConnectorRegistry.pack(forSlug: slug)!.readTools!
            let tools = reads.map { ConnectorRegistry.ClassifiedTool(name: prefix + $0, category: .read) }
                + ["create_file", "copy_file", "share_file", "update_file"].map { .init(name: prefix + $0, category: .write) }
                + [.init(name: prefix + "trash_file", category: .destructive)]
            try ConnectorClassifier.validate(tools, slug: slug, inventory: tools.map(\.name))
            check(true, "complete reviewed classification validates")
            let unsafe = tools.dropLast() + [.init(name: prefix + "trash_file", category: .write)]
            do { try ConnectorClassifier.validate(Array(unsafe), slug: slug); check(false, "trash must be destructive") }
            catch { check(true, "trash-as-write is rejected") }
            do { try ConnectorClassifier.validate(Array(tools.dropLast()), slug: slug, inventory: tools.map(\.name)); check(false, "missing inventory must fail") }
            catch { check(true, "missing destructive inventory entry is rejected") }
            do { try ConnectorClassifier.validate(tools + [tools[0]], slug: slug); check(false, "duplicate verdict must fail") }
            catch { check(true, "duplicate classifications are rejected") }
            let bare = tools.map { ConnectorRegistry.ClassifiedTool(name: String($0.name.dropFirst(prefix.count)), category: $0.category) }
            let bareJSON = String(data: try JSONEncoder().encode(["tools": bare]), encoding: .utf8)!
            check(try Set(ConnectorClassifier.parse(bareJSON, prefix: prefix).map(\.name)) == Set(tools.map(\.name)), "bare MCP names qualify to the verified server namespace")
            let conflicting = bare + [.init(name: prefix + "trash_file", category: .write)]
            let conflictJSON = String(data: try JSONEncoder().encode(["tools": conflicting]), encoding: .utf8)!
            do { _ = try ConnectorClassifier.parse(conflictJSON, prefix: prefix); check(false, "conflicting bare/full verdicts must fail") }
            catch { check(true, "conflicting bare/full verdicts are rejected") }
            let capture = ConnectorRegistry.Classification(tools: tools, cliVersion: "fixture", capturedAt: now,
                                                            verifiedInventory: tools.map(\.name))
            let legacyCapture = ConnectorRegistry.Classification(tools: tools, cliVersion: "fixture", capturedAt: now)
            check(!ConnectorClassifier.isFresh(legacyCapture, slug: slug, version: "fixture", now: now), "unverified legacy classification requires refresh")
            check(ConnectorClassifier.isFresh(capture, slug: slug, version: "fixture", now: now), "current classification is usable")
            check(!ConnectorClassifier.isFresh(capture, slug: slug, version: "changed", now: now), "CLI version drift invalidates classification")
            check(!ConnectorClassifier.isFresh(capture, slug: slug, version: "fixture", now: now.addingTimeInterval(ConnectorClassifier.captureTTL)), "TTL expiry excludes stale action policy")
            check(!ConnectorClassifier.isFresh(capture, slug: slug, version: "fixture", now: now.addingTimeInterval(-1)), "future-dated capture is not trusted")

            for bad in ["Done", "STATUS: NOT DONE", "STATUS: DONEISH", "STATUS: DONE - earlier\nStill working"] {
                if case .none = AgentStatus.parseConnector(bad) { check(true, "unconfirmed action cannot become DONE") }
                else { check(false, "unconfirmed action cannot become DONE") }
            }
            if case .done = AgentStatus.parseConnector("STATUS: DONE - Created the fixture\n  \n") { check(true, "exact final DONE accepts trailing whitespace") }
            else { check(false, "exact final DONE accepts trailing whitespace") }
            if case .couldNot = AgentStatus.parseConnector("STATUS: COULD_NOT - The content is not done") { check(true, "failure reason mentioning done remains a failure") }
            else { check(false, "failure reason mentioning done remains a failure") }

            if let path = ProcessInfo.processInfo.environment["LAB_MIGRATION_STORE"] {
                let migrated = try ModelContainer(for: schema,
                    configurations: ModelConfiguration(schema: schema, url: URL(fileURLWithPath: path)))
                let migrationStore = CycleStore(modelContainer: migrated)
                let migrationNotes = await migrationStore.notes()
                check(!migrationNotes.isEmpty, "copied pre-change database opens with its notes preserved")
                let checkpoint = try await migrationStore.mcpCheckpoint(bucket)
                check(checkpoint != nil && checkpoint?.origin == nil, "existing marker migrates with unknown origin")
            }
        } catch { check(false, "unexpected fixture error: \(ErrorLabel(error))") }
        Log("Connector curation checks: \(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
}

#endif
