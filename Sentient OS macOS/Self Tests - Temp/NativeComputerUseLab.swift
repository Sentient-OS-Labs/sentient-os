#if DEBUG
// Signed-app validation of native Codex and the Claude subscription provider.
// Uses the real CLI process plumbing without normal app startup, production data writes, or TCC edits.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import Carbon
import Darwin
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
        if command == "helper-takeover" || command == "permission-readiness" || command.hasPrefix("doctor") {
            // AEDeterminePermission can hang on a deliberately suspended foreign helper.
            // The production gate performs this check after replacing it; preserve that order.
            result["appleEventsBefore"] = "checked_by_production_gate_after_takeover"
        } else if env["LAB_SKIP_AUTOMATION_PROBE"] == "1" {
            result["appleEventsBefore"] = "diagnostic probe skipped; OS authorization unchanged"
        } else if command.hasPrefix("claude") || command == "coordinator" {
            result["appleEventsBefore"] = "not_required_for_this_test"
        } else {
            result["appleEventsBefore"] = await appleEventsPermission(ask: false)
        }
        result["accessibility"] = AXIsProcessTrusted()
        result["screenRecording"] = CGPreflightScreenCaptureAccess()
        result["nativeHelperPresent"] = FileManager.default.isExecutableFile(atPath: helper.path)
        if command != "permission-readiness" { result["cuaInstalled"] = CuaDriver.isInstalled }
        persist(result)
        Log("NATIVE LAB preflight: \(command), AE=\(result["appleEventsBefore"]!), AX=\(result["accessibility"]!), Screen=\(result["screenRecording"]!)")
        do {
            switch command {
            case "preflight": break
            case "permission-readiness":
                // Real app-owned AX/capture proof, with no model, actions or permission request.
                // Optional TCC reads are evidence only; deny them in a fixture sandbox to prove
                // readiness remains independent of FDA. Never reset the user's real grants.
                let fixtureRoot = root.standardizedFileURL.resolvingSymlinksInPath()
                guard let runtimePath = env["SENTIENT_CODEX_RUNTIME_ROOT"],
                      URL(fileURLWithPath: runtimePath).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(fixtureRoot.path + "/"),
                      (try? String(contentsOf: fixtureRoot.appendingPathComponent(".native-permission-fixture"), encoding: .utf8)) == "1\n" else {
                    throw LabError.missingFixture
                }
                result["isolatedRuntimeVerified"] = true
                func tccReadObservation(_ path: String) -> (readable: Bool, denied: Bool) {
                    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
                    if descriptor >= 0 { Darwin.close(descriptor); return (true, false) }
                    return (false, errno == EPERM || errno == EACCES)
                }
                let systemTCC = tccReadObservation("/Library/Application Support/com.apple.TCC/TCC.db")
                let userTCC = tccReadObservation(FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path)
                result["systemTCCReadable"] = systemTCC.readable
                result["userTCCReadable"] = userTCC.readable
                result["systemTCCDenyConfirmed"] = systemTCC.denied
                result["userTCCDenyConfirmed"] = userTCC.denied
                if env["LAB_DENY_TCC_REQUIRED"] == "1" {
                    guard systemTCC.denied, userTCC.denied else { throw LabError.permissionDatabaseReadable }
                }
                let axObservation = Permissions.tccState(service: "kTCCServiceAccessibility", clientBundleID: helperID)
                let captureObservation = Permissions.tccState(service: "kTCCServiceScreenCapture", clientBundleID: helperID)
                result["helperAccessibilityTCCReadable"] = axObservation != .unavailable
                result["helperScreenRecordingTCCReadable"] = captureObservation != .unavailable
                if env["LAB_DENY_TCC_REQUIRED"] == "1" {
                    guard axObservation == .unavailable, captureObservation == .unavailable else { throw LabError.permissionDatabaseReadable }
                }
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                let running = try await OpenAIComputerUseRuntime.shared.start(configuration: configuration)
                let automation = await Permissions.nativeAutomationState(ask: false)
                result["automationGranted"] = automation == .granted
                guard automation == .granted else { throw OpenAIComputerUse.RuntimeError.permissionRequired }
                do {
                    try await NativePermissionCheck.shared.check(configuration: configuration, helper: running)
                    let proof = NativePermissionCheck.shared.snapshot
                    result["helperAccessibilityVerified"] = proof.accessibility == .verified
                    result["helperScreenRecordingVerified"] = proof.screenRecording == .verified
                    result["permissionReadinessVerified"] = proof.isReady
                    await NativePermissionCheck.shared.close()
                    result["proofClearedAfterClose"] = !NativePermissionCheck.shared.snapshot.isReady
                    guard proof.isReady else { throw LabError.invalidCapture }
                } catch {
                    await NativePermissionCheck.shared.close()
                    throw error
                }
            case "doctor-chatgpt", "doctor-claude":
                let saved = UserDefaults.standard.object(forKey: ComputerUseDoctor.savedReportKey)
                defer {
                    if let saved { UserDefaults.standard.set(saved, forKey: ComputerUseDoctor.savedReportKey) }
                    else { UserDefaults.standard.removeObject(forKey: ComputerUseDoctor.savedReportKey) }
                }
                let provider: ModelBackend = command == "doctor-claude" ? .claude : .chatgpt
                let previousCheck = ComputerUseDoctor.shared.report?.id
                let prompt = """
                Verify that an unnecessary computer-use diagnostic is suppressed. This is a tool-contract test.
                Call the available sentient_native.diagnose_computer_use tool exactly once with no arguments,
                and no other app, shell, web or computer tools. No failures have occurred in this run, so
                the expected status is not_needed. Do not manufacture failures to make a test eligible.
                Do not inspect or modify any customer app, account, file or permissions. Do not
                send any diagnostic report. If the returned status is not_needed, reply NOT_NEEDED and
                end with STATUS: DONE. Otherwise explain the mismatch and end with STATUS: COULD_NOT.
                """
                result["reply"] = try await ModelBackend.$runOverride.withValue(provider) {
                    try await FrontierRun.runAgentCommand(prompt, timeout: 180, onLine: { appendLine($0) })
                }
                let stream = try String(contentsOf: output.deletingPathExtension().appendingPathExtension("stream.txt"), encoding: .utf8)
                guard ComputerUseDoctor.shared.report?.id == previousCheck, !ComputerUseDoctor.shared.isRunning,
                      stream.contains("diagnose_computer_use"), stream.contains("not_needed"),
                      (result["reply"] as? String)?.contains("NOT_NEEDED") == true else { throw LabError.invalidCapture }
                result["diagnosticSuppressed"] = true
            case "doctor":
                let saved = UserDefaults.standard.object(forKey: ComputerUseDoctor.savedReportKey)
                defer {
                    if let saved { UserDefaults.standard.set(saved, forKey: ComputerUseDoctor.savedReportKey) }
                    else { UserDefaults.standard.removeObject(forKey: ComputerUseDoctor.savedReportKey) }
                }
                let fault = env["LAB_DIAGNOSTIC_FAULT"] ?? "none"
                let expected: ComputerUseCheckReport.Outcome
                switch fault {
                case "disconnect":
                    ComputerUseDoctor.shared.testProbeFailures = [.init(kind: .connection, code: nil, detail: .disconnected, stage: .transport)]
                    expected = .repaired
                case "persistent":
                    ComputerUseDoctor.shared.testProbeFailures = Array(repeating: .init(kind: .connection, code: nil, detail: .disconnected, stage: .transport), count: 2)
                    expected = .needsAttention
                case "permission":
                    ComputerUseDoctor.shared.testProbeFailures = [.init(kind: .permission, code: -1743, detail: .permissionDenied, stage: .probe)]
                    expected = .permissionsNeeded
                case "focus":
                    ComputerUseDoctor.shared.testProbeFailures = [.init(kind: .unknown, code: nil, detail: .focusChanged, stage: .action)]
                    expected = .interrupted
                case "cancel": expected = .cancelled
                default: expected = .passed
                }
                ComputerUseDoctor.shared.start()
                if fault == "cancel" {
                    Task { try? await Task.sleep(for: .milliseconds(800)); ComputerUseDoctor.shared.cancel() }
                }
                while ComputerUseDoctor.shared.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                guard let report = ComputerUseDoctor.shared.report else { throw LabError.invalidCapture }
                result["diagnostic"] = try JSONSerialization.jsonObject(with: report.encoded())
                result["injectedFault"] = fault
                result["expectedOutcome"] = expected.rawValue
                result["repairClaimVerified"] = report.repairVerified == (expected == .repaired)
                persist(result)
                if let seconds = env["LAB_KEEP_OPEN"].flatMap(Double.init) { try await Task.sleep(for: .seconds(min(seconds, 300))) }
                guard report.outcome == expected, report.repairVerified == (expected == .repaired),
                      !["permission", "focus", "cancel"].contains(fault) || !report.repairAttempted else { throw LabError.invalidCapture }
            case "capture", "helper-takeover":
                // Explicit test-only capture through the current model-free session API.
                // No production health UI/recovery loop, saved pixels, or model call.
                let bootstrap = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                    styleMask: [.titled], backing: .buffered, defer: false)
                bootstrap.isReleasedWhenClosed = false
                bootstrap.title = "Sentient backend test"
                let captureText = "Sentient native capture check"
                let label = NSTextField(labelWithString: captureText)
                label.frame = NSRect(x: 20, y: 60, width: 320, height: 40)
                bootstrap.contentView?.addSubview(label)
                bootstrap.center(); bootstrap.makeKeyAndOrderFront(nil)
                defer { bootstrap.close() }
                NSApplication.shared.activate(ignoringOtherApps: true)
                for _ in 0..<20 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(100)) }
                let lease = try await CodexRuntime.sharedRuntimeLease()
                defer { lease.unlock() }
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                if command == "helper-takeover" {
                    let foreign = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
                        .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL != configuration.appURL.standardizedFileURL }
                    guard !foreign.isEmpty else { throw LabError.missingConflict }
                    result["foreignHelpersBefore"] = foreign.count
                    await CodexSetup.shared.refreshInstalled()
                    let gate = ComputerUseGate.shared
                    gate.refresh()
                    await gate.awaitAutomationRefresh()
                    result["passiveConflictHidden"] = gate.nativePermissionError == nil
                    result["passiveCheckPreservedOtherHelper"] = foreign.allSatisfy { !$0.isTerminated }
                    persist(result)
                    // A fixture timeout must distinguish a runtime stall from macOS setup
                    // legitimately waiting for a person. Read-only; never alter TCC grants.
                    let gateMonitor = Task { @MainActor in
                        for _ in 0..<40 {
                            let snapshot: [String: Any] = [
                                "allRequiredGranted": gate.allRequiredGranted,
                                "automation": String(describing: gate.automation),
                                "checkingAutomation": gate.checkingAutomation,
                                "requestingAutomation": gate.requestingAutomation,
                                "helperAccessibility": gate.helperAccessibility,
                                "helperScreen": gate.helperScreen,
                                "sentientScreen": gate.sentientScreen,
                                "runtimeInstalled": gate.setup.ready,
                                "codexReady": CodexSetup.shared.computerUseReady,
                                "voice": String(describing: gate.micSpeech),
                                "voiceOffered": UserDefaults.standard.bool(forKey: ComputerUseGate.micSpeechOfferedKey),
                                "nativePermissionError": gate.nativePermissionError ?? ""
                            ]
                            if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
                                try? data.write(to: root.appendingPathComponent("evidence/gate-status.json"), options: .atomic)
                            }
                            do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        }
                    }
                    defer { gateMonitor.cancel() }
                    // Exactly the preparation used by the real prompt-box task, with all
                    // existing macOS grants. No model, credential edits or user-app actions.
                    try await gate.waitUntilReady()
                    result["foregroundGateReady"] = gate.allRequiredGranted
                    result["foreignHelpersTerminated"] = foreign.allSatisfy(\.isTerminated)
                    let own = try await OpenAIComputerUseRuntime.shared.start(configuration: configuration, stoppingConflictingHelpers: true)
                    let reused = try await OpenAIComputerUseRuntime.shared.start(configuration: configuration, stoppingConflictingHelpers: true)
                    result["privateHelperReused"] = !own.isTerminated && own.processIdentifier == reused.processIdentifier
                    result["privateHelperPath"] = own.bundleURL?.standardizedFileURL == configuration.appURL.standardizedFileURL
                    guard gate.allRequiredGranted, gate.nativePermissionError == nil,
                          foreign.allSatisfy(\.isTerminated), !own.isTerminated,
                          own.processIdentifier == reused.processIdentifier else { throw LabError.takeoverFailed }
                }
                let task = try await OpenAIComputerUseRuntime.shared.beginTask(configuration: configuration)
                defer { OpenAIComputerUseRuntime.shared.endTask(task) }
                let session = try await OpenAIComputerUseSession.open(configuration)
                do {
                    let arguments = try JSONSerialization.data(withJSONObject: ["app": Bundle.main.bundleURL.path])
                    let data = try await session.call("get_app_state", arguments: arguments)
                    guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw LabError.invalidCapture
                    }
                    try OpenAIComputerUseProbe.validateResult(reply, requiresCapture: true)
                    let content = reply["content"] as? [[String: Any]] ?? []
                    guard content.contains(where: { ($0["text"] as? String)?.contains(captureText) == true }) else {
                        throw LabError.invalidCapture
                    }
                    if env["LAB_CAPTURE_DETAILS"] == "1" {
                        // Only this app-owned synthetic window; never retain image bytes.
                        let details = content.compactMap { $0["text"] as? String }
                        try JSONSerialization.data(withJSONObject: details, options: .prettyPrinted)
                            .write(to: root.appendingPathComponent("evidence/synthetic-state.json"))
                        try await session.catalog().write(to: root.appendingPathComponent("evidence/native-catalog.json"))
                    }
                    try Task.checkCancellation()
                    await session.close()
                    result["captureHealth"] = "passed"
                    result["captureVerified"] = true
                } catch {
                    await session.close()
                    throw error
                }
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
    private enum LabError: Error { case missingPrompt, invalidCapture, missingConflict, takeoverFailed, missingFixture, permissionDatabaseReadable }
}
#endif
