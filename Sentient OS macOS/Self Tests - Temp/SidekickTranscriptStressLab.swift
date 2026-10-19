#if DEBUG
// Bounded real-Home reproduction for layout hangs. SidekickAppLab installs isolated defaults
// and a cloned fixture store before this entry. No provider, native helper or other-app action.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

@MainActor enum SidekickTranscriptStressLab {
    enum Failure: String, Error { case isolation, unavailable, screenLocked, simulation, compaction, capture }

    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        let env = ProcessInfo.processInfo.environment
        guard env["SENTIENT_SELFTEST"] == "sidekickapp", env["LAB_SIDEKICK_STAGE"] == "ui-stress",
              let path = env["LAB_SIDEKICK_ROOT"],
              root.standardizedFileURL == URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL,
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture.json"))) as? [String: Any],
              let cycles = manifest["stress_cycles"] as? Int, (12...20).contains(cycles),
              manifest["stress_source_sha256"] is String else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        let run = app.commandCoordinator.run, conversation = run.conversation, presentation = app.sidekickPresentation
        guard let store = conversation.store, !run.isRunning, run.interaction == nil else { throw Failure.unavailable }
        let began = ProcessInfo.processInfo.systemUptime
        let initialSequence = try store.latestSequence
        let initialMemory = try SidekickInstructionStore.read().text
        let sourcePage = try store.transcriptPage()
        guard let final = sourcePage.records.last(where: { $0.event.kind == .assistantMessage && $0.event.messageKind == .answer }),
              let request = try store.records(taskID: final.event.taskID, limit: 500).last(where: { $0.event.kind == .userMessage }) else { throw Failure.simulation }
        let originalRequest = request.event.text, originalAnswer = final.event.text
        let activityCounts = [3, 27, 4, 1, 26, 0]
        let capturesEnabled = manifest["stress_captures"] as? Bool == true
        var completed = 0, stops = 0, paging = 0, captures = 0, notchMessages = 0
        if capturesEnabled {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("stress-captures", isDirectory: true), withIntermediateDirectories: true)
        }
        var checks: [String: Bool] = [:]
        var beats: [[String: Any]] = []
        var contentSamples: [[String: Any]] = []
        var blankCycles: [Int] = []
        var offscreenAnswerCycles: [Int] = []
        func beat(_ phase: String, cycle: Int = -1) throws {
            let value: [String: Any] = ["phase": phase, "cycle": cycle, "completed_cycles": completed,
                "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - began) * 1_000),
                "process_id": getpid(), "scroll_request": presentation.scrollRequest,
                "rendered_message_count": presentation.rows.count,
                "home_visible": conversation.isVisible, "app_active": NSApp.isActive,
                "notch_message": app.commandCoordinator.phase == .message,
                "cycle_activity_count": cycle >= 0 ? activityCounts[cycle % activityCounts.count] : 0]
            beats.append(value)
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("stress-heartbeat.json"), options: .atomic)
        }
        defer {
            run.preventsTaskExecutionForUIFixture = true
            conversation.beginMaintenance()
            let result: [String: Any] = ["completed_cycles": completed, "requested_cycles": cycles,
                "checks": checks, "heartbeats": beats, "provider_calls": 0, "initial_sequence": initialSequence,
                "source_request_bytes": originalRequest.utf8.count, "source_answer_bytes": originalAnswer.utf8.count,
                "captures_enabled": capturesEnabled, "own_window_captures": captures,
                "native_notch_message_cycles": notchMessages,
                "visible_content_samples": contentSamples, "blank_transcript_cycles": blankCycles,
                "offscreen_latest_answer_cycles": offscreenAnswerCycles,
                "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - began) * 1_000)]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: root.appendingPathComponent("stress-manifest.json"), options: .atomic)
            }
        }
        try beat("before_mount")
        run.preventsTaskExecutionForUIFixture = true
        MainNavigation.shared.reset()
        presentation.surface = .conversation
        conversation.draft = ""
        let host = NSHostingView(rootView: HomeView(deck: .jesai).environment(app).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Sidekick transcript stress · synthetic fixture"
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let notch = NotchWindowController(coordinator: app.commandCoordinator)
        notch.start()
        defer { notch.shutdownForTesting(); window.close() }
        try beat("mounted")
        await presentation.load(.latest, conversation: conversation)
        try await pause(120)
        checks["real_notch_controller_started"] = notch.panelForTesting != nil
        try beat("initial_latest_loaded")

        for cycle in 0..<cycles {
            try beat("before_adopt", cycle: cycle)
            run.preventsTaskExecutionForUIFixture = false
            let cycleRequest = cycle == 0 ? originalRequest : originalRequest + "\n\n[UI stress cycle \(cycle + 1)]"
            run.adoptExternal(caption: cycleRequest, request: cycleRequest, onStopRequest: { stops += 1 })
            run.preventsTaskExecutionForUIFixture = true
            guard run.isRunning, let recording = run.interaction?.conversationRun else { throw Failure.simulation }
            let taskID = run.runID
            presentation.surface = .conversation
            presentation.followActiveWork(taskID, generation: conversation.generation)
            await presentation.load(.latest, conversation: conversation)
            try beat("adopted_expanded", cycle: cycle)
            try await pause(70)
            let count = activityCounts[cycle % activityCounts.count]
            run.externalPush("codex"); run.externalPush("Thinking through your task")
            for index in 0..<count {
                try appendActivity(recording, index: index, failed: count == 4 && index == 3)
                if index == 19 || index == 20 {
                    conversation.refresh()
                    run.externalPush("codex"); run.externalPush("→ sentient_native.get_app_state")
                    try beat(index == 19 ? "activity_40" : "activity_42", cycle: cycle)
                    try await pause(80)
                }
            }
            conversation.refresh()
            if count > 0 { run.externalPush("codex"); run.externalPush("→ sentient_native.get_app_state") }
            try beat("activity_\(count * 2)", cycle: cycle)
            try await pause(100)
            let page = try store.activityPage(taskID: taskID)
            if page.hasEarlier, let first = page.records.first {
                presentation.browseWork(taskID)
                presentation.setWorkPage(.before(first.sequence), taskID: taskID)
                try beat("work_earlier", cycle: cycle)
                try await pause(70)
                presentation.setWorkPage(.after(first.sequence), taskID: taskID)
                try beat("work_next", cycle: cycle)
                try await pause(70)
                presentation.followLatestWork(taskID)
                try beat("work_latest", cycle: cycle)
                try await pause(70)
                paging += 1
            }
            if cycle.isMultiple(of: 3), let firstMessage = presentation.rows.first {
                await presentation.load(.earlier(firstMessage.sequence), conversation: conversation)
                try beat("history_earlier", cycle: cycle)
                try await pause(50)
                await presentation.load(.latest, conversation: conversation)
                try beat("history_latest", cycle: cycle)
            }
            // The observed failure completed while Home was inactive, then reactivated.
            // Preserve that ordering, rather than backgrounding an already-finished view.
            // deactivate() alone can leave a self-test app active. Hide only this owned
            // window so native occlusion/presence really changes while its view stays mounted.
            window.orderOut(nil)
            NSApp.deactivate()
            try beat("inactive_before_final", cycle: cycle)
            try await pause(80)
            let visibilityDeadline = ContinuousClock.now.advanced(by: .milliseconds(300))
            while conversation.isVisible && ContinuousClock.now < visibilityDeadline { try await pause(10) }
            guard !conversation.isVisible else { throw Failure.simulation }
            try beat("home_hidden_before_final", cycle: cycle)
            run.externalPush("codex")
            run.externalPush(originalAnswer + " Checking the saved result.")
            try beat("inactive_progress_prose", cycle: cycle)
            try await pause(70)
            let variation: String
            switch cycle % 3 {
            case 1: variation = "\n\n### Synthetic layout variation\n\n- A short follow-up.\n- A longer item that wraps naturally and changes the response height as the activity disclosure finishes."
            case 2: variation = "\n\n| Fixture | State |\n|:--|:--|\n| First row | Ready |\n| Second row | Complete |\n\n> This extra synthetic block exercises a different response height."
            default: variation = ""
            }
            // Every answer source is unique, so an old cloned reply cannot satisfy the
            // final-answer visibility check simply because its wording is identical.
            let suffix = "\n\n*UI stress cycle \(cycle + 1).*" + variation
            guard originalAnswer.utf8.count + suffix.utf8.count <= 65_536 else { throw Failure.simulation }
            let answer = originalAnswer + suffix
            _ = try recording.message(answer, kind: .answer, priority: .high, completion: .done)
            conversation.refresh()
            try beat("final_inserted", cycle: cycle)
            if count > 0 && cycle.isMultiple(of: 2) {
                // A final message may precede the provider's final verification/tool
                // completion. Keep Home mounted but hidden while that late activity lands.
                try appendActivity(recording, index: count, failed: false)
                conversation.refresh()
                run.externalPush("codex"); run.externalPush("→ sentient_native.get_app_state")
                try beat("late_activity_after_answer", cycle: cycle)
            }
            try await pause(70)
            if app.commandCoordinator.phase == .message, notch.panelForTesting?.isVisible == true { notchMessages += 1 }
            run.completeExternal(.success, line: "Synthetic cycle complete", finalText: "STATUS: DONE", runID: taskID)
            // Synchronous maintenance begins before the 2-second compaction task can run.
            // Do not yield, write a heartbeat, or run another UI phase before this guard.
            guard conversation.beginMaintenance() else { throw Failure.compaction }
            await conversation.drainBackgroundWork()
            guard !conversation.hasPendingCompactionWorkForTesting else { throw Failure.compaction }
            try beat("completed_and_drained", cycle: cycle)
            // Maintenance cancellation must not suppress the normal activation refresh.
            // Releasing it does not schedule compaction; only a future completion can.
            conversation.endMaintenance()
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try beat("reactivated", cycle: cycle)
            try await pause(700)
            if capturesEnabled {
                try beat("own_capture_started", cycle: cycle)
                try await capture(window: window, cycle: cycle, root: root)
                captures += 1
                try beat("own_capture_finished", cycle: cycle)
            }
            // Observe the same settled viewport that was captured, before requesting any
            // extra AppKit layout which could hide a transient blank lazy-stack gap.
            let content = visibleConversationContent(in: host, latestAnswer: answer)
            contentSamples.append(["cycle": cycle, "model_rows": presentation.rows.count,
                "visible_text_fragments": content.text, "visible_activity_rows": content.activity,
                "visible_latest_answer_fragments": content.answer])
            if presentation.rows.isEmpty || content.text + content.activity == 0 { blankCycles.append(cycle) }
            if content.answer == 0 { offscreenAnswerCycles.append(cycle) }
            try beat("visible_content_checked", cycle: cycle)
            host.layoutSubtreeIfNeeded()
            completed += 1
            try beat("cycle_finished", cycle: cycle)
        }
        checks["all_cycles_completed"] = completed == cycles
        checks["all_activity_pages_exercised"] = paging == (0..<cycles).filter { activityCounts[$0 % activityCounts.count] > 20 }.count
        checks["simulation_never_stopped"] = stops == 0 && !run.isRunning
        checks["compaction_drained_each_cycle"] = !conversation.hasPendingCompactionWorkForTesting
        checks["requested_own_captures_completed"] = captures == (capturesEnabled ? cycles : 0)
        checks["saved_instructions_unchanged"] = try SidekickInstructionStore.read().text == initialMemory
        checks["cloned_store_remains_readable"] = try store.latestSequence > initialSequence
        checks["main_actor_reached_final_phase"] = true
        checks["reactivated_transcript_never_blank"] = blankCycles.isEmpty && contentSamples.count == cycles
        checks["latest_answer_visible_after_each_completion"] = offscreenAnswerCycles.isEmpty && contentSamples.count == cycles
        checks["inactive_completion_presented_real_notch"] = notchMessages > 0
        notch.shutdownForTesting()
        checks["native_notch_resources_released"] = notch.resourcesReleasedForTesting
        try beat("finished")
        return checks
    }
    private static func pause(_ milliseconds: Int) async throws {
        await Task.yield(); try await Task.sleep(for: .milliseconds(milliseconds))
    }
    private static func visibleConversationContent(in root: NSView, latestAnswer: String) -> (text: Int, activity: Int, answer: Int) {
        var textCount = 0, activityCount = 0, answerCount = 0
        let answerSource = SidekickMarkdownDocument(markdown: latestAnswer).source
        func hasArea(_ rect: CGRect) -> Bool {
            !rect.isNull && rect.width >= 24 && rect.height >= 8
        }
        @MainActor func views(_ view: NSView) {
            if let text = view as? SidekickMarkdownTextView, text.interactionEnabled,
               !text.isHiddenOrHasHiddenAncestor, text.alphaValue > 0.01,
               !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let clipped = text.visibleRect.intersection(text.bounds)
                if hasArea(clipped), hasArea(root.convert(clipped, from: text).intersection(root.bounds)) {
                    textCount += 1
                    // Match the renderer's model source, not a hard-coded phrase or a
                    // coincidentally visible old reply. At least one final-answer fragment
                    // must be on screen; visible activity alone is insufficient.
                    if text.source == answerSource { answerCount += 1 }
                }
            }
            for child in view.subviews { views(child) }
        }
        views(root)
        // Activity rows are SwiftUI text, rather than native Markdown text views. Inspect
        // only their concrete row IDs, never the large group/container's estimated frame.
        var visited = Set<ObjectIdentifier>()
        @MainActor func activity(_ value: Any, depth: Int) {
            guard depth < 35, visited.count < 4000, let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            func attribute(_ key: String) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            if let identifier = attribute("accessibilityIdentifier") as? String,
               identifier.hasPrefix("sidekick.activityStep."),
               let frame = attribute("accessibilityFrame") as? NSValue, let window = root.window {
                let local = root.convert(window.convertFromScreen(frame.rectValue), from: nil)
                if hasArea(local.intersection(root.visibleRect)) { activityCount += 1 }
            }
            for child in attribute("accessibilityChildren") as? [Any] ?? [] { activity(child, depth: depth + 1) }
        }
        activity(root, depth: 0)
        return (textCount, activityCount, answerCount)
    }
    private static func capture(window: NSWindow, cycle: Int, root: URL) async throws {
        // Use only the current-process API and this exact Home window. Never enumerate
        // or capture another application's windows, a display, or a screen rectangle.
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
        }) else { throw Failure.capture }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let config = SCStreamConfiguration()
        config.width = Int(ceil(own.frame.width * CGFloat(filter.pointPixelScale)))
        config.height = Int(ceil(own.frame.height * CGFloat(filter.pointPixelScale)))
        config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
        config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { throw Failure.capture }
        try jpeg.write(to: root.appendingPathComponent("stress-captures/cycle-\(cycle + 1).jpg"), options: .atomic)
    }
    private static func appendActivity(_ recording: SidekickConversationRun, index: Int, failed: Bool) throws {
        for status in ["started", "completed"] {
            let result: [String: Any] = failed && status == "completed"
                ? ["isError": true, "content": [["type": "text", "text": "Synthetic fixture operation unavailable."]]]
                : ["content": [["type": "text", "text": "Synthetic fixture receipt."]]]
            let item: [String: Any] = ["id": "stress-tool-\(index)", "type": "mcp_tool_call", "server": "sentient_native",
                "tool": index.isMultiple(of: 2) ? "get_app_state" : "click",
                "arguments": ["app": index.isMultiple(of: 3) ? "com.spotify.client" : "net.whatsapp.WhatsApp",
                              "description": "Synthetic activity \(index + 1)"], "status": failed && status == "completed" ? "failed" : status,
                "result": result]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "item." + status, "item": item]), as: UTF8.self)
            try recording.observe(raw, streamID: recording.taskID)
        }
    }
}
#endif
