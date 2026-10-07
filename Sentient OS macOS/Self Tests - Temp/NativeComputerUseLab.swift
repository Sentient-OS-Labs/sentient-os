#if DEBUG
// Signed-app validation of native Codex and the Claude subscription provider.
// Uses the real CLI process plumbing without normal app startup, production data writes, or TCC edits.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import Carbon
import Foundation

nonisolated enum NativeComputerUseLab {
    private static let helperID = "com.openai.sky.CUAService"
    private static let env = ProcessInfo.processInfo.environment
    private static var root: URL { URL(fileURLWithPath: env["LAB_ROOT"]!) }
    private static var output: URL { root.appendingPathComponent("evidence/\(env["LAB_NAME"] ?? "preflight").json") }
    private static var helper: URL {
        CodexRuntime.helper.appendingPathComponent(OpenAIComputerUse.clientRelativePath)
    }

    @MainActor static func run() async {
        guard env["LAB_ROOT"] != nil else { Log("NATIVE LAB: LAB_ROOT is required"); return }
        let command = env["LAB_COMMAND"] ?? "preflight"
        var result: [String: Any] = ["command": command, "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "bundlePath": Bundle.main.bundlePath, "pid": ProcessInfo.processInfo.processIdentifier,
            "started": Date().timeIntervalSince1970]
        persist(result)
        if env["LAB_SKIP_AUTOMATION_PROBE"] == "1" {
            result["appleEventsBefore"] = "diagnostic probe skipped; OS authorization unchanged"
        } else if command.hasPrefix("claude") || command == "coordinator" {
            result["appleEventsBefore"] = "not_required_for_this_test"
        } else {
            result["appleEventsBefore"] = await appleEventsPermission(ask: false)
        }
        result["accessibility"] = AXIsProcessTrusted()
        result["screenRecording"] = CGPreflightScreenCaptureAccess()
        result["nativeHelperPresent"] = FileManager.default.isExecutableFile(atPath: helper.path)
        result["cuaInstalled"] = CuaDriver.isInstalled
        persist(result)
        Log("NATIVE LAB preflight: \(command), AE=\(result["appleEventsBefore"]!), AX=\(result["accessibility"]!), Screen=\(result["screenRecording"]!)")
        do {
            switch command {
            case "preflight": break
            case "coordinator":
                guard Bundle.main.bundleIdentifier == "ai.sentient.cua-controller-validation" else {
                    result["error"] = "Controller tests require a separate defaults domain"; break
                }
                let coordinator = CommandCoordinator()
                var stops = 0
                var completions: [String] = []
                coordinator.run.onFinished = { completions.append(String(describing: $0)) }
                result["firstAccepted"] = coordinator.beginExternalRun(caption: "Synthetic first run", onStopRequest: { stops += 1 })
                for source in [TriggerSource.promptBar, .notchTyped, .voice] {
                    coordinator.submit("Must be rejected while busy", mode: .computer, source: source)
                }
                result["busyCaptionPreserved"] = coordinator.run.statusLine == "Synthetic first run"
                result["secondCardRejected"] = !coordinator.beginExternalRun(caption: "Must be rejected", onStopRequest: {})
                coordinator.run.externalPush("codex")
                coordinator.run.externalPush("Synthetic progress line")
                result["progressLine"] = coordinator.run.statusLine
                coordinator.stop()
                result["cancelForwardedOnce"] = stops == 1
                result["lockHeldDuringStop"] = coordinator.run.isRunning
                result["cardRejectedDuringStop"] = !coordinator.beginExternalRun(caption: "Must still be rejected", onStopRequest: {})
                coordinator.run.completeExternal(.stopped, line: "Stopped")
                result["lockReleasedAfterCompletion"] = !coordinator.run.isRunning
                coordinator.run.completeExternal(.success, line: "Duplicate completion")
                result["completionDeliveredOnce"] = completions == ["stopped"]
                result["nextAccepted"] = coordinator.beginExternalRun(caption: "Synthetic next run", onStopRequest: {})
                coordinator.run.completeExternal(.stopped, line: "Test complete")
            case "request-automation":
                NSApplication.shared.activate(ignoringOtherApps: true)
                Log("NATIVE LAB: requesting the native Apple Events consent dialog")
                result["appleEventsRequest"] = await appleEventsPermission(ask: true)
                result["appleEventsAfter"] = await appleEventsPermission(ask: false)
            case "native", "native-stop", "native-stop-recover", "native-error-recover":
                guard let promptFile = env["LAB_PROMPT_FILE"] else { throw LabError.missingPrompt }
                let prompt = try String(contentsOfFile: promptFile, encoding: .utf8)
                let cancelAfter = command.hasPrefix("native-stop") ? Double(env["LAB_CANCEL_AFTER"] ?? "15") : nil
                result.merge(await native(prompt: prompt, cancelAfter: cancelAfter)) { _, new in new }
                if command.hasSuffix("-recover"), let file = env["LAB_RECOVERY_PROMPT_FILE"] {
                    let recoveryPrompt = try String(contentsOfFile: file, encoding: .utf8)
                    result["recovery"] = await native(prompt: recoveryPrompt, cancelAfter: nil)
                }
            case "claude", "claude-stop", "claude-stop-recover":
                guard let promptFile = env["LAB_PROMPT_FILE"] else { throw LabError.missingPrompt }
                let prompt = try String(contentsOfFile: promptFile, encoding: .utf8)
                let began = Date()
                let task = Task {
                    try await ModelBackend.$runOverride.withValue(.claude) {
                        try await FrontierRun.runAgentCommand(prompt,
                            timeout: 180, onLine: { line in appendLine(line) })
                    }
                }
                if command.hasPrefix("claude-stop") {
                    let seconds = Double(env["LAB_CANCEL_AFTER"] ?? "15") ?? 15
                    Task {
                        if let target = env["LAB_CANCEL_COUNT"].flatMap(Int.init) {
                            for _ in 0..<1200 {
                                if let data = try? Data(contentsOf: root.appendingPathComponent("evidence/fixture-state.json")),
                                   let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                                   let count = state["count"] as? Int, count >= target {
                                    task.cancel(); return
                                }
                                try? await Task.sleep(for: .milliseconds(150))
                            }
                        } else {
                            try? await Task.sleep(for: .seconds(seconds)); task.cancel()
                        }
                    }
                }
                do {
                    let text = try await task.value
                    result["reply"] = text
                    result["status"] = status(AgentStatus.parse(text))
                } catch { result["error"] = String(describing: error); result["cancelled"] = task.isCancelled }
                result["seconds"] = Date().timeIntervalSince(began)
                if command == "claude-stop-recover", let file = env["LAB_RECOVERY_PROMPT_FILE"] {
                    let recoveryPrompt = try String(contentsOfFile: file, encoding: .utf8)
                    do {
                        result["recoveryReply"] = try await ModelBackend.$runOverride.withValue(.claude) {
                            try await FrontierRun.runAgentCommand(recoveryPrompt,
                                timeout: 120, onLine: { appendLine("RECOVERY: " + $0) })
                        }
                    } catch {
                        result["recoveryError"] = String(describing: error)
                        try? await Task.sleep(for: .seconds(3))
                        do {
                            result["delayedRecoveryReply"] = try await ModelBackend.$runOverride.withValue(.claude) {
                                try await FrontierRun.runAgentCommand(recoveryPrompt,
                                    timeout: 120, onLine: { appendLine("DELAYED RECOVERY: " + $0) })
                            }
                        } catch { result["delayedRecoveryError"] = String(describing: error) }
                    }
                }
            default: result["error"] = "Unknown LAB_COMMAND"
            }
        } catch { result["error"] = String(describing: error) }
        result["finished"] = Date().timeIntervalSince1970
        persist(result)
        Log("NATIVE LAB: finished \(command); receipt \(output.path)")
    }

    private static func native(prompt: String, cancelAfter: Double?) async -> [String: Any] {
        guard let cli = CodexCLI.locateBinary(),
              let configuration = try? OpenAIComputerUse.Configuration(cliPath: cli) else {
            return ["error": "Private Codex runtime unavailable"]
        }
        let model = env["LAB_MODEL"] ?? "gpt-5.6-sol"
        var args = ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
            "--dangerously-bypass-approvals-and-sandbox", "-m", model,
            "-c", "model_reasoning_effort=\"low\"", "-c", "features.apps=false", "-c", "features.plugins=false",
            "-c", "mcp_servers.native_cua.command=\(quoted(configuration.clientURL.path))",
            "-c", "mcp_servers.native_cua.args=[\"mcp\"]",
            "-c", "mcp_servers.native_cua.required=true",
            "-c", "mcp_servers.native_cua.startup_timeout_sec=30",
            "-c", "mcp_servers.native_cua.tool_timeout_sec=45"]
        for (key, value) in configuration.clientEnvironment.sorted(by: { $0.key < $1.key }) {
            args += ["-c", "mcp_servers.native_cua.env.\(key)=\(quoted(value))"]
        }
        args.append(prompt)
        let began = Date()
        let task = Task {
            try await CodexCLI.executeStreaming(binary: cli, args: args, timeout: 180,
                onLine: { line in appendLine(line) })
        }
        let stopper: Task<Int?, Never>? = cancelAfter.map { seconds in
            Task {
                if let target = env["LAB_CANCEL_COUNT"].flatMap(Int.init) {
                    for _ in 0..<1200 {
                        if Task.isCancelled { return nil }
                        if let data = try? Data(contentsOf: root.appendingPathComponent("evidence/fixture-state.json")),
                           let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                           let count = state["count"] as? Int, count >= target {
                            task.cancel(); return count
                        }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
                    }
                    return nil
                }
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return nil }
                task.cancel(); return -1
            }
        }
        do {
            let response = try await task.value
            stopper?.cancel()
            let cancelledAt = await stopper?.value
            let text = response.stdout.isEmpty ? response.stderr : response.stdout
            var receipt: [String: Any] = ["exitCode": response.status, "reply": text, "status": status(AgentStatus.parse(text)),
                "seconds": Date().timeIntervalSince(began), "cancelled": task.isCancelled]
            if let cancelledAt { receipt["cancelledAtCount"] = cancelledAt }
            return receipt
        } catch {
            stopper?.cancel()
            let cancelledAt = await stopper?.value
            var receipt: [String: Any] = ["error": String(describing: error), "seconds": Date().timeIntervalSince(began), "cancelled": task.isCancelled]
            if let cancelledAt { receipt["cancelledAtCount"] = cancelledAt }
            return receipt
        }
    }

    private static func appleEventsPermission(ask: Bool) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: helperID)
                let code = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
                continuation.resume(returning: code)
            }
        }
    }

    private static func quoted(_ string: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
    }

    private static let lineLock = NSLock()
    private static func appendLine(_ line: String) {
        lineLock.lock(); defer { lineLock.unlock() }
        let url = output.deletingPathExtension().appendingPathExtension("stream.txt")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(line)\n".utf8))
    }

    private static func persist(_ result: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }

    private static func status(_ value: AgentStatus) -> String {
        switch value { case .done: "done"; case .none: "none"; case .couldNot(let reason): "couldNot: " + reason }
    }
    private enum LabError: Error { case missingPrompt }
}
#endif
