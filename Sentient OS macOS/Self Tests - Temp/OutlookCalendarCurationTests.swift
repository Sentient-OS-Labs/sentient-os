#if DEBUG
//
// OutlookCalendarCurationTests.swift
// Calendar curation fixtures and explicit live checks. Uses isolated stores and one reserved
// no-attendee creation per engine; native traces stay in the private review directory.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation
import SwiftData
import os

enum OutlookCalendarCurationTests {
    static let slug = OutlookCalendarConnector.slug
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LAB_CALENDAR_OUTPUT_DIR"]
        ?? "/tmp/sentient-outlook-calendar-curation", isDirectory: true)
    static func date(_ text: String) -> Date { OutlookMailSource.date(text)! }
    static let window = MCPSource.Window(lower: date("2026-09-01T00:00:00Z"), upper: date("2026-09-15T00:00:00Z"), label: "fixture")
    static func event(id: String = "EVENT_FIXTURE", start: String = "2026-09-14T09:00:00", end: String = "2026-09-14T10:00:00") -> [String: Any] {
        ["id": id, "subject": "Project planning", "start": ["dateTime": start, "timeZone": "UTC"],
         "end": ["dateTime": end, "timeZone": "UTC"], "webLink": "https://outlook.office.com/calendar/item/\(id)",
         "attendees": [], "body": ["contentType": "text", "content": ""], "location": ["displayName": ""],
         "isCancelled": false, "sensitivity": "normal", "showAs": "busy", "responseStatus": ["response": "accepted"]]
    }
    static func searchArgs(_ backend: ModelBackend, window: MCPSource.Window = window, offset: Int = 0) -> [String: Any] {
        backend == .claude
            ? ["query": "*", "afterDateTime": MCPSource.timestamp(window.lower.addingTimeInterval(-0.001)),
               "beforeDateTime": MCPSource.timestamp(window.upper), "order": "newest", "limit": 25, "offset": offset]
            : ["start_datetime": MCPSource.timestamp(window.lower), "end_datetime": MCPSource.timestamp(window.upper),
               "order_by": "start/dateTime desc", "top": 200]
    }
    static func trace(_ backend: ModelBackend, name: String, arguments: [String: Any], values: [[String: Any]],
                      callID: String = "call1", next: Int? = nil, total: Int? = nil, failed: Bool = false) -> String {
        func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
        if backend == .chatgpt {
            let result: [String: Any] = ["value": values, "next_link": next.map { "https://graph.microsoft.com/next/\($0)" } as Any? ?? NSNull()]
            return json(["type": "item.completed", "item": ["type": "mcp_tool_call", "id": callID,
                "server": "codex_apps", "tool": "microsoft_outlook_calendar." + name, "arguments": arguments,
                "status": failed ? "failed" : "completed", "result": ["content": [], "structured_content": result]]])
        }
        let full = Microsoft365Connector.prefix + name
        var payloads = values
        if let next { payloads.append(["nextOffset": next, "totalResultCount": 26]) }
        else if let total { payloads.append(["totalResultCount": total]) }
        let content: Any = payloads.isEmpty ? "(\(full) completed with no output)"
            : payloads.map { ["type": "text", "text": json($0)] }
        return json(["type": "assistant", "message": ["content": [["type": "tool_use", "id": callID, "name": full, "input": arguments]]]])
            + "\n" + json(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": callID, "is_error": failed, "content": content]]]])
    }

    static func run() async {
        var failures = 0, count = 0
        func check(_ value: Bool, _ label: String) { count += 1; if !value { failures += 1 }; Log("\(value ? "PASS" : "FAIL") \(label)") }
        func rejects(_ work: () throws -> Void) -> Bool { do { try work(); return false } catch { return true } }
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        var domain = saved
        let suite = ConnectorCensus.DetectedConnector(slug: "microsoft-365", displayName: Microsoft365Connector.name,
            origin: .claude, serverURL: Microsoft365Connector.url, catalogID: nil, iconPath: nil, healthy: true, lastSeen: Date())
        let projected = ConnectorCensus.logicalServices([suite])
        check(projected.map(\.slug) == ["outlook-mail", slug], "one suite produces two logical services")
        check(ConnectorCensus.logicalServices(projected + [suite]) == projected, "repeated projection is idempotent")
        domain["mcp.connectors.claude"] = try! JSONEncoder().encode([suite])
        domain["mcp.connectors.chatgpt"] = try! JSONEncoder().encode([
            ConnectorCensus.DetectedConnector(slug: slug, displayName: "Outlook Calendar", origin: .chatgpt,
                serverURL: nil, catalogID: "connector_e6a7394682e24467ac68c60696f275a4", iconPath: nil, healthy: true, lastSeen: Date()),
            ConnectorCensus.DetectedConnector(slug: OutlookMailConnector.slug, displayName: "Outlook Mail", origin: .chatgpt,
                serverURL: nil, catalogID: "connector_4aaab2856305417b993eca9a216aaf6e", iconPath: nil, healthy: true, lastSeen: Date())])
        let tools = Microsoft365Connector.categories.map { ConnectorRegistry.ClassifiedTool(name: Microsoft365Connector.prefix + $0.key, category: $0.value) }
        domain[ConnectorRegistry.classificationKey(slug)] = try! JSONEncoder().encode(ConnectorRegistry.Classification(
            tools: tools, cliVersion: ConnectorClassifier.currentCLIVersion ?? "", capturedAt: Date(), verifiedInventory: tools.map(\.name)))
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        check(ConnectorRegistry.classificationKey(slug) == ConnectorRegistry.classificationKey("outlook-mail"), "suite shares the existing classification key")
        check(ConnectorRegistry.kbKey(slug) != ConnectorRegistry.kbKey("outlook-mail"), "knowledge preferences remain distinct")
        check(ConnectorRegistry.pack(forSlug: slug)?.kbAdapter == .windowedMonthly, "calendar uses monthly adapter")
        check(CalendarEventTime.timeZone("Pacific Standard Time")?.identifier == "America/Los_Angeles", "bundled Windows time-zone mapping")
        check(CalendarEventTime.date(["dateTime": "2026-09-15T09:00:00", "timeZone": "Pacific Standard Time"]) == date("2026-09-15T16:00:00Z"), "mailbox wall time converts exactly once")
        check(CalendarEventTime.date(["dateTime": "2026-09-15T09:00", "timeZone": "UTC"]) == date("2026-09-15T09:00:00Z"), "minute precision is accepted")
        for text in ["2026-03-08T02:30:00", "2026-11-01T01:30:00", "2026-02-30T10:00:00"] {
            check(CalendarEventTime.date(["dateTime": text, "timeZone": "America/Los_Angeles"]) == nil, "invalid or ambiguous wall time refuses: \(text)")
        }
        check(CalendarEventTime.date(["dateTime": "2026-09-15T09:00:00", "timeZone": "Invented Zone"]) == nil, "unknown zone never falls back to this Mac")
        check(!OutlookCalendarToolPolicy.integer(true, in: 1...25), "boolean is not a page limit")
        check(!OutlookCalendarToolPolicy.integer(1.5, in: 1...25), "fractional page limit refuses")
        check(OutlookCalendarConnector.eventID("calendar:///events/ABC%2FDEF%3D") == "ABC/DEF=", "event URI preserves observed ID")
        for uri in ["mail:///messages/ABC", "calendar:///events/ABC?owner=other@example.invalid", "calendar://host/events/ABC", "calendar:///events/ABC#fragment", "file:///events/ABC"] {
            check(OutlookCalendarConnector.eventID(uri) == nil, "unapproved resource URI refuses")
        }
        for backend in [ModelBackend.claude, .chatgpt] {
            await ModelBackend.$runOverride.withValue(backend) {
                let name = backend == .claude ? "outlook_calendar_search" : "list_events"
                let args = searchArgs(backend)
                let prefix = backend == .claude ? Microsoft365Connector.prefix : "microsoft_outlook_calendar."
                let context = OutlookCalendarToolPolicy.Context(operation: .read, purpose: .initial, window: window)
                check(OutlookCalendarToolPolicy.allowed(name: prefix + name, input: args, backend: backend, context: context), "\(backend) exact knowledge query allowed")
                var altered = args; altered[backend == .claude ? "calendarOwnerEmail" : "calendar_id"] = "OTHER"
                check(!OutlookCalendarToolPolicy.allowed(name: prefix + name, input: altered, backend: backend, context: context), "\(backend) other calendar refuses")
                altered = args; altered[backend == .claude ? "afterDateTime" : "start_datetime"] = "2020-01-01T00:00:00Z"
                check(!OutlookCalendarToolPolicy.allowed(name: prefix + name, input: altered, backend: backend, context: context), "\(backend) changed window refuses")
                let native = trace(backend, name: name, arguments: args, values: [event()])
                do {
                    let result = try OutlookCalendarSource.evidence(raw: native, backend: backend, purpose: .initial, window: window)
                    check(result.events.count == 1 && result.complete, "\(backend) native event evidence")
                    let empty = try OutlookCalendarSource.evidence(raw: trace(backend, name: name, arguments: args, values: []), backend: backend, purpose: .initial, window: window)
                    check(empty.events.isEmpty && empty.complete, "\(backend) actual empty discovery succeeds")
                    let boundary = [event(id: "LOWER", start: "2026-09-01T00:00:00", end: "2026-09-01T01:00:00"),
                                    event(id: "UPPER", start: "2026-09-15T00:00:00", end: "2026-09-15T01:00:00")]
                    let bounded = try OutlookCalendarSource.evidence(raw: trace(backend, name: name, arguments: args, values: boundary), backend: backend, purpose: .initial, window: window)
                    check(bounded.events.map(\.id) == ["LOWER"], "\(backend) half-open start boundary")
                    let spanning = event(start: "2026-08-31T00:00:00", end: "2026-09-02T00:00:00")
                    let overlap = try OutlookCalendarSource.evidence(raw: trace(backend, name: name, arguments: args, values: [spanning]), backend: backend, purpose: .context, window: window)
                    check(overlap.events.count == 1, "\(backend) context uses interval overlap")
                } catch { check(false, "\(backend) valid evidence rejected: \(ErrorLabel(error))") }
                check(rejects { _ = try OutlookCalendarSource.evidence(raw: "", backend: backend, purpose: .initial, window: window) }, "\(backend) assistant claim is not read evidence")
                check(rejects { _ = try OutlookCalendarSource.evidence(raw: trace(backend, name: name, arguments: args, values: [], failed: true), backend: backend, purpose: .initial, window: window) }, "\(backend) failed discovery is not quiet")
                var read = MCPSource.readInvocation(slug: slug, prompt: "fixture")
                read.outlookCalendarReadPurpose = .initial; read.outlookCalendarReadWindow = window
                do {
                    let argv = backend == .claude ? try ClaudeCLI.arguments(for: read, modelID: "sonnet", effortArg: "medium")
                        : try CodexCLI.arguments(for: read, modelID: "gpt-6-luna", effortArg: "medium", schemaFile: nil)
                    check(argv.joined().contains("--outlook-tool-policy"), "\(backend) read invokes native policy")
                    check(!argv.contains("--dangerously-bypass-approvals-and-sandbox") && !argv.contains("--dangerously-skip-permissions"), "\(backend) read remains sandboxed")
                    var mixed = read; mixed.mcpReadConnectors = ["outlook-mail", slug]; mixed.mcpReadToolNames = nil
                    mixed.outlookCalendarReadPurpose = nil; mixed.outlookCalendarReadWindow = nil
                    let both = backend == .claude ? try ClaudeCLI.arguments(for: mixed, modelID: "sonnet", effortArg: "medium")
                        : try CodexCLI.arguments(for: mixed, modelID: "gpt-6-luna", effortArg: "medium", schemaFile: nil)
                    check(both.joined().contains(backend == .claude ? "outlook_calendar_search" : "list_events"), "\(backend) mixed reads retain Calendar")
                    if backend == .claude, let index = both.firstIndex(of: "--disallowedTools") {
                        check(!both[index + 1].contains("outlook_calendar_search") && !both[index + 1].contains("__read_resource"), "mixed suite complement does not veto approved reads")
                    }
                } catch { check(false, "\(backend) recipe refused: \(ErrorLabel(error))") }
            }
        }
        do {
            var row = event(); row["uri"] = "calendar:///events/EVENT_FIXTURE"
            let raw = trace(.claude, name: "outlook_calendar_search", arguments: searchArgs(.claude), values: [row])
            let valid = MCPSource.ReadOutcome.notable(.init(summary: "The user was scheduled for project planning. calendar:///events/EVENT_FIXTURE", hasActionItems: false, itemCount: 1))
            check(!rejects { _ = try OutlookCalendarSource.validate(raw: raw, backend: .claude, mode: .initial, window: window, outcome: valid) }, "observed event URI is a valid source alongside webLink")
            let uncited = MCPSource.ReadOutcome.notable(.init(summary: "The user was scheduled for project planning. calendar:///events/EVENT_FIXTURE\n\nAnother unsupported paragraph.", hasActionItems: false, itemCount: 1))
            check(rejects { _ = try OutlookCalendarSource.validate(raw: raw, backend: .claude, mode: .initial, window: window, outcome: uncited) }, "every retained paragraph requires its own source")
            let fabricated = MCPSource.ReadOutcome.notable(.init(summary: "The user was scheduled for project planning. calendar:///events/EVENT_FIXTURE https://example.invalid/invented", hasActionItems: false, itemCount: 1))
            check(rejects { _ = try OutlookCalendarSource.validate(raw: raw, backend: .claude, mode: .initial, window: window, outcome: fabricated) }, "unobserved links cannot enter the summary")
        }
        let content = "Title: Fixture appointment\nStart: 2026-09-15T09:00:00\nEnd: 2026-09-15T09:15:00\nTime zone: UTC\nAttendees: \nLocation: \nNotes: Verification."
        check(OutlookCalendarActionEvidence.creationFromContent(content) != nil, "editable event details parse")
        for backend in [ModelBackend.claude, .chatgpt] {
            let base: [String: Any] = ["subject": "Fixture appointment",
                "start": ["dateTime": "2026-09-15T09:00:00", "timeZone": "UTC"],
                "end": ["dateTime": "2026-09-15T09:15:00", "timeZone": "UTC"]]
            var duplicate = base
            duplicate["attendees"] = ["required", "optional"].map { kind -> [String: Any] in
                backend == .claude ? ["email": "person@example.invalid", "type": kind]
                    : ["emailAddress": ["address": "person@example.invalid"], "type": kind]
            }
            check(OutlookCalendarToolPolicy.Creation(input: duplicate, backend: backend) == nil,
                  "\(backend) duplicate attendee address refuses across roles")
            var hidden = base; hidden[backend == .claude ? "showAs" : "show_as"] = "free"
            check(OutlookCalendarToolPolicy.Creation(input: hidden, backend: backend) == nil,
                  "\(backend) unreviewed availability settings refuse")
        }
        if let expected = OutlookCalendarActionEvidence.creationFromContent(content) {
            var value = event(start: "2026-09-15T09:00:00", end: "2026-09-15T09:15:00")
            value["subject"] = "Fixture appointment"; value["sensitivity"] = "private"; value["attendees"] = NSNull()
            value["body"] = ["contentType": "html", "content": "<html><head><style>.EmailQuote { margin: 1pt; }</style></head><body><div>Verification.</div></body></html>"]
            check(!rejects { try OutlookCalendarActionEvidence.verifyFields(value, id: "EVENT_FIXTURE", expected: expected, requiredSensitivity: "private") }, "native null attendees and generated HTML verify")
            check(rejects { try OutlookCalendarActionEvidence.verifyFields(value, id: "EVENT_FIXTURE", expected: expected, requiredSensitivity: "normal") }, "requested visibility must match read-back")
            value.removeValue(forKey: "attendees")
            check(rejects { try OutlookCalendarActionEvidence.verifyFields(value, id: "EVENT_FIXTURE", expected: expected) }, "missing attendees are not a verified empty set")
        }
        var unknown = event(); unknown.removeValue(forKey: "sensitivity")
        check((try? OutlookCalendarSource.Event(unknown).privateContent) == true, "unknown sensitivity cannot enter retained context")
        check(!rejects { _ = try OutlookCalendarSource.evidence(raw: trace(.claude, name: "outlook_calendar_search", arguments: searchArgs(.claude), values: [event()], total: 1), backend: .claude, purpose: .initial, window: window) }, "Claude terminal total-count metadata is accepted")
        let page1 = trace(.claude, name: "outlook_calendar_search", arguments: searchArgs(.claude), values: [event(id: "FIRST")], callID: "page1", next: 1)
        let page2 = trace(.claude, name: "outlook_calendar_search", arguments: searchArgs(.claude, offset: 1), values: [event(id: "SECOND")], callID: "page2", total: 2)
        check((try? OutlookCalendarSource.evidence(raw: page1 + "\n" + page2, backend: .claude, purpose: .initial, window: window).events.count) == 2, "returned nextOffset drives another page")
        check(OutlookCalendarActionEvidence.creationFromContent(content + "\nNotes: Duplicate") == nil, "duplicate event fields refuse")
        check(OutlookCalendarActionEvidence.creationFromContent(content.replacingOccurrences(of: "09:15", with: "08:15")) == nil, "end before start refuses")
        let mailCard = PreparedAction(title: "Reply to a pending message", method: .gmail, target: "", urgency: .high,
            dueDate: nil, status: .confirmed, verification: "", cardSummary: "", preparedContent: "Draft", executionRecipe: "Route",
            buttonText: "Send", detailLabel: "Draft", sources: [], reviewNote: "")
        var oldCalendar = mailCard; oldCalendar.calendarContextOnly = true
        let refreshed = ProactiveCycle.mergeCalendarOnly(ReadyResult(ready: [], dropped: []), existing: ReadyResult(ready: [mailCard], dropped: []))
        check(refreshed.ready.count == 1 && refreshed.ready[0].id == mailCard.id, "calendar-only quiet pass retains unrelated mail card")
        check(ProactiveCycle.mergeCalendarOnly(ReadyResult(ready: [], dropped: []), existing: ReadyResult(ready: [oldCalendar], dropped: [])).ready.isEmpty,
              "calendar-only contribution can retire without erasing unrelated cards")
        var edited = mailCard; edited.calendarOperation = .create; edited.preparedContent = "Changed"; edited.recipient = "new@example.invalid"
        check(edited.calendarOperation == .create && edited.connectorIdentity == mailCard.connectorIdentity,
              "value edits preserve connector operation metadata")
        let prior = CalendarContext.merge(google: "Original Google bytes\n", outlook: nil)
        check(prior.text == "Original Google bytes\n" && !prior.hasOutlookEvents, "no-Outlook merge preserves Google bytes")
        let unavailable = CalendarContext.Snapshot(status: .unavailable, events: [], window: window)
        check(CalendarContext.merge(google: "Google events", outlook: unavailable).text?.contains("Availability is unknown") == true, "one provider failure remains explicit")
        let services = [CommandRouter.Service(slug: "google-calendar", name: "Google Calendar", description: ""),
                        CommandRouter.Service(slug: slug, name: "Outlook Calendar", description: "")]
        check(CommandRouter.ambiguousCalendar("what is on my calendar Friday", services: services), "two unnamed calendars are ambiguous")
        check(!CommandRouter.ambiguousCalendar("check Outlook tomorrow", services: services), "explicit Outlook is unambiguous")
        check(CommandRouter.ambiguousCalendar("check Google and Outlook", services: services), "two providers cannot become one connector route")
        do {
            let windows = try MCPSource.windows(slug: slug, mode: .initial, since: nil, now: window.upper)
            check(windows.count == 12 && windows[0].upper == window.upper, "twelve months end at captured now")
            check(zip(windows, windows.dropFirst()).allSatisfy { $0.lower == $1.upper }, "monthly windows are contiguous")
            let schema = Schema([BucketPointer.self, CycleNote.self])
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
            let store = CycleStore(modelContainer: container)
            let first = try await MCPSource.run(slug: slug, mode: .initial, store: store, now: window.upper,
                reader: { _, _, _, _ in .quiet(itemCount: 0) })
            let mark = try await store.mcpCheckpoint(MCPSource.bucketKey(slug))
            check(first == 0 && mark?.mark.order == window.upper.timeIntervalSince1970, "quiet initial commits checkpoint")
            let counter = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await MCPSource.run(slug: slug, mode: .initial, store: store, now: window.upper.addingTimeInterval(60), reader: { _, _, _, _ in
                    let n = counter.withLock { $0 += 1; return $0 }
                    if n == 12 { throw MCPSource.MCPError.storageFailure }
                    return .quiet(itemCount: 0)
                })
                check(false, "last-window failure must throw")
            } catch { check(true, "last-window failure throws") }
            check(try await store.mcpCheckpoint(MCPSource.bucketKey(slug))?.mark.order == mark?.mark.order, "last-window failure preserves prior checkpoint")
        } catch { check(false, "orchestration fixtures: \(ErrorLabel(error))") }
        Log("Outlook Calendar fixtures: \(count) checks, \(failures) failures")
        if failures != 0 { exit(1) }
    }

    static func act() async {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let backend = ModelBackend.current
            let account = try await OutlookCalendarConnector.readIdentity()
            let reserve = root.appending(path: "create-reserved-\(backend.rawValue)")
            guard HostedToolPolicy.claim(reserve) else { Log("REFUSED: this engine's test creation is already reserved; inspect its original evidence"); exit(1) }
            let start = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 900) * 900 + 7_200)
            let end = start.addingTimeInterval(900)
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let title = "sentient-outlook-calendar-\(backend.rawValue)-\(UUID().uuidString.lowercased())"
            let content = "Title: \(title)\nStart: \(format.string(from: start))\nEnd: \(format.string(from: end))\nTime zone: UTC\nAttendees: \nLocation: \nNotes: Temporary connector verification event."
            let card = PreparedAction(title: "Outlook Calendar connector verification \(backend.rawValue)", method: .mcp, target: "Outlook Calendar",
                methodTarget: slug, connectorIdentity: account.fingerprint, calendarOperation: .create,
                urgency: .low, dueDate: nil, status: .confirmed, verification: "One no-attendee test appointment",
                cardSummary: "Create one temporary event.", preparedContent: content,
                executionRecipe: "Create exactly one event on the verified primary Outlook calendar using CONTENT. No attendees, resources, recurrence, invitations or online meeting.\(backend == .claude ? " Set sensitivity=private." : "") Read it back. Do not retry creation.",
                buttonText: "Create test event", detailLabel: "Event details", sources: [], reviewNote: "")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(card).write(to: root.appending(path: "create-card-\(backend.rawValue).json"), options: .atomic)
            let outcome = await ProactiveExecutor.shared.fire(card) { Log($0) }
            switch outcome {
            case .fired: Log("Calendar test event verified. Artifact: \(title)")
            case .failed(let reason), .notFireable(let reason): Log("Calendar test event unconfirmed: \(reason)"); exit(1)
            }
        } catch { Log("Calendar act failed: \(ErrorLabel(error))"); exit(1) }
    }

    static func context() async {
        do {
            let snapshot = try await CalendarContext.fetchOutlook()
            try snapshot.text.write(to: root.appending(path: "context-\(ModelBackend.current.rawValue).txt"), atomically: true, encoding: .utf8)
            Log("Calendar context: status=\(snapshot.status.rawValue), events=\(snapshot.events.count)")
            if snapshot.status == .unavailable { exit(1) }
        } catch { Log("Calendar context failed: \(ErrorLabel(error))"); exit(1) }
    }

    static func receipt() async {
        do {
            let backend = ModelBackend.current
            let card = try JSONDecoder().decode(PreparedAction.self, from: Data(contentsOf: root.appending(path: "create-card-\(backend.rawValue).json")))
            let path = ProcessInfo.processInfo.environment["LAB_TRACE_INPUT"] ?? root.appending(path: "create-\(backend == .claude ? "claude" : "codex").jsonl").path
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            let identity = try await OutlookCalendarConnector.readIdentity(trackUsage: false)
            guard identity.fingerprint == card.connectorIdentity else { throw MCPSource.MCPError.connectionChanged }
            try await OutlookCalendarActionEvidence.verify(raw: raw, backend: backend, operation: .create,
                identity: identity, intentHash: OutlookToolPolicy.hash(card.id))
            Log("Calendar original creation independently verified; no new creation attempted")
        } catch { Log("Calendar receipt failed: \(ErrorLabel(error))"); exit(1) }
    }

    static func policy() async {
        var recipes: [String: [String]] = [:]
        do {
            for backend in [ModelBackend.claude, .chatgpt] {
                try await ModelBackend.$runOverride.withValue(backend) {
                    for kind in ["read", "knowledge", "mixed", "create", "computer"] {
                        var inv = MCPSource.readInvocation(slug: slug, prompt: "Synthetic policy fixture")
                        inv.mcpReadToolNames = nil
                        if kind == "knowledge" {
                            inv.outlookCalendarReadPurpose = .initial; inv.outlookCalendarReadWindow = window
                        }
                        if kind == "mixed" { inv.mcpReadConnectors = ["outlook-mail", slug] }
                        if kind == "create" {
                            inv.mcpReadConnectors = []; inv.connectorOnlyRead = false
                            inv.mcpActionServer = slug; inv.outlookCalendarOperation = .create
                            inv.outlookCalendarAccountFingerprint = String(repeating: "a", count: 64)
                            inv.outlookCalendarIntentHash = String(repeating: "b", count: 64)
                        }
                        let args: [String]
                        if kind == "computer" {
                            args = backend == .claude
                                ? try ClaudeCLI.agentArguments(prompt: "Synthetic policy fixture", modelID: "sonnet", effortArg: "low", socketPath: "/tmp/calendar-fixture.sock")
                                : CodexCLI.agentArguments(prompt: "Synthetic policy fixture", imagePaths: [], modelID: "gpt-6-luna", effortArg: "low", socketPath: "/tmp/calendar-fixture.sock")
                        } else {
                            args = backend == .claude ? try ClaudeCLI.arguments(for: inv, modelID: "sonnet", effortArg: "low")
                                : try CodexCLI.arguments(for: inv, modelID: "gpt-6-luna", effortArg: "low", schemaFile: nil)
                        }
                        recipes["\(backend.rawValue)-\(kind)"] = args
                    }
                }
            }
            let data = try JSONEncoder().encode(recipes)
            try data.write(to: root.appending(path: "calendar-policy-argv.json"), options: .atomic)
            Log("Calendar native-policy argv exported")
        } catch { Log("Calendar policy export failed: \(ErrorLabel(error))"); exit(1) }
    }
}
#endif
