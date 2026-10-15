// Classifies explicitly failed native tool replies without retaining app content or error text.
// Shared by task diagnostics, early capture recovery, and the model-free health probe.
// Doc: Documentation - Diagnostics (Sentry & TelemetryDeck).md

import Foundation

nonisolated struct NativeComputerUseFailure: LocalizedError, Sendable, Equatable {
    enum Kind: String, Sendable { case capture, noWindows = "no_windows", permission, connection, unknown }
    let kind: Kind
    let code: Int?

    var errorDescription: String? {
        switch kind {
        case .capture:
            "Sidekick couldn’t capture the app’s window. Open Permissions & Health and choose Check app control, then try again."
        case .noWindows:
            "Sidekick couldn’t find a readable window. Keep the app open on your current desktop, then try again."
        case .permission:
            "Computer use could not access the app. Check its permissions in Permissions & Health."
        case .connection:
            "Computer use lost its connection. Finish active tasks, then restart computer use in Permissions & Health."
        case .unknown:
            "Computer use could not complete the check. Try again in Permissions & Health."
        }
    }

    static func from(item: [String: Any]) -> Self? {
        guard item["type"] as? String == "mcp_tool_call", item["server"] as? String == "sentient_native" else { return nil }
        let result = item["result"] as? [String: Any] ?? [:]
        let failed = item["status"] as? String == "failed" || item["error"] is String || item["error"] is [String: Any]
            || result["isError"] as? Bool == true || result["is_error"] as? Bool == true
        guard failed else { return nil }
        return classify(["error": item["error"] ?? [:], "message": result["error"] ?? "",
                         "content": result["content"] ?? [], "code": result["code"] ?? NSNull()])
    }

    /// Called only on a protocol-level error, never on successful app text or model narration.
    static func classify(_ value: Any) -> Self {
        var texts: [String] = []
        var code: Int?
        func read(_ value: Any, depth: Int) {
            guard depth < 3, texts.count < 8 else { return }
            if let string = value as? String { texts.append(String(string.prefix(2048))); return }
            guard let object = value as? [String: Any] else { return }
            code = code ?? (object["code"] as? Int)
            for key in ["message", "error"] { if let nested = object[key] { read(nested, depth: depth + 1) } }
            if let text = object["content"] as? String { texts.append(String(text.prefix(2048))) }
            if let blocks = object["content"] as? [[String: Any]] {
                for block in blocks.prefix(4) where block["type"] as? String == "text" {
                    if let text = block["text"] as? String { texts.append(String(text.prefix(2048))) }
                }
            }
        }
        read(value, depth: 0)
        let text = String(texts.joined(separator: "\n").prefix(8192))
        if let range = text.range(of: #"(?m)^Computer Use server error (-?[0-9]{1,8}):"#, options: .regularExpression) {
            code = Int(text[range].dropFirst("Computer Use server error ".count).dropLast())
        }
        let lower = text.lowercased()
        let kind: Kind
        if lower.contains("nowindowsavailable") { kind = .noWindows }
        else if ["screenshotcapturefailed", "screencapturefailed", "unknowncapturefailed", "screenshot_capture_failed",
                 "screen capture failed", "screenshot capture failed"].contains(where: lower.contains) { kind = .capture }
        else if ["permission", "not authorized", "accessibility"].contains(where: lower.contains) { kind = .permission }
        else if ["connection", "disconnected"].contains(where: lower.contains) { kind = .connection }
        else { kind = .unknown }
        return Self(kind: kind, code: code)
    }
}
