// Operates only uniquely marked controls in Sentient's temporary test window.
// Every action uses a fresh tree and is verified against the actual native control value.
import Foundation

nonisolated enum ComputerUseCheckProbe {
    typealias Call = @Sendable (String, Data) async throws -> Data
    typealias Update = @MainActor @Sendable (ComputerUseCheckReport.Check, ComputerUseCheckReport.Status, NativeComputerUseFailure?) -> Void

    struct Target: Sendable {
        let app: String
        let marker: String
        let buttonLabel: String
        let fieldLabel: String
        let expectedText: String
        let isCurrent: @MainActor @Sendable () -> Bool
        let wasClicked: @MainActor @Sendable () -> Bool
        let textMatches: @MainActor @Sendable () -> Bool
    }

    static func run(target: Target, call: Call, update: Update) async throws {
        func invoke(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
            try Task.checkCancellation()
            guard await target.isCurrent() else { throw interrupted() }
            let data = try await call(tool, JSONSerialization.data(withJSONObject: args))
            try Task.checkCancellation()
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .probe)
            }
            if NativeComputerUseFailure.isError(result) { throw NativeComputerUseFailure.classify(result, stage: .probe) }
            guard await target.isCurrent() else { throw interrupted() }
            return result
        }
        func read() async throws -> (String, [String: Any]) {
            let result = try await invoke("get_app_state", ["app": target.app])
            let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard text.contains(target.marker) else { throw interrupted() }
            return (text, result)
        }
        var stage = ComputerUseCheckReport.Check.accessibility
        do {
            await update(stage, .running, nil)
            let (_, initial) = try await read()
            await update(stage, .passed, nil)
            stage = .capture; await update(stage, .running, nil)
            try OpenAIComputerUseProbe.validateResult(initial, requiresCapture: true)
            await update(stage, .passed, nil)

            stage = .click; await update(stage, .running, nil)
            let (buttonTree, _) = try await read()
            let button = try element(in: buttonTree, label: target.buttonLabel, role: "button")
            _ = try await invoke("click", ["app": target.app, "element_index": button])
            _ = try await read()
            guard await target.wasClicked() else { throw interrupted() }
            await update(stage, .passed, nil)

            stage = .textEntry; await update(stage, .running, nil)
            let (fieldTree, _) = try await read()
            let field = try element(in: fieldTree, label: target.fieldLabel, role: "text field")
            _ = try await invoke("set_value", ["app": target.app, "element_index": field, "value": target.expectedText])
            _ = try await read()
            guard await target.textMatches() else { throw interrupted() }
            await update(stage, .passed, nil)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = error as? NativeComputerUseFailure
                ?? .init(kind: .unknown, code: nil, detail: .unspecified, stage: .probe)
            await update(stage, ComputerUseCheckReport.outcome(for: failure) == .interrupted ? .interrupted : .needsAttention, failure)
            throw failure
        }
    }

    static func element(in tree: String, label: String, role: String) throws -> String {
        // No arbitrary app text, approximate matching or coordinate fallback. An ambiguous or
        // changed test tree is interrupted, never permission failure and never a guessed click.
        let pattern = #"^\s*([0-9]+) "# + NSRegularExpression.escapedPattern(for: role) + #"\b[^\n]*"#
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(tree.startIndex..., in: tree)
        let ids = regex.matches(in: tree, range: range).compactMap { match -> String? in
            guard let line = Range(match.range, in: tree), let id = Range(match.range(at: 1), in: tree),
                  tree[line].contains(label) else { return nil }
            return String(tree[id])
        }
        guard ids.count == 1 else { throw interrupted() }
        return ids[0]
    }
    private static func interrupted() -> NativeComputerUseFailure {
        .init(kind: .unknown, code: nil, detail: .testWindowNotObserved, stage: .probe)
    }
}
