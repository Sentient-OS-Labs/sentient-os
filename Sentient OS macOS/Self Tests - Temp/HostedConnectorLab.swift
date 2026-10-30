#if DEBUG
// Actual-app hosted connector acceptance against an explicitly local synthetic gateway.
// Runs before AppState, isolates defaults and data, and exercises production dispatch and storage.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import Foundation
import ObjectiveC
import SwiftData
import SwiftUI

private nonisolated final class HostedFixtureDefaults: NSObject {
    nonisolated(unsafe) static var value: UserDefaults?
    @objc class func isolatedStandard() -> UserDefaults { value! }
}
@MainActor enum HostedConnectorLab {
    enum Failure: Error { case configuration, assertion, syntheticInterruption }
    private static var root: URL!
    private static var checks: [String: Bool] = [:]
    static func prepare() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LAB_HOSTED_CONNECTOR_ROOT"], path.hasPrefix("/"),
              let gateway = env["LAB_HOSTED_CONNECTOR_GATEWAY"], let url = URL(string: gateway),
              url.scheme == "http", url.host == "127.0.0.1", url.path.isEmpty,
              url.user == nil, url.password == nil, url.query == nil else { throw Failure.configuration }
        root = URL(fileURLWithPath: path).standardizedFileURL
        guard root == root.resolvingSymlinksInPath(), root.lastPathComponent.hasPrefix("sentient-connectors-"),
              let runtimePath = env["SENTIENT_CODEX_RUNTIME_ROOT"],
              URL(fileURLWithPath: runtimePath).standardizedFileURL == root.appendingPathComponent("runtime"),
              (try? String(contentsOf: root.appendingPathComponent(".fixture"), encoding: .utf8)) == "1\n",
              let suite = env["LAB_HOSTED_CONNECTOR_SUITE"], suite.hasPrefix("ai.sentient.connector-fixture."),
              let defaults = UserDefaults(suiteName: suite),
              let getter = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)),
              let replacement = class_getClassMethod(HostedFixtureDefaults.self, #selector(HostedFixtureDefaults.isolatedStandard)) else { throw Failure.configuration }
        HostedFixtureDefaults.value = defaults
        method_setImplementation(getter, method_getImplementation(replacement))
        guard UserDefaults.standard === defaults else { throw Failure.configuration }
        defaults.set("sentient", forKey: ModelBackend.key)
        defaults.set(gateway, forKey: "sentient.hosted.gatewayURL")
        checks["isolated_defaults"] = true
    }
    private static func require(_ name: String, _ value: Bool) throws {
        checks[name] = value; if !value { throw Failure.assertion }
    }
    static func run() async -> Int32 {
        let phase = ProcessInfo.processInfo.environment["LAB_HOSTED_CONNECTOR_PHASE"] ?? ""
        do {
            let gateway = URL(string: ProcessInfo.processInfo.environment["LAB_HOSTED_CONNECTOR_GATEWAY"]!)!
            let live = phase.hasPrefix("live-")
            let token = live ? try String(contentsOf: root.appendingPathComponent("principal-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) : "principal-a"
            guard !live || token.hasPrefix("acceptance_") else { throw Failure.configuration }
            let identity = try JSONSerialization.data(withJSONObject: ["accessToken": token, "refreshToken": "fixture-refresh",
                "expiresAt": Date().addingTimeInterval(86400).timeIntervalSinceReferenceDate,
                "userID": "10000000-0000-4000-8000-000000000001", "origin": gateway.absoluteString])
            let config = HostedInferenceConfiguration(gatewayURL: gateway, identityURL: gateway, publishableKey: "fixture-public")
            let client = HostedInferenceClient(configuration: { config }, credentials: .init(read: { identity }, write: { _ in throw Failure.assertion }))
            let connector = HostedConnectorClient(client: client)
            try await HostedInference.$clientOverride.withValue(client) {
                try await HostedConnectorClient.$override.withValue(connector) {
                    if phase == "lifecycle" {
                        let unopened = HostedConnectorClient(client: HostedInferenceClient(configuration: { config }, credentials: .init(
                            read: { throw Failure.assertion }, write: { _ in throw Failure.assertion })))
                        try await unopened.disconnectAll()
                        checks["inference_only_reset_needs_no_connector_service_or_keychain"] = true
                        UserDefaults.standard.set(true, forKey: HostedConnectorStore.managementUsedKey)
                        do { try await unopened.disconnectAll(); throw Failure.configuration }
                        catch Failure.assertion { checks["unfinished_authorization_cannot_skip_cleanup"] = true }
                        UserDefaults.standard.removeObject(forKey: HostedConnectorStore.managementUsedKey)
                        return
                    }
                    if live {
                        if phase == "live-read" { try await liveRead(client: connector) }
                        else if phase == "live-cleanup" { try await connector.disconnectAll() }
                        else if phase.hasPrefix("live-connect-") {
                            let service = String(phase.dropFirst("live-connect-".count))
                            guard ["gmail", "google-calendar", "google-drive"].contains(service) else { throw Failure.configuration }
                            try await connectUI(service: service, client: connector)
                        } else { throw Failure.configuration }
                        return
                    }
                    if phase == "source-first" {
                        let attempt = try await connector.begin(service: "gmail", label: "Fixture account", reconnect: nil)
                        try require("oauth_completed", try await connector.poll(attempt))
                        let account = HostedConnectorStore.accounts().first!
                        ConnectorRegistry.setKBEnabled(account.slug, true)
                    } else { _ = try await connector.refresh() }
                    guard let account = HostedConnectorStore.accounts().first(where: { $0.service == "gmail" }) else { throw Failure.configuration }
                    try require("processing_admits_selection", ProcessingRequest.current().mcpSlugs.contains(account.slug))
                    try require("subscription_gmail_not_borrowed", !ProcessingRequest.current().runGmail)
                    if phase.hasPrefix("source-") { try await source(phase: phase, account: account) }
                    else if phase == "structured" {
                        try await HostedInference.withRun(purpose: .sidekick) { @MainActor in
                            let before = HostedInference.currentRun?.id
                            var inv = CodexCLI.Invocation(prompt: "Read synthetic message abcdef0011223344 using this account's gmail_read tool, then report STATUS: DONE. This is a fixture; no other data or action is authorized.")
                            inv.cwd = root.path; inv.webSearch = false; inv.timeout = 60
                            inv.mcpActionServer = account.taskTarget; inv.hostedConnectorMode = "read"
                            let response = try await FrontierRun.run(inv)
                            try require("structured_real_cli_completed", response.result.contains("STATUS: DONE"))
                            try require("one_foreground_scope", before == HostedInference.currentRun?.id)
                        }
                    } else if phase == "bridge" { try await bridge(account: account) }
                    else if phase == "policy" { try await policy(account: account, client: connector) }
                    else if phase == "recovery" { try await recovery(account: account) }
                    else if phase == "bounded" { try await bounded(account: account) }
                    else if phase == "summary-cli" { try await summaryCLI(account: account) }
                    else if phase == "render" { try await render(account: account) }
                    else { throw Failure.configuration }
                }
            }
            try JSONSerialization.data(withJSONObject: ["phase": phase, "passed": true, "checks": checks], options: [.prettyPrinted,.sortedKeys])
                .write(to: root.appendingPathComponent(phase + ".json"), options: .atomic)
            Log("Hosted connector fixture: \(phase) passed \(checks.count) checks")
            return 0
        } catch {
            try? JSONSerialization.data(withJSONObject: ["phase": phase, "passed": false, "checks": checks,
                "error_type": String(describing: type(of: error))], options: [.prettyPrinted,.sortedKeys])
                .write(to: root.appendingPathComponent(phase + ".json"), options: .atomic)
            Log("Hosted connector fixture failed: \(phase), \(ErrorLabel(error))")
            return 1
        }
    }
    private static func summaryCLI(account: HostedConnectorAccount) async throws {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("summary.store")))
        let store = CycleStore(modelContainer: container), now = Date()
        let plan = try HostedConnectorReadState.plan(origin: account.taskTarget, calendar: false, since: now.addingTimeInterval(-3600), now: now)
        _ = try await store.beginHostedConnectorRead(bucketKey: MCPSource.bucketKey(account.slug), proposed: plan)
        let kept = try await HostedConnectorSource.run(slug: account.slug, mode: .initial, store: store, now: now, onProgress: { _ in })
        let notes = await store.notes()
        try require("real_cli_selected_and_summarized_source_evidence", kept == 1 && notes.count == 1 && notes[0].text.contains("Quartz milestone"))
        try require("real_cli_summary_published_with_checkpoint", (try await store.mcpCheckpoint(MCPSource.bucketKey(account.slug))?.mark.order ?? 0) > 0)
    }
    private static func bounded(account: HostedConnectorAccount) async throws {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("bounded.store")))
        let store = CycleStore(modelContainer: container), now = Date()
        try await InitialAnalysisRecovery.$replayCloudStages.withValue(true) {
            try await HostedConnectorSource.$summarizeOverride.withValue({ _, _ in
                .notable(.init(summary: "Synthetic bounded import page", hasActionItems: false, itemCount: 1))
            }) {
                for attempt in 0..<5 {
                    do {
                        _ = try await HostedConnectorSource.run(slug: account.slug, mode: .initial, store: store, now: now, onProgress: { _ in })
                        try require("large_import_finishes_after_bounded_attempts", attempt == 4)
                    } catch HostedConnectorFailure.incompleteRead {
                        try require("page_limit_is_partial_\(attempt)", attempt < 4)
                        try require("partial_import_keeps_watermark_\(attempt)", try await store.mcpCheckpoint(MCPSource.bucketKey(account.slug))?.mark.order == 0)
                    }
                    try require("bounded_progress_is_not_replayed_\(attempt)", await store.notes().count == min(96, 20 * (attempt + 1)))
                }
                let notes = await store.notes()
                try require("all_96_pages_have_unique_pending_summaries", Set(notes.map(\.sourceID)).count == 96)
                try require("large_import_advances_watermark_only_when_complete", (try await store.mcpCheckpoint(MCPSource.bucketKey(account.slug))?.mark.order ?? 0) > 0)
            }
        }
    }
    private static func recovery(account: HostedConnectorAccount) async throws {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("recovery.store")))
        let store = CycleStore(modelContainer: container), bucket = "mcp.fixture.recovery"
        let plan = try HostedConnectorReadState.plan(origin: account.taskTarget, calendar: false, since: nil, now: Date())
        var state = try await store.beginHostedConnectorRead(bucketKey: bucket, proposed: plan)
        func note(_ state: HostedConnectorReadState) -> NoteDraft {
            .init(kind: .mcp, sourceID: state.sourceID, folder: "Fixture", itemDate: state.windows[state.windowIndex].end,
                  text: "Synthetic bounded page", title: nil, reminderFlagged: false)
        }
        for _ in 0..<2 {
            let previous = state; state.advance(cursor: UUID().uuidString.lowercased())
            try await store.commitHostedConnectorPage(bucketKey: bucket, expected: previous, next: state, note: note(previous))
        }
        let beforeRestart = state
        state.cursor = nil; state.pageIndex = 0; state.revision += 1
        await store.failNextMCPCommitForTesting()
        do {
            try await store.commitHostedConnectorPage(bucketKey: bucket, expected: beforeRestart, next: state, note: nil)
            throw Failure.assertion
        } catch MCPSource.MCPError.storageFailure { }
        try require("failed_cursor_restart_preserves_notes", await store.notes().count == 2)
        try require("failed_cursor_restart_preserves_cursor", try await store.beginHostedConnectorRead(bucketKey: bucket, proposed: plan) == beforeRestart)
        try await store.commitHostedConnectorPage(bucketKey: bucket, expected: beforeRestart, next: state, note: nil)
        try require("cursor_restart_removes_entire_unfinished_window", await store.notes().isEmpty)
        let previous = state; state.advance(cursor: UUID().uuidString.lowercased())
        try await store.commitHostedConnectorPage(bucketKey: bucket, expected: previous, next: state, note: note(previous))
        let replay = try await InitialAnalysisRecovery.$replayCloudStages.withValue(true) {
            try await store.beginHostedConnectorRead(bucketKey: bucket, proposed: plan)
        }
        try require("initial_recovery_preserves_durable_pagination", replay == state)
        try require("initial_recovery_preserves_committed_pages", await store.notes().count == 1)
        var afterReplay = replay; afterReplay.advance(cursor: UUID().uuidString.lowercased())
        try await store.commitHostedConnectorPage(bucketKey: bucket, expected: replay, next: afterReplay, note: note(replay))
        let changed = try HostedConnectorReadState.plan(origin: account.slug + "@999", calendar: false, since: nil, now: Date())
        _ = try await store.beginHostedConnectorRead(bucketKey: bucket, proposed: changed)
        try require("reconnect_retires_old_generation_pending_notes", await store.notes().isEmpty)
        do {
            var stale = afterReplay; stale.advance(cursor: nil)
            try await store.commitHostedConnectorPage(bucketKey: bucket, expected: afterReplay, next: stale, note: note(afterReplay))
            throw Failure.assertion
        } catch MCPSource.MCPError.connectionChanged { checks["stale_generation_cannot_publish"] = true }
    }
    private static func connectUI(service: String, client: HostedConnectorClient) async throws {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Sentient • Read-only connector acceptance"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            window.contentViewController = NSHostingController(rootView: AcceptanceConnectionHost(service: service, client: client) { continuation.resume() })
            window.center(); window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        }
        window.orderOut(nil)
        let inventory = try await client.refresh()
        try require("oauth_connected_" + service, inventory.connections.contains { $0.service == service && $0.connected })
    }
    private static func liveRead(client: HostedConnectorClient) async throws {
        let inventory = try await client.refresh()
        let selected = Set((ProcessInfo.processInfo.environment["LAB_HOSTED_CONNECTOR_SERVICES"] ?? "gmail,google-calendar,google-drive").split(separator: ",").map(String.init))
        guard !selected.isEmpty, selected.isSubset(of: ["gmail", "google-calendar", "google-drive"]) else { throw Failure.configuration }
        // Unique synthetic marker only; never enumerate the user's mailbox or workspace.
        let query = "SentientAcceptanceNoData7cae58d19ff54d0b"
        let formatter = ISO8601DateFormatter()
        let end = Date(), start = end.addingTimeInterval(-86400)
        let arguments: ConnectorJSON = .object(["start": .string(formatter.string(from: start)), "end": .string(formatter.string(from: end)), "query": .string(query)])
        try await HostedInference.withRun(purpose: .sidekick) { @MainActor in
            guard let run = HostedInference.currentRun else { throw Failure.configuration }
            for (service, tool) in [("gmail", "gmail_search"), ("google-calendar", "google_calendar_list"), ("google-drive", "drive_search")] {
                guard selected.contains(service) else { continue }
                guard let account = inventory.connections.first(where: { $0.service == service && $0.connected }) else { throw Failure.configuration }
                let cap = try await client.prepare(account, mode: "read", run: run)
                do {
                    try require(service + "_read_only_capability", cap.tools.allSatisfy { !$0.write })
                    let result = try await client.execute(cap, tool: tool, arguments: arguments, operationID: UUID())
                    try require(service + "_bounded_query_completed", result.status == "completed")
                    try require(service + "_synthetic_marker_empty", result.data?["items"]?.array?.isEmpty == true && result.cursor == nil)
                    await client.close(cap)
                } catch { await client.close(cap); throw error }
            }
        }
    }
    private static func policy(account: HostedConnectorAccount, client: HostedConnectorClient) async throws {
        let inventory = try await client.refresh()
        let stale = HostedConnectorAccount(id: account.id, service: account.service, generation: account.generation + 100,
            label: "Stale fixture", status: "disconnected")
        try HostedConnectorStore.save([stale], revision: inventory.revision - 1)
        try require("late_inventory_cannot_roll_back_account", HostedConnectorStore.account(account.taskTarget) == account)
        let interaction = SidekickInteraction { _ in throw Failure.assertion }
        let services = [CommandRouter.Service(slug: account.taskTarget, name: account.displayName,
            description: account.taskDescription, providerSlug: account.service, accountLabel: account.label)]
        try await SidekickInteraction.$current.withValue(interaction) {
            try await HostedInference.withRun(purpose: .sidekick) { @MainActor in
                for writing in [true, false] {
                    let output = ConnectorJSON.object(["route": .string("computer"), "target": .null, "hosted_operation": .string("none"),
                        "hosted_write_targets": .array(writing ? [.string(account.taskTarget)] : [])]).text
                    await FrontierRun.$acceptanceRun.withValue({ invocation in
                        guard invocation.toolsDisabled else { throw Failure.assertion }
                        return .init(result: output, sessionID: nil, numTurns: 1, durationMS: 1, inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, raw: "")
                    }) {
                        _ = await CommandRouter.route(writing ? "Send a Gmail email, then open the synthetic website" : "Read my Gmail and open the synthetic website", services: services)
                    }
                    try require(writing ? "router_captures_requested_write" : "read_request_clears_write_authority",
                        interaction.authorizedHostedWrites.contains(account.taskTarget) == writing)
                    try await HostedConnectorToolServer.withConnection(targets: [account.taskTarget], mode: "task") { @MainActor in
                        let hasSend = HostedConnectorToolServer.connection?.tools.contains(where: { $0.hasPrefix("gmail_send_") }) == true
                        try require(writing ? "requested_write_attaches" : "computer_read_has_no_send_tool", hasSend == writing)
                    }
                }
            }
        }
    }
    private static func source(phase: String, account: HostedConnectorAccount) async throws {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("cycle.store")))
        let store = CycleStore(modelContainer: container), summaryCounter = Counter()
        try await CycleStore.$acceptanceStore.withValue(store) {
            try await HostedConnectorSource.$summarizeOverride.withValue({ _, _ in
                let count = await summaryCounter.next()
                if phase == "source-first" && count == 2 { throw Failure.syntheticInterruption }
                return .notable(.init(summary: "The user is preparing the synthetic Quartz project review.", hasActionItems: true, itemCount: 1))
            }) {
                var request = ProcessingRequest.current(); request.fullCycle = false; request.readySelectionCount = nil
                let result = await ProcessingRun(request: request, scheduled: false).execute(progress: { _ in }, phase: { _ in }, onLine: { _ in })
                let notes = await store.notes()
                if phase == "source-first" {
                    try require("interrupted_page_saved", notes.count == 1)
                    try require("unfinished_window_does_not_advance_watermark", try await store.mcpCheckpoint(MCPSource.bucketKey(account.slug))?.mark.order == 0)
                    try require("real_failure_reported", !result.complete)
                    try require("failed_read_still_admitted", ProcessingRequest.current().mcpSlugs.contains(account.slug))
                } else {
                    try require("reopened_selection_preserved", ConnectorRegistry.isKBEnabled(account.slug))
                    try require("resumed_without_duplicate_pages", notes.count == 8 && Set(notes.map(\.sourceID)).count == 8)
                    try require("recovered_analysis_succeeded", result.complete)
                    try require("completed_windows_advance_watermark", (try await store.mcpCheckpoint(MCPSource.bucketKey(account.slug))?.mark.order ?? 0) > 0)
                }
            }
        }
    }
    private static func bridge(account: HostedConnectorAccount) async throws {
        try await HostedInference.withRun(purpose: .sidekick) { @MainActor in
            try await HostedConnectorToolServer.withConnection(targets: [account.taskTarget], mode: "read", requireCall: true) { @MainActor in
                guard let run = HostedInference.currentRun, let claude = ClaudeCLI.locateBinary() else { throw Failure.configuration }
                let native = LocalMCPServer(name: "sentient_native", tools: ["get_app_state"], timeout: 60) { data in
                    let rpc = try JSONDecoder().decode(ConnectorJSON.self, from: data)
                    let result: ConnectorJSON
                    switch rpc["method"]?.string {
                    case "initialize": result = .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])])
                    case "tools/list": result = .object(["tools": .array([.object(["name": .string("get_app_state"), "description": .string("Synthetic native tool; never reads the desktop."), "inputSchema": .object(["type": .string("object"), "properties": .object([:])])])])])
                    default: result = .object(["content": .array([.object(["type": .string("text"), "text": .string("Synthetic native fixture")])])])
                    }
                    return try ConnectorJSON.object(["jsonrpc": .string("2.0"), "id": rpc["id"] ?? .null, "result": result]).data()
                }
                let relay = ClaudeSubscriptionBridge(binary: claude, model: run.model, effort: "low", timeout: 60,
                    namespaces: ["mcp__sentient_native", "mcp__sentient_connectors"],
                    hostedEnvironment: try HostedClaudeRuntime.environment(), onProgress: { _ in })
                do {
                    let nativeConnection = try await native.start(), config = try await relay.start()
                    let disabled = ["features.shell_tool=false", "features.view_image=false", "features.browser_use=false",
                        "features.computer_use=false", "features.multi_agent=false", "features.code_mode=false", "features.image_generation=false",
                        "features.goals=false", "features.skill_search=false", "features.tool_search=false", "features.plugins=false",
                        "features.apps=false", "apps._default.enabled=false", "web_search=\"disabled\""]
                    var args = try CodexCLI.agentArguments(prompt: "Read synthetic message abcdef0011223344 using the provided Gmail read tool. Do not use any real apps, shell or data. End with STATUS: DONE.", imagePaths: [],
                        modelID: run.model, effortArg: "low", providerOverrides: config.overrides + disabled, nativeConnection: nativeConnection)
                    args.insert(contentsOf: ["--ephemeral", "--cd", root.path], at: args.count - 1)
                    let output = try await ComputerUseStream.run(binary: CodexRuntime.executable.path, args: args, timeout: 60,
                        extraEnv: config.environment, narrate: false, onLine: { _ in })
                    try output.stdout.write(to: root.appendingPathComponent("bridge-output.ndjson"), atomically: true, encoding: .utf8)
                    try require("real_codex_bridge_exit", output.status == 0)
                    try require("bridge_completed", output.stdout.contains("STATUS: DONE") || output.stdout.contains("Synthetic connector read verified"))
                    await relay.stop(); await native.stop()
                } catch { await relay.stop(); await native.stop(); throw error }
            }
        }
    }
    private static func render(account: HostedConnectorAccount) async throws {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let view = HostedConnectorConnectSheet(service: "gmail", account: account, refreshOnOpen: false).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.backgroundColor = .black
        host.layoutSubtreeIfNeeded(); window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.assertion }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw Failure.assertion }
        try data.write(to: root.appendingPathComponent("connection.png"))
        try require("connection_view_rendered", bitmap.pixelsWide > 400 && bitmap.pixelsHigh > 400)
        try require("hosted_picker_stays_hidden", !FrontierEngineTab.hostedUsageVisible)
    }
    private actor Counter { var value = 0; func next() -> Int { value += 1; return value } }
}

private struct AcceptanceConnectionHost: View {
    let service: String
    let client: HostedConnectorClient
    let finished: () -> Void
    @State private var showing = false
    var body: some View {
        VStack(spacing: 20) {
            Text("Read-only acceptance").font(.title2)
            Text("Only a unique synthetic-marker search will run after connecting the three Google services.")
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Open connection sheet") { showing = true }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showing, onDismiss: finished) {
            HostedConnectorConnectSheet(service: service, client: client).preferredColorScheme(.dark)
        }
    }
}
#endif
