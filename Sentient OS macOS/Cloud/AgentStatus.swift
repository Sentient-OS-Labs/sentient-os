// Final task-status parsing shared by Sidekick, proactive actions and connector runs.
// Completion requires an exact final sentinel; missing or malformed status stays unconfirmed.
// Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation

nonisolated enum AgentStatus {
    case done                      // STATUS: DONE — the agent claims it completed the task
    case couldNot(reason: String)  // STATUS: COULD_NOT — it cleanly gave up (reason may be empty)
    case none                      // no sentinel in the reply (legacy prompt / the model forgot)

    static let unconfirmedConnectorMessage = "Completion could not be confirmed. Check the service before trying again."

    /// Structured connector replies have no echoed transcript. Require the final nonempty
    /// line to contain the exact sentinel, so "NOT DONE" or quoted earlier output cannot pass.
    static func parseConnector(_ reply: String) -> AgentStatus {
        guard let final = reply.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty }),
              final.range(of: #"^STATUS:\s*(DONE|COULD_NOT)(?:\s*[-:—–]\s*.*)?$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil else { return .none }
        let value = final.dropFirst("STATUS:".count).trimmingCharacters(in: .whitespaces)
        return value.uppercased().hasPrefix("DONE") ? .done : .couldNot(reason: reason(of: final))
    }

    /// Computer tasks return the CLI's final message. Only its final nonempty line may assert
    /// completion; quoted output, prompt echoes and "NOT DONE" cannot become successful actions.
    static func parse(_ reply: String) -> AgentStatus {
        let parsed = parseConnector(reply)
        if case .none = parsed {
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("COULD NOT") {
                return .couldNot(reason: String(String(trimmed.dropFirst("COULD NOT".count))
                    .trimmingCharacters(in: trimSet).prefix(300)))
            }
        }
        return parsed
    }

    static let unconfirmedComputerMessage = "Completion could not be confirmed. Check the app before trying again."

    /// The display-ready text after the marker on a `STATUS: COULD_NOT — <reason>` line.
    private static func reason(of line: String) -> String {
        guard let r = line.range(of: "COULD_NOT", options: [.backwards, .caseInsensitive]) else { return "" }
        return String(String(line[r.upperBound...]).trimmingCharacters(in: trimSet).prefix(300))
    }

    /// Strips the sentinel's separators/backticks around the reason (em/en dashes, colons, ticks).
    private static let trimSet = CharacterSet(charactersIn: " `—–:-.\n\t")
}
