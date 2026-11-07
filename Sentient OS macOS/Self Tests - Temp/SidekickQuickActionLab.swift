#if DEBUG
import AppKit

/// Opt-in integration through the actual foreground agent and local MCP server, without a test Home window.
@MainActor enum SidekickQuickActionLab {
    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("allow-live-quick-actions").path) else { throw Failure.authorization }
        let coordinator = app.commandCoordinator, model = coordinator.run
        await CodexSetup.shared.refreshInstalled()
        if ModelBackend.current == .claude { _ = await ClaudeAuth.refresh() }
        ComputerUseGate.shared.refresh()
        await ComputerUseGate.shared.awaitAutomationRefresh()
        ComputerUseGate.shared.fixNativePermissions()
        while ComputerUseGate.shared.requestingAutomation || ComputerUseGate.shared.checkingCapabilities {
            try await Task.sleep(for:.milliseconds(100))
        }
        var summaryCalls = 0, proofreadCalls = 0, corrected = "", summaryText = ""
        let original = model.makeQuickActions
        model.makeQuickActions = { source in
            let actions = original!(source)
            return SidekickQuickActions(summarize: { preference, application in
                summaryCalls += 1
                let result = try await actions.summarize(preference,application)
                summaryText = result.markdown
                return result
            }, proofread: { text in
                proofreadCalls += 1
                corrected = try await actions.proofread(text)
                return corrected
            })
        }
        defer { model.makeQuickActions = original; coordinator.summarize.dismiss(); model.stop() }
        var checks: [String: Bool] = [:], results: [[String: Any]] = []
        for (name,prompt) in [
            ("proofread", "Fix the spelling mistakes in this text and show me the corrected text: \"I recieved teh mesage.\" Do not edit any app or send anything."),
            ("summarize", "Summarise the page currently open in Safari. Do not navigate or change anything in Safari.")
        ] {
            let began = Date()
            let accepted = coordinator.submit(prompt,mode:.computer,source:.promptBar)
            while model.isRunning && Date().timeIntervalSince(began) < 180 {
                if model.recovery.isPending { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            checks[name + "-accepted"] = accepted
            checks[name + "-completed"] = !model.isRunning && !model.recovery.isPending
            checks[name + "-tool-used"] = name == "proofread" ? proofreadCalls == 1 : summaryCalls == 1
            checks[name + "-service-result"] = name == "proofread" ? corrected.contains("I received the message.") : summaryText.count > 50
            results.append(["case":name,"seconds":Date().timeIntervalSince(began),"status":model.statusLine,
                "corrected_text":corrected,"summary":summaryText,"model":ComputerUseSpeed.current.modelLine])
            try JSONSerialization.data(withJSONObject:["checks":checks,"results":results],options:[.prettyPrinted,.sortedKeys])
                .write(to:root.appendingPathComponent("quick-action-results.json"))
            if model.isRunning || model.recovery.isPending { model.stop(); throw Failure.task }
        }
        guard checks.values.allSatisfy({$0}) else { throw Failure.task }
        return checks
    }
    enum Failure: Error { case authorization, task }
}
#endif
