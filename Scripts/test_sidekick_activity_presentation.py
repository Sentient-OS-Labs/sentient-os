#!/usr/bin/env python3
"""Compile the complete activity presentation helper with production Store types.

All input is synthetic records in memory. No app lookup, I/O by the helper, provider calls,
production preferences, credentials, network or external diagnostics sinks.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import Foundation

typealias Store = SidekickConversationStore
typealias Event = SidekickConversationEvent
typealias Presentation = SidekickActivityPresentation

@main enum ActivityPresentationTests {
    static var checks = 0
    static let taskID = UUID()
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        checks += 1
    }
    static func record(_ name: String, sequence: Int64 = 1, toolID: String = "stream-a:item_0",
                       task: UUID = taskID, status: Event.Activity.Status = .started,
                       arguments: String? = nil, result: String? = nil) -> Store.Record {
        .init(sequence: sequence, event: Event(id: "event:\(task):\(sequence)", taskID: task, kind: .activity,
            text: name, activity: .init(toolID: toolID, name: name, arguments: arguments, result: result, status: status)))
    }
    static func one(_ name: String, args: String? = nil, result: String? = nil) -> Presentation.Step {
        let values = Presentation.steps([record(name, arguments: args, result: result)])
        guard values.count == 1 else { fatalError("expected one visible step: " + name) }
        return values[0]
    }
    static func json(_ value: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), encoding: .utf8)!
    }

    static func main() async {
        let started = record("sentient_native.get_app_state", sequence: 2, arguments: #"{"app":"com.apple.Safari"}"#)
        let other = record("Bash", sequence: 3, toolID: "stream-a:item_1", arguments: "echo fixture")
        let ended = record("sentient_native.get_app_state", sequence: 8, status: .completed,
            arguments: #"{"app":"com.apple.Safari"}"#, result: "SYNTHETIC_RESULT_MUST_NOT_BECOME_A_TITLE")
        let values = Presentation.steps([ended, other, started])
        check(values.count == 2, "started/terminal events coalesce into one observed operation")
        check(values[0].firstSequence == 2 && values[1].firstSequence == 3,
              "steps remain in first-observed order instead of completion order")
        check(values[0].record == ended && values[0].record.event.activity?.status == .completed,
              "latest exact source record and terminal status are retained")
        check(values[0].title == "Looking at Safari" && values[0].symbol == "macwindow",
              "native tool ID becomes a readable action with an app")
        check(!values[0].title.contains("SYNTHETIC_RESULT"), "tool output is never a summary label")
        check(values[0].record.event.activity?.result == "SYNTHETIC_RESULT_MUST_NOT_BECOME_A_TITLE",
              "explicit details retain the original result unchanged")
        let streamB = record("Bash", sequence: 4, toolID: "stream-b:item_0")
        check(Presentation.steps([started, ended, streamB]).count == 2, "same provider item number in distinct streams stays distinct")
        let anotherTask = record("Bash", sequence: 5, task: UUID())
        check(Presentation.steps([started, anotherTask]).count == 2, "legacy reused tool IDs in separate tasks cannot collapse")
        let failed = record("Bash", sequence: 10, status: .failed, arguments: "rm fixture", result: "error")
        let interrupted = record("Bash", sequence: 11, toolID: "stream-z:item_2", status: .interrupted)
        let endings = Presentation.steps([failed, interrupted])
        check(endings.map { $0.record.event.activity!.status } == [.failed, .interrupted], "failed and interrupted outcomes are preserved")
        check(endings.allSatisfy { $0.title == "Running a command" }, "action descriptions do not invent successful outcomes")
        let nonActivity = Store.Record(sequence: 9, event: Event(taskID: taskID, kind: .assistantMessage, text: "Visible reply"))
        check(Presentation.steps([nonActivity]).isEmpty, "message content is not duplicated as work activity")
        check(Presentation.steps([]).isEmpty, "empty input is harmless")

        for hidden in ["sentient_recovery.describe_task_usage", "mcp__sentient_recovery__describe_task_usage",
                       "message_user", "sentient_recovery.read_history", "mcp__sentient_recovery__search_history",
                       "StructuredOutput", "provider.StructuredOutput", "mcp__sentient_relay__call",
                       "sentient_relay.invoke", "relay.forward", "telemetry.report", "sentient_telemetry.record",
                       "send_telemetry", "record_telemetry"] {
            check(Presentation.steps([record(hidden)]).isEmpty, "bookkeeping hidden: " + hidden)
        }
        for (name, expected) in [
            ("sentient_native.click", "Clicking"), ("mcp__sentient_native__double_click", "Clicking"),
            ("sentient_native.perform_secondary_action", "Clicking"), ("sentient_native.set_value", "Entering text"),
            ("mcp__sentient_native__type_text", "Entering text"), ("sentient_native.press_key", "Using the keyboard"),
            ("sentient_native.select_text", "Selecting text"), ("sentient_native.scroll", "Scrolling"),
            ("sentient_native.drag", "Dragging"), ("sentient_native.list_apps", "Looking at your Mac"),
            ("browser.browser_navigate", "Opening a webpage"), ("mcp__playwright__browser_click", "Clicking on a webpage"),
            ("browser.fill_form", "Entering text on a webpage"), ("browser.snapshot", "Looking at a webpage"),
            ("web_search", "Searching the web"), ("WebSearch", "Searching the web"),
            ("functions.exec_command", "Running a command"), ("command_execution", "Running a command"),
            ("functions.write_stdin", "Continuing a command"), ("mcp__node_repl__js", "Running code"),
            ("Read", "Reading a file"), ("Edit", "Editing a file"), ("Write", "Writing a file"),
            ("functions.apply_patch", "Editing a file"), ("sentient_memory.read_memory", "Reading Sidekick memory"),
            ("sentient_memory.update_memory", "Updating Sidekick memory"),
            ("sentient_knowledge.search_knowledge_base", "Searching your knowledge base"),
            ("sentient_knowledge.update_knowledge_base", "Updating your knowledge base"),
            ("mcp__sentient_recovery__ask_user", "Asking a question")
        ] {
            check(one(name).title == expected, "human label for " + name)
        }
        check(one("web.run", args: #"{"search_query":[{"q":"fixture"}]}"#).title == "Searching the web",
              "structured web search category is recognized")
        check(one("web.open").title == "Reading a webpage", "web reading has a neutral action label")
        check(one("vendor.unknown_tool").title == "Used a tool", "unknown tool uses safe generic label")
        check(one("mcp__database__read").title == "Used a tool", "unrelated read tool is not mislabeled as file access")

        let safari = one("sentient_native.click", args: #"{"app":"com.apple.Safari"}"#)
        check(safari.appName == "Safari" && safari.appIdentifier == "com.apple.Safari", "bundle selector maps to known friendly app and identifier")
        let chrome = one("mcp__sentient_native__set_value", args: #"{"app":"/Applications/Google Chrome.app"}"#)
        check(chrome.title == "Entering text in Google Chrome" && chrome.appIdentifier == "com.google.Chrome",
              "app path becomes friendly name rather than a full filesystem path")
        let notes = one("sentient_native.get_app_state", args: #"{"application":{"bundle_id":"com.apple.Notes"}}"#)
        check(notes.appName == "Notes" && notes.title == "Looking at Notes", "structured app selector is supported")
        let plain = one("sentient_native.scroll", args: #"{"app_name":"Safari"}"#)
        check(plain.appName == "Safari" && plain.appIdentifier == "com.apple.Safari", "plain known app name resolves without external lookup")
        let unicodePath = "/Users/fixture/Applications/Café 编辑器.app"
        let unicode = one("sentient_native.get_app_state", args: json(["app": unicodePath]))
        check(unicode.appName == "Café 编辑器" && unicode.appIdentifier == unicodePath,
              "Unicode app basename is preserved without filesystem access")
        let unknownID = one("sentient_native.get_app_state", args: #"{"app":"org.fixture.unknown"}"#)
        check(unknownID.appName == nil && unknownID.appIdentifier == "org.fixture.unknown" && unknownID.title == "Looking at an app",
              "unknown bundle identifier does not become an invented app name")
        check(one("Bash", args: "osascript -e 'tell application \"Safari\" to activate'").appName == nil,
              "literal shell code does not imply an observed app action")
        check(one("Bash", args: #"{"command":"open -a Safari"}"#).title == "Running a command",
              "structured shell command is not guessed to be native computer use")

        let described = one("Bash", args: #"{"description":"Find matching project files","command":"rg fixture"}"#)
        check(described.title == "Find matching project files" && described.symbol == "terminal", "short supplied description improves command label")
        check(one("sentient_native.click", args: #"{"title":"Open the calendar","description":"Fallback description","app":"Calendar"}"#).title == "Open the calendar",
              "safe title takes precedence over description")
        check(one("Bash", args: json(["title": "检查日历 👩🏽‍💻"])).title == "检查日历 👩🏽‍💻", "Unicode title is preserved")
        check(one("Bash", args: json(["title": String(repeating: "x", count: 121)])).title == "Running a command",
              "long title is replaced with a bounded category")
        for suspicious in ["Authorization: fixture", "Bearer fixture-secret", "password=fixture",
                           "API key fixture", "access_token=fixture", "ghp_abcdefghijklmnop", "sk-proj-abcdefghijklmnop",
                           "https://fixture.invalid/?token=fixture", "[redacted]", "line one\nline two", "safe\u{202E}hidden"] {
            check(one("Bash", args: json(["title": suspicious])).title == "Running a command",
                  "sensitive/control-looking title falls back without exposing content")
        }
        check(one("Bash", args: #"{"title":"password=fixture","description":"Check the project"}"#).title == "Check the project",
              "rejected title can fall back to a safe supplied description")
        for malformed in [nil, "", "not JSON", "{broken", "[]", "42", #"{"title":42,"app":false}"#, String(repeating: "x", count: 32_769)] as [String?] {
            let step = one("sentient_native.get_app_state", args: malformed)
            check(step.title == "Looking at an app" && step.appName == nil, "malformed or oversized arguments have safe fallback")
        }
        check(one("sentient_native.type_text", args: #"{"app":"password=fixture","text":"SYNTHETIC_PRIVATE_TEXT"}"#).title == "Entering text",
              "suspicious app selector and entered text never become action label")
        let all = Presentation.steps([started, ended, other, failed, streamB, interrupted])
        check(all.allSatisfy { $0.title.count <= 120 }, "all generated titles respect display bound")
        check(Set(all.map(\.id)).count == all.count, "projection supplies stable unique SwiftUI identities")
        let background = await Task.detached { Presentation.steps([ended, other, started]) }.value
        check(background.map(\.title) == values.map(\.title) && background.map(\.record) == values.map(\.record),
              "pure Sendable projection is safe off the main actor")
        print("PASS: \(checks) Sidekick activity presentation checks")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="sentient-activity-presentation-test-") as temporary:
        directory = Path(temporary)
        fixture = directory / "ActivityPresentationTests.swift"
        fixture.write_text(FIXTURE)
        executable = directory / "activity-presentation-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
            "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
            str(APP / "Notch Magic/SidekickConversationStore.swift"),
            str(APP / "Views/Sidekick/SidekickActivityPresentation.swift"), str(fixture),
            "-o", str(executable),
        ], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=20)


if __name__ == "__main__":
    main()
