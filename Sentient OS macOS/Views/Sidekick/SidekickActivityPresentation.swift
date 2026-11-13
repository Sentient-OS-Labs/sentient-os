// Human labels for saved activity. This is a presentation-only projection: no commands,
// tool results, app discovery or external lookups are executed here.
import Foundation

nonisolated enum SidekickActivityPresentation {
    struct Step: Identifiable, Sendable {
        let id: String
        let firstSequence: Int64
        let record: SidekickConversationStore.Record
        let title: String
        let symbol: String
        let appName: String?
        let appIdentifier: String?
    }

    struct NotchStatus {
        let text: String
        let activity: Step?
    }

    /// All provider adapters feed this presentation. Keep authored narration intact;
    /// tool/search/command signals use the same title and icon identity as chat.
    static func notchStatus(_ status: String, activity: Step?) -> NotchStatus {
        let last = status.split(separator: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = last.hasPrefix("$")
        let search = last.hasPrefix("🔎")
        let tool = rawTool(in: last)
        if tool != nil || last.hasPrefix("→") || command || search {
            let fallback = tool.map { label(ToolName($0), arguments: [:], app: nil).title }
                ?? (command ? "Running a command" : search ? "Searching the web" : "Working…")
            return NotchStatus(text: activity?.title ?? fallback, activity: activity)
        }
        // Status is a rolling log: only the newest human line belongs in the UI.
        return NotchStatus(text: last.isEmpty ? "Working…" : last, activity: nil)
    }

    private static func rawTool(in line: String) -> String? {
        let candidate = line.hasPrefix("→") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
        let token = candidate.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first.map(String.init) ?? ""
        return token.hasPrefix("sentient_") || token.hasPrefix("mcp__") ? token : nil
    }

    static func islandSubtitle(_ status: String, activity: Step?) -> String {
        let last = status.split(separator: "\n").last.map(String.init) ?? ""
        if rawTool(in: last.trimmingCharacters(in: .whitespaces)) != nil || last.trimmingCharacters(in: .whitespaces).hasPrefix("→") {
            if let activity { return islandAction(activity) }
        }
        return notchStatus(status, activity: nil).text
    }

    /// Fixed-width processing wings use a short action category. Completed tools yield
    /// back to the model's thinking state, so their app icon cannot linger as live work.
    static func compactNotchStatus(_ status: String, activity: Step?) -> NotchStatus {
        let presented = notchStatus(status, activity: activity)
        if let step = presented.activity, let operation = step.record.event.activity {
            guard operation.status == .started else { return NotchStatus(text: "Thinking", activity: nil) }
            let category = label(ToolName(operation.name), arguments: arguments(operation.arguments), app: nil).title
            let verb = category.split(separator: " ").first.map(String.init) ?? "Working"
            let short = ["Entering": "Typing", "Looking": "Reading", "Using": "Working",
                         "Continuing": "Running", "Used": "Working", "Asking": "Waiting"][verb] ?? verb
            return NotchStatus(text: short, activity: step)
        }
        if status.localizedCaseInsensitiveContains("offline") { return NotchStatus(text: "Offline", activity: nil) }
        let last = presented.text.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces) ?? ""
        let first = last.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: .punctuationCharacters) ?? ""
        let short = ["Preparing": "Starting", "Starting": "Starting",
                     "Stopping": "Stopping", "Waiting": "Waiting", "Retrying": "Retrying",
                     "Connecting": "Linking", "Reconnecting": "Linking", "Reading": "Reading",
                     "Running": "Running", "Searching": "Searching", "Working": "Working"][first] ?? "Thinking"
        return NotchStatus(text: short, activity: nil)
    }

    static func steps(_ records: [SidekickConversationStore.Record]) -> [Step] {
        var grouped: [String: (first: Int64, latest: SidekickConversationStore.Record)] = [:]
        for record in records {
            guard record.event.kind == .activity, let activity = record.event.activity,
                  !hidden(ToolName(activity.name)) else { continue }
            // The stored tool ID includes its provider-stream identity. Preserve all of it;
            // task scope also protects imported activity that predates stream-scoped IDs.
            let id = record.event.taskID.uuidString + ":" + activity.toolID
            if let previous = grouped[id] {
                let newer = record.sequence > previous.latest.sequence
                    || (record.sequence == previous.latest.sequence && record.event.id > previous.latest.event.id)
                grouped[id] = (min(previous.first, record.sequence), newer ? record : previous.latest)
            } else { grouped[id] = (record.sequence, record) }
        }
        return grouped.map { id, value in
            let activity = value.latest.event.activity!
            let tool = ToolName(activity.name)
            let arguments = arguments(activity.arguments)
            let app = application(arguments)
            let label = label(tool, arguments: arguments, app: app?.name)
            let title = suppliedTitle(arguments) ?? label.title
            return Step(id: id, firstSequence: value.first, record: value.latest,
                        title: title, symbol: label.symbol, appName: app?.name, appIdentifier: app?.identifier)
        }.sorted { $0.firstSequence == $1.firstSequence ? $0.id < $1.id : $0.firstSequence < $1.firstSequence }
    }

    /// Short second line under an app name in the floating working island.
    static func islandAction(_ step: Step) -> String {
        guard let activity = step.record.event.activity else { return step.title }
        guard activity.status == .started else { return "Thinking…" }
        switch ToolName(activity.name).leaf {
        case "get_app_state": return "Looking around"
        case "click", "double_click", "right_click", "perform_secondary_action": return "Clicking"
        case "type_text", "set_value": return "Entering text"
        case "select_text": return "Selecting text"
        case "press_key": return "Using the keyboard"
        case "scroll": return "Scrolling"
        case "drag": return "Dragging"
        case "open_app", "launch_app", "activate_app": return "Opening app"
        default: return step.title
        }
    }

    private struct ToolName {
        let parts: [String]
        var leaf: String { parts.last ?? "" }
        init(_ name: String) {
            parts = name.lowercased().replacingOccurrences(of: "__", with: ".")
                .split(separator: ".").map(String.init)
        }
        var native: Bool { parts.contains("sentient_native") }
        var browser: Bool { parts.contains(where: { ["browser", "playwright", "puppeteer"].contains($0) }) || leaf.hasPrefix("browser_") }
    }

    private static func hidden(_ tool: ToolName) -> Bool {
        if tool.parts.contains(where: { ["sentient_relay", "relay", "sentient_telemetry", "telemetry"].contains($0) }) { return true }
        return ["describe_task_usage", "message_user", "read_history", "search_history", "structuredoutput",
                "record_telemetry", "send_telemetry", "submit_telemetry"].contains(tool.leaf)
    }

    private static func arguments(_ raw: String?) -> [String: Any] {
        guard let raw, raw.utf8.count <= 32_768, let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data), let map = value as? [String: Any] else { return [:] }
        return map
    }

    private static func suppliedTitle(_ arguments: [String: Any]) -> String? {
        for key in ["title", "description"] {
            guard let raw = arguments[key] as? String else { continue }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawTool(in: value) == nil, !value.hasPrefix("→"), !value.isEmpty, value.count <= 120, value.utf8.count <= 512,
                  !hasControls(value), !looksSensitive(value) else { continue }
            return value
        }
        return nil
    }

    private static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .control
            || CharacterSet.newlines.contains($0) || (0x202A...0x202E).contains($0.value)
            || (0x2066...0x2069).contains($0.value) }
    }

    private static func looksSensitive(_ value: String) -> Bool {
        let patterns = [
            #"(?i)\b(?:authorization|bearer|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|passwd|client[_ -]?secret|private[_ -]?key|cookie|credential)\b"#,
            #"(?i)\b(?:token|secret)\s*[:=]"#,
            #"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b"#,
            #"(?i)\[(?:redacted|omitted)\]|-----BEGIN|[a-z][a-z0-9+.-]*://[^\s]*[?@]|data:[^\s]*;base64,"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    private struct App {
        let name: String?
        let identifier: String?
    }
    private static let knownApps: [String: (name: String, identifier: String)] = [
        "com.spotify.client": ("Spotify", "com.spotify.client"),
        "net.whatsapp.whatsapp": ("WhatsApp", "net.whatsapp.WhatsApp"),
        "com.apple.safari": ("Safari", "com.apple.Safari"),
        "com.google.chrome": ("Google Chrome", "com.google.Chrome"),
        "com.microsoft.edgemac": ("Microsoft Edge", "com.microsoft.edgemac"),
        "com.microsoft.word": ("Microsoft Word", "com.microsoft.Word"),
        "com.microsoft.excel": ("Microsoft Excel", "com.microsoft.Excel"),
        "com.pixelmatorteam.pixelmator.x": ("Pixelmator Pro", "com.pixelmatorteam.pixelmator.x"),
        "com.apple.mail": ("Mail", "com.apple.mail"),
        "com.apple.mobilesms": ("Messages", "com.apple.MobileSMS"),
        "com.apple.notes": ("Notes", "com.apple.Notes"),
        "com.apple.finder": ("Finder", "com.apple.finder"),
        "com.apple.ical": ("Calendar", "com.apple.iCal"),
        "com.apple.reminders": ("Reminders", "com.apple.reminders"),
        "com.apple.systempreferences": ("System Settings", "com.apple.systempreferences"),
        "com.apple.terminal": ("Terminal", "com.apple.Terminal"),
        "com.microsoft.vscode": ("Visual Studio Code", "com.microsoft.VSCode"),
        "com.tinyspeck.slackmacgap": ("Slack", "com.tinyspeck.slackmacgap"),
        "com.hnc.discord": ("Discord", "com.hnc.Discord")
    ]
    private static let appKeys = ["app", "application", "app_name", "appName", "bundle_id", "bundleIdentifier",
                                  "app_identifier", "appIdentifier", "app_path", "appPath"]

    private static func application(_ arguments: [String: Any]) -> App? {
        for key in appKeys {
            if let value = arguments[key] as? String, let app = application(value) { return app }
            if let nested = arguments[key] as? [String: Any] {
                for nestedKey in ["bundle_id", "bundleIdentifier", "identifier", "path", "name"] {
                    if let value = nested[nestedKey] as? String, let app = application(value) { return app }
                }
            }
        }
        return nil
    }

    private static func application(_ raw: String) -> App? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1_024, !hasControls(value), !looksSensitive(value) else { return nil }
        if let known = knownApps[value.lowercased()] { return App(name: known.name, identifier: known.identifier) }
        if value.range(of: #"^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil {
            // An unfamiliar bundle ID is useful for a caller's optional icon lookup, but
            // does not become an invented product name in the main activity label.
            return App(name: nil, identifier: value)
        }
        let name: String
        let identifier: String?
        if value.lowercased().hasSuffix(".app") {
            name = ((value as NSString).lastPathComponent as NSString).deletingPathExtension
            identifier = value
        } else {
            guard !value.contains("/"), !value.contains("\\"), !value.contains(":"),
                  !value.contains("="), !value.contains("{") else { return nil }
            name = value; identifier = nil
        }
        guard !name.isEmpty, name.count <= 64, name.utf8.count <= 256 else { return nil }
        if let known = knownApps.values.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return App(name: known.name, identifier: known.identifier)
        }
        return App(name: name, identifier: identifier)
    }

    private static func label(_ tool: ToolName, arguments: [String: Any], app: String?) -> (title: String, symbol: String) {
        func inApp(_ action: String) -> String { app.map { action + " in " + $0 } ?? action }
        if tool.native {
            switch tool.leaf {
            case "get_app_state": return (app.map { "Looking at " + $0 } ?? "Looking at an app", "macwindow")
            case "diagnose_computer_use": return ("Checking computer use", "stethoscope")
            case "get_desktop_state", "list_apps": return ("Looking at your Mac", "desktopcomputer")
            case "click", "double_click", "right_click", "perform_secondary_action": return (inApp("Clicking"), "cursorarrow")
            case "type_text", "set_value": return (inApp("Entering text"), "keyboard")
            case "select_text": return (inApp("Selecting text"), "text.cursor")
            case "press_key": return (inApp("Using the keyboard"), "keyboard")
            case "scroll": return (inApp("Scrolling"), "arrow.up.and.down")
            case "drag": return (inApp("Dragging"), "hand.draw")
            case "open_app", "launch_app", "activate_app": return (app.map { "Opening " + $0 } ?? "Opening an app", "macwindow")
            default: return (app.map { "Using " + $0 } ?? "Using an app", "macwindow")
            }
        }
        if tool.browser {
            let name = tool.leaf.hasPrefix("browser_") ? String(tool.leaf.dropFirst(8)) : tool.leaf
            switch name {
            case "navigate", "open", "goto": return ("Opening a webpage", "globe")
            case "click", "double_click": return ("Clicking on a webpage", "cursorarrow")
            case "type", "type_text", "fill", "fill_form": return ("Entering text on a webpage", "keyboard")
            case "snapshot", "get_dom", "screenshot": return ("Looking at a webpage", "globe")
            case "scroll": return ("Scrolling a webpage", "arrow.up.and.down")
            case "search": return ("Searching the web", "magnifyingglass")
            default: return ("Using the browser", "globe")
            }
        }
        if ["web_search", "search_query", "websearch"].contains(tool.leaf)
            || (tool.parts.contains("web") && arguments["search_query"] != nil) {
            return ("Searching the web", "magnifyingglass")
        }
        if tool.parts.contains("web") { return ("Reading a webpage", "globe") }
        switch tool.leaf {
        case "bash", "command_execution", "exec_command", "shell_command", "shell": return ("Running a command", "terminal")
        case "write_stdin": return ("Continuing a command", "terminal")
        case "js", "python", "exec", "execute_code", "run_code": return ("Running code", "terminal")
        case "read_file": return ("Reading a file", "doc.text")
        case "edit_file", "apply_patch": return ("Editing a file", "square.and.pencil")
        case "write_file": return ("Writing a file", "doc.badge.plus")
        case "read" where tool.parts.count == 1: return ("Reading a file", "doc.text")
        case "edit" where tool.parts.count == 1: return ("Editing a file", "square.and.pencil")
        case "write" where tool.parts.count == 1: return ("Writing a file", "doc.badge.plus")
        case "read_memory", "get_memory": return ("Reading Sidekick memory", "brain")
        case "update_memory", "write_memory", "edit_memory": return ("Updating Sidekick memory", "brain")
        case "search_knowledge", "search_knowledge_base", "search_kb": return ("Searching your knowledge base", "books.vertical")
        case "read_knowledge", "read_knowledge_base", "read_kb": return ("Reading your knowledge base", "books.vertical")
        case "update_knowledge", "update_knowledge_base", "write_kb": return ("Updating your knowledge base", "books.vertical")
        case "ask_user": return ("Asking a question", "questionmark.bubble")
        default: return ("Used a tool", "gearshape")
        }
    }
}
