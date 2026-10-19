// Final task-status parsing shared by Sidekick, proactive actions and connector runs.
// Completion requires an explicit structured answer outcome or exact final sentinel, after a clean provider exit.
// Doc: Cloud/Documentation - Cloud - CodexCLI (the codex exec spine).md

import Foundation

nonisolated enum AgentStatus: Equatable, Sendable {
    /// Wire values belong to message_user's final answer, not ordinary progress text.
    enum Completion: String, Sendable { case done; case couldNot = "could_not" }

    /// A saved answer is not inherently successful. Only its explicit completion claim or a
    /// legacy final sentinel can establish an outcome, and neither overrides a failed run.
    /// Failure claims win contradictions rather than letting an earlier DONE mask a refusal.
    static func resolve(_ reply: String, completion: AgentStatus?, providerSucceeded: Bool,
                        connector: Bool = false) -> AgentStatus {
        guard providerSucceeded else { return .none }
        let final = connector ? parseConnector(reply) : parse(reply)
        if case .couldNot = final { return final }
        if let completion, case .couldNot = completion { return completion }
        if case .done = final { return .done }
        if let completion, case .done = completion { return .done }
        return .none
    }

    case done                      // STATUS: DONE — the agent claims it completed the task
    case couldNot(reason: String)  // STATUS: COULD_NOT — it cleanly gave up (reason may be empty)
    case none                      // neither source supplies current explicit completion

    static let unconfirmedConnectorMessage = "Sidekick finished without confirming the outcome. Check the service before repeating the action."

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
                    .trimmingCharacters(in: trimSet)))
            }
        }
        return parsed
    }

    static let unconfirmedComputerMessage = "Sidekick finished without confirming the outcome. Check the app before repeating the action."

    /// The display-ready text after the marker on a `STATUS: COULD_NOT — <reason>` line.
    private static func reason(of line: String) -> String {
        guard let r = line.range(of: "COULD_NOT", options: [.backwards, .caseInsensitive]) else { return "" }
        return String(line[r.upperBound...]).trimmingCharacters(in: trimSet)
    }

    /// Strips the sentinel's separators/backticks around the reason (em/en dashes, colons, ticks).
    private static let trimSet = CharacterSet(charactersIn: " `—–:-.\n\t")
}
