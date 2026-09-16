#if DEBUG
//
// OutlookCalendarProactiveTests.swift
// Exercises calendar-only judging on synthetic input, and live research over the one known
// disposable event. Neither path persists cards or writes to the user's knowledge base.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
//

import Foundation

enum OutlookCalendarProactiveTests {
    static func judge() async {
        do {
            let now = Date()
            let window = MCPSource.Window(lower: now.addingTimeInterval(-604_800), upper: now.addingTimeInterval(86_400), label: "fixture")
            let start = MCPSource.timestamp(now.addingTimeInterval(7_200)), end = MCPSource.timestamp(now.addingTimeInterval(10_800))
            let event = try OutlookCalendarSource.Event(["id": "INTERVIEW_FIXTURE", "subject": "Final interview for a design lead role",
                "start": ["dateTime": start, "timeZone": "UTC"], "end": ["dateTime": end, "timeZone": "UTC"],
                "sensitivity": "normal", "showAs": "busy", "responseStatus": ["response": "accepted"],
                "webLink": "https://outlook.office.com/calendar/item/INTERVIEW_FIXTURE"])
            let context = CalendarContext.Snapshot(status: .complete, events: [event], window: window)
            let before = UserDefaults.standard.data(forKey: "proactive.latestActionItems")
            let items = try await Proactive.shared.findActionItems(from: [], now: now, calendarContext: context.text,
                allowCalendarOnly: true, calendarContextScoped: true, persistResult: false)
            guard !items.isEmpty, UserDefaults.standard.data(forKey: "proactive.latestActionItems") == before else {
                throw OutlookCalendarSource.invalid("calendar_only_judge")
            }
            let output = try ConnectorReadAudit.outputDirectory()
            try JSONEncoder().encode(items).write(to: output.appending(path: "synthetic-judge.json"), options: .atomic)
            Log("Calendar-only synthetic judge: \(items.count) candidate(s), no summaries, no persisted changes")
        } catch { Log("Calendar-only judge failed: \(ErrorLabel(error))"); exit(1) }
    }

    static func research() async {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        do {
            guard ProcessInfo.processInfo.environment["SENTIENT_VAULT_ROOT"] != nil else {
                throw OutlookCalendarSource.invalid("isolated_vault_required")
            }
            var domain = saved
            for source in ConnectorRegistry.detectedForCurrentBackend() { domain[ConnectorRegistry.kbKey(source.slug)] = false }
            domain[ConnectorRegistry.kbKey(OutlookCalendarConnector.slug)] = true
            domain["dbg.gmail.connected"] = false; domain["dbg.calendar.connected"] = false
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            let snapshot = try await CalendarContext.fetchOutlook()
            guard let event = snapshot.events.first(where: { $0.subject.hasPrefix("sentient-outlook-calendar-") }),
                  let reference = event.reference else { throw OutlookCalendarSource.invalid("test_event_not_visible") }
            let before = defaults.data(forKey: "proactive.latestReady")
            let item = ActionItem(title: "Verify the temporary Outlook Calendar appointment",
                action: "Read only the existing temporary event \(reference) and prepare a short research briefing confirming its title and UTC start/end. Do not create or change anything. Do not search the web or inspect unrelated events.",
                importance: "The user requested connector verification. This is a disposable test event, and the existing event must be read back through Outlook Calendar.",
                dueDate: nil, sources: [reference], urgency: .low)
            let result = try await ProactiveResearch.shared.researchAndPrepare(items: [item], notes: [],
                calendarContext: snapshot.text, calendarContextScoped: true, persistResult: false)
            guard result.ready.allSatisfy({ $0.method == .research }), defaults.data(forKey: "proactive.latestReady") == before,
                  let path = ProcessInfo.processInfo.environment["LAB_TRACE_OUTPUT"] else { throw OutlookCalendarSource.invalid("research_state") }
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            let calls = MCPCallEvidence.receipts(raw: raw, backend: ModelBackend.current)
            guard calls.contains(where: { call in
                let name = OutlookCalendarConnector.bareName(call, backend: ModelBackend.current)
                guard call.status == .succeeded, ["read_resource", "fetch_event"].contains(name ?? ""),
                      let input = OutlookMailConnector.object(call.arguments) else { return false }
                return input["event_id"] as? String == event.id
                    || (input["uri"] as? String).flatMap(OutlookCalendarConnector.eventID) == event.id
            }) else { throw OutlookCalendarSource.invalid("research_native_read") }
            let prompt = try String(contentsOfFile: path + ".prompt.txt", encoding: .utf8)
            guard prompt.contains(snapshot.text), prompt.contains(reference), prompt.contains("LIVE CALENDAR CONTEXT") else {
                throw OutlookCalendarSource.invalid("research_context")
            }
            let output = try ConnectorReadAudit.outputDirectory()
            try JSONEncoder().encode(result).write(to: output.appending(path: "research-result.json"), options: .atomic)
            Log("Live Outlook research: context present, exact event read, no mutations or persisted cards")
        } catch { Log("Live Outlook research failed: \(ErrorLabel(error))"); exit(1) }
    }
}
#endif
