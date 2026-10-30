#if DEBUG
// Targeted native UI checks after SidekickAppLab isolates defaults and support files.
// Captures only this process's windows. No provider, computer-use helper or other app.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit
import SwiftUI
import WebKit

// A deliberate headless render surface for the film fixture only. Some remote Mac
// sessions report every automated window fully occluded. WebKit then correctly pauses
// rAF. The explicit runner flag supplies visibility to this owned test window; hiding
// or minimizing it still pauses normally. Production NSWindows are never changed.
@MainActor private final class FilmFixtureWindow: NSWindow {
    var rendersWhileOccluded = false
    override var occlusionState: NSWindow.OcclusionState {
        rendersWhileOccluded && isVisible && !isMiniaturized
            ? super.occlusionState.union(.visible) : super.occlusionState
    }
}

@MainActor enum SidekickPolishLab {
    enum Failure: String, Error { case isolation, screenLocked, unavailable, capture, accessibility, foreground }
    struct Element {
        let identifier: String
        let label: String
        let role: String
        let frame: CGRect
        var enabled: Bool? = nil
    }
    @MainActor private final class MenuObservation {
        var opened = 0
        var names: [String] = []
    }

    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "sidekickapp",
              ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-polish",
              let configuredRoot = ProcessInfo.processInfo.environment["LAB_SIDEKICK_ROOT"], root.isFileURL,
              root.standardizedFileURL == URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath() else { throw Failure.isolation }
        guard let store = app.commandCoordinator.run.conversation.store else { throw Failure.unavailable }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        let run = app.commandCoordinator.run
        let conversation = run.conversation
        let presentation = app.sidekickPresentation
        guard !run.isRunning, run.interaction == nil else { throw Failure.unavailable }
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = try SidekickInstructionStore.read().text
        let shortcut = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey)
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        var settingsControls: [[String: Any]] = []
        var completed = false
        defer {
            // Preserve earlier checks and captures when a later native interaction fails.
            let manifest: [String: Any] = ["schema": 1, "captures": captures, "checks": checks,
                "completed": completed, "settings_controls": settingsControls,
                "provider_calls": 0, "capture_scope": "current_process_windows_only"]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: root.appendingPathComponent("polish-manifest.json"), options: .atomic)
            }
        }
        var simulatedStops = 0
        run.preventsTaskExecutionForUIFixture = true
        MainNavigation.shared.reset()
        presentation.surface = .suggestions
        conversation.draft = "Find a little time for focused work tomorrow."

        let host = NSHostingView(rootView: AnyView(HomeView(deck: .jesai).environment(app).preferredColorScheme(.dark)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sidekick polish fixture · synthetic content"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.close(); run.preventsTaskExecutionForUIFixture = true }
        try await settle(750)
        let ready = elements(host)
        checks["ready_has_send"] = ready.contains { $0.identifier == "sidekick.send" }
        checks["home_ready_before_initial_analysis"] = app.hasCompletedOnboarding && !app.processing.initialComplete
        checks["double_tap_waits_for_initial_analysis"] = !DoubleTap.initialAnalysisComplete
        checks["ready_has_no_stop"] = !ready.contains { $0.identifier == "sidekick.stop" }
        captures.append(try await capture(host, name: "01-home-ready", directory: directory))

        // Adopt only a local simulation. No submit/start/provider code is called; UI sends
        // stay blocked by isRunning, and the explicit fixture gate is restored immediately.
        run.preventsTaskExecutionForUIFixture = false
        run.adoptExternal(caption: "Checking your apps…", request: "Synthetic UI work only", onStopRequest: { simulatedStops += 1 })
        run.preventsTaskExecutionForUIFixture = true
        guard run.isRunning, let recording = run.interaction?.conversationRun else { throw Failure.unavailable }
        conversation.draft = ""
        presentation.surface = .conversation
        await presentation.load(.latest, conversation: conversation)
        try await settle(300)
        for index in 0..<26 {
            try activity(recording, index: index, title: "Checked fixture item \(index + 1)")
        }
        conversation.refresh()
        run.externalPush("codex")
        run.externalPush("→ sentient_native.get_app_state")
        try await settle(350)
        try activity(recording, index: 26, title: "Read the newest fixture note")
        conversation.refresh()
        try await settle(650)
        let busy = elements(host)
        checks["busy_has_one_stop"] = busy.filter { $0.identifier == "sidekick.stop" }.count == 1
        checks["busy_has_no_send"] = !busy.contains { $0.identifier == "sidekick.send" }
        checks["busy_has_no_wait_helper"] = !busy.contains {
            $0.label.localizedCaseInsensitiveContains("Working on it.")
                || $0.label.localizedCaseInsensitiveContains("draft your next message")
        }
        if let newest = busy.first(where: { $0.label.contains("Read the newest fixture note") }),
           let composer = busy.first(where: { $0.identifier == "sidekick.composer" }) {
            let screenContent = window.convertToScreen(host.convert(host.bounds, to: nil))
            checks["latest_work_row_visible"] = newest.frame.height > 0 && screenContent.contains(newest.frame)
                && newest.frame.minY >= composer.frame.maxY
        } else { checks["latest_work_row_visible"] = false }
        captures.append(try await capture(host, name: "02-home-working", directory: directory))

        let metrics = NotchMetrics(availableSize: CGSize(width: 1440, height: 900), hardwareNotch: CGSize(width: 200, height: 32))
        let notch = NSHostingView(rootView: notchView(phase: .typing, metrics: metrics, activity: nil))
        let notchWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 250),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        notchWindow.title = "Sidekick notch polish · synthetic content"
        notchWindow.isReleasedWhenClosed = false; notchWindow.contentView = notch
        notchWindow.appearance = NSAppearance(named: .darkAqua)
        window.orderOut(nil); notchWindow.center(); notchWindow.makeKeyAndOrderFront(nil)
        defer { notchWindow.close() }
        try await settle(450)
        captures.append(try await capture(notch, name: "03-notch-typing", directory: directory))
        let latest = SidekickActivityPresentation.steps(try store.records(taskID: run.runID, limit: 100)).last
        notch.rootView = notchView(phase: .running, metrics: metrics, activity: latest)
        try await settle(450)
        captures.append(try await capture(notch, name: "04-notch-working", directory: directory))
        checks["notch_work_uses_real_activity"] = latest?.appIdentifier == "com.spotify.client"
        notchWindow.orderOut(nil)
        run.completeExternal(.success, line: "UI fixture complete", finalText: "STATUS: DONE", runID: run.runID)
        checks["simulation_stopped_without_provider"] = !run.isRunning && simulatedStops == 0
        conversation.beginMaintenance()

        MainNavigation.shared.settingsPane = .proactive
        host.rootView = AnyView(SettingsView().environment(app).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await settle(500)
        captures.append(try await capture(host, name: "05-settings-shortcut", directory: directory))
        let settings = elements(host)
        settingsControls = settings.filter {
            $0.identifier.hasPrefix("settings.menu.") || $0.role == NSAccessibility.Role.popUpButton.rawValue
                || $0.label.localizedCaseInsensitiveContains("shortcut") || $0.label.contains("Right ⌘")
        }.map { ["identifier": $0.identifier, "label": $0.label, "role": $0.role,
                 "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }
        checks["settings_has_open_source_footer"] = settings.contains { $0.label == "Open source on GitHub" }
        let menu = settings.first(where: {
            ($0.identifier == "settings.menu.Sidekick shortcut" || $0.label == "Sidekick shortcut") && $0.frame.width >= 100
        })
        checks["shortcut_has_full_width_hit_target"] = menu != nil
        guard let menu else { throw Failure.accessibility }
        checks["shortcut_right_padding_opens_menu"] = try await openMenu(window: window, screenPoint: CGPoint(x: menu.frame.maxX - 3, y: menu.frame.midY))
        checks["shortcut_left_padding_opens_menu"] = try await openMenu(window: window, screenPoint: CGPoint(x: menu.frame.minX + 4, y: menu.frame.midY))
        checks["shortcut_selection_preserved"] = UserDefaults.standard.string(forKey: ShortcutPreferences.storageKey) == shortcut
        checks["saved_instructions_preserved"] = try SidekickInstructionStore.read().text == memory
        checks["five_own_window_captures"] = captures.count == 5
        completed = true
        return checks
    }

    /// The real Home controls, native popovers and notch, with synthetic local preferences only.
    static func runDiscovery(app: AppState, root: URL) async throws -> [String: Bool] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SENTIENT_SELFTEST"] == "sidekickapp", environment["LAB_SIDEKICK_STAGE"] == "ui-discovery",
              let configuredRoot = environment["LAB_SIDEKICK_ROOT"], root.isFileURL,
              root.standardizedFileURL == URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath() else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        let run = app.commandCoordinator.run
        guard !run.isRunning, run.interaction == nil, let store = run.conversation.store else { throw Failure.unavailable }
        let before = try store.latestSequence
        let memory = try SidekickInstructionStore.read().text
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ProcessingPlan.initialCompletedKey)
        defaults.removeObject(forKey: SidekickDiscovery.readyHintSeenKey)
        defaults.removeObject(forKey: SidekickDiscovery.notchUsesKey)
        defaults.set(true, forKey: DoubleTap.enabledKey)
        defaults.set(true, forKey: NotchPreferences.clickEnabledKey)
        defaults.set(ShortcutKey.rightCommand.rawValue, forKey: ShortcutPreferences.storageKey)
        run.preventsTaskExecutionForUIFixture = true
        MainNavigation.shared.reset()
        let presentation = app.sidekickPresentation
        presentation.surface = .suggestions
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        var phase = "mount"
        var diagnostics: [String: Any] = [:]
        var focusTransitions: [[String: Any]] = []
        var completed = false
        defer {
            let manifest: [String: Any] = ["schema": 1, "stage": "ui-discovery", "captures": captures,
                "checks": checks, "phase": phase, "diagnostics": diagnostics, "focus_transitions": focusTransitions, "completed": completed, "provider_calls": 0,
                "capture_scope": "current_process_windows_only"]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("discovery-manifest.json"), options: .atomic)
            }
        }
        func home() -> AnyView { AnyView(HomeView(deck: .jesai).environment(app).preferredColorScheme(.dark)) }
        let host = NSHostingView(rootView: home())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sidekick discovery fixture · synthetic content"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.contentView = host
        let notch = NotchWindowController(coordinator: app.commandCoordinator)
        defer { notch.shutdownForTesting(); window.close() }
        func recordFocus(_ transition: String, target: NSWindow? = nil, attempt: Int = 0) {
            focusTransitions.append([
                "transition": transition, "phase": phase, "attempt": attempt,
                "uptime": ProcessInfo.processInfo.systemUptime, "app_active": NSApp.isActive,
                "home_visible": window.isVisible, "home_key": window.isKeyWindow,
                "home_active": presentation.windowActive, "key_window": NSApp.keyWindow?.windowNumber ?? -1,
                "target_window": target?.windowNumber ?? -1,
                "target_visible": target?.isVisible ?? false, "target_key": target?.isKeyWindow ?? false,
                "target_can_become_key": target?.canBecomeKey ?? false,
                "own_windows": NSApp.windows.map {
                    ["number": $0.windowNumber, "visible": $0.isVisible, "key": $0.isKeyWindow,
                     "main": $0.isMainWindow, "class": String(describing: type(of: $0))] as [String: Any]
                }
            ])
        }
        func foreground(_ target: NSWindow, transition: String) async throws {
            recordFocus(transition + ".begin", target: target)
            var stable = 0
            for attempt in 1...30 {
                if !NSApp.isActive || !target.isVisible || !target.isKeyWindow || NSApp.keyWindow !== target {
                    stable = 0
                    target.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                try await settle(100)
                recordFocus(transition + ".poll", target: target, attempt: attempt)
                if NSApp.isActive && target.isVisible && target.isKeyWindow && NSApp.keyWindow === target {
                    stable += 1
                    // Let any queued AppKit focus restoration run before the next action.
                    if stable >= 2 { return }
                } else { stable = 0 }
            }
            recordFocus(transition + ".failed", target: target)
            throw Failure.foreground
        }
        func reveal(_ transition: String) async throws {
            try await foreground(window, transition: transition)
        }
        func describe(_ values: [Element]) -> [[String: Any]] {
            values.map { ["identifier": $0.identifier, "label": $0.label, "role": $0.role,
                         "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }
        }
        func find(_ identifier: String, in values: [Element]? = nil) -> Element? {
            let candidates = (values ?? elements(host)).filter { $0.identifier == identifier && $0.frame.width > 0 && $0.frame.height > 0 }
            // SwiftUI forwards identifiers to wrapper/label nodes. Use the native control's
            // actual frame for click geometry, rather than whichever descendant walks first.
            return candidates.first { $0.role == NSAccessibility.Role.button.rawValue }
                ?? candidates.first { $0.role == NSAccessibility.Role.popUpButton.rawValue }
                ?? candidates.first
        }
        var hintObservationStartedAt = ProcessInfo.processInfo.systemUptime
        func hintState() -> [String: Any] {
            ["seen_at": defaults.double(forKey: SidekickDiscovery.readyHintSeenKey),
             "completed_at": defaults.double(forKey: ProcessingPlan.initialCompletedKey),
             "home_active": presentation.windowActive, "window_visible": window.isVisible,
             "app_active": NSApp.isActive, "home_key": window.isKeyWindow,
             "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - hintObservationStartedAt) * 1000),
             "key_window": NSApp.keyWindow?.windowNumber ?? -1,
             "hint_elements": describe(elements(host).filter { $0.identifier == "doubleTap.readyHint" })]
        }
        func lesson() -> NSView? {
            NSApp.windows.filter { $0.isVisible && $0 !== window }.compactMap(\.contentView)
                .first { view in elements(view).contains { $0.identifier == "doubleTap.lesson" } }
        }
        func click(_ identifier: String) async throws {
            try await reveal("click." + identifier)
            guard let element = find(identifier) else { throw Failure.accessibility }
            try postClick(window: window, screenPoint: CGPoint(x: element.frame.midX, y: element.frame.midY))
            try await settle(350)
            recordFocus("click." + identifier + ".delivered", target: window)
        }
        func dismissLesson() async throws {
            guard lesson() != nil else { throw Failure.accessibility }
            // Popover windows forward key status to their parent. Dismiss using the normal
            // click-away gesture on an empty corner of our own Home, with no fake focus state.
            let frame = window.convertToScreen(host.convert(host.bounds, to: nil))
            recordFocus("dismiss_lesson.outside_click", target: window)
            try postClick(window: window, screenPoint: CGPoint(x: frame.minX + 7, y: frame.minY + 7))
            for _ in 0..<25 {
                if lesson() == nil {
                    try await reveal("return_from_lesson." + phase)
                    return
                }
                try await settle(80)
            }
            recordFocus("dismiss_lesson.failed", target: window)
            throw Failure.accessibility
        }
        window.center(); try await reveal("initial_home")
        try await settle(800)
        let wide = elements(host)
        diagnostics["wide_header"] = describe(wide.filter { $0.identifier.hasPrefix("navigation.") || $0.identifier.hasPrefix("sidekick.notch") })
        checks["wide_double_tap_before_analysis"] = {
            guard let button = find("navigation.doubleTap"), let analysis = find("navigation.analysis") else { return false }
            return button.frame.maxX < analysis.frame.minX && abs(button.frame.midY - analysis.frame.midY) < 4
        }()
        checks["wide_proactive_has_notch_cue"] = find("sidekick.notchHint") != nil && find("sidekick.proactive") == nil
        checks["wide_has_no_ready_hint_before_analysis"] = !wide.contains { $0.identifier == "doubleTap.readyHint" }
        captures.append(try await capture(host, name: "discovery-01-home-wide", directory: directory))
        phase = "waiting_lesson"
        // Change the actual preference while Home stays mounted; the lesson must follow it.
        ShortcutPreferences.save(.leftOption)
        defaults.set(false, forKey: NotchPreferences.clickEnabledKey)
        try await settle(250)
        try await click("navigation.doubleTap")
        guard let waitingLesson = lesson() else { throw Failure.accessibility }
        let waiting = elements(waitingLesson)
        diagnostics["waiting_lesson"] = describe(waiting)
        // The lesson root's identifier is inherited by SwiftUI's children on this SDK.
        // Verify the actual displayed state text and native action instead of a lost child ID.
        checks["native_click_opens_waiting_lesson"] = waiting.contains { $0.label == "Ready after your first analysis." }
        checks["waiting_lesson_reflects_left_option"] = waiting.contains { $0.label.contains(ShortcutKey.leftOption.label) }
        checks["waiting_lesson_has_analysis_action"] = waiting.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "View analysis" }
        captures.append(try await capture(host, name: "discovery-02-waiting-lesson", directory: directory, includingChild: waitingLesson.window))
        try await dismissLesson()

        phase = "imported_knowledge_lesson"
        let importedNote = VaultGenerator.vaultRoot.appendingPathComponent("DoubleTapImportedFixture.md")
        try "# Imported fixture\nUseful personal project context.".write(to: importedNote, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: importedNote) }
        try await click("navigation.doubleTap")
        guard let importedLesson = lesson() else { throw Failure.accessibility }
        let importedElements = elements(importedLesson)
        checks["imported_knowledge_shows_ready_instructions"] = importedElements.contains {
            $0.label.contains("Click a reply box, then tap")
        } && !importedElements.contains { $0.label == "Ready after your first analysis." }
        checks["imported_knowledge_preserves_analysis_milestone"] = ProcessingPlan.initialCompletedAt() == nil
        try await dismissLesson()
        try FileManager.default.removeItem(at: importedNote)
        try await click("navigation.doubleTap")
        guard let removedLesson = lesson() else { throw Failure.accessibility }
        checks["removed_import_restores_setup_lesson"] = elements(removedLesson).contains { $0.label == "Ready after your first analysis." }
        try await dismissLesson()

        phase = "compact_chat"
        presentation.surface = .conversation
        await presentation.load(.latest, conversation: run.conversation)
        window.setContentSize(NSSize(width: 840, height: 820))
        try await settle(700)
        let compact = elements(host)
        let identifiers = ["sidekick.proactive", "sidekick.search", "sidekick.clearChat", "navigation.doubleTap", "navigation.analysis", "navigation.settings"]
        var controls = identifiers.compactMap { find($0, in: compact) }
        if let knowledge = compact.first(where: { $0.label == "Knowledge" && $0.role == NSAccessibility.Role.button.rawValue && $0.frame.width > 0 }) { controls.append(knowledge) }
        diagnostics["compact_controls"] = describe(controls)
        diagnostics["compact_header_candidates"] = describe(compact.filter {
            identifiers.contains($0.identifier) || $0.label == "Knowledge"
        })
        let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        diagnostics["compact_content_frame"] = [contentFrame.minX, contentFrame.minY, contentFrame.width, contentFrame.height]
        checks["compact_chat_keeps_double_tap_and_all_controls"] = controls.count == identifiers.count + 1
        checks["compact_chat_has_no_notch_cue"] = !compact.contains { $0.identifier == "sidekick.notchHint" }
        checks["compact_header_controls_do_not_overlap"] = controls.indices.allSatisfy { first in
            contentFrame.contains(controls[first].frame) && controls.indices.allSatisfy { second in
                first == second || !controls[first].frame.intersects(controls[second].frame)
            }
        }
        captures.append(try await capture(host, name: "discovery-03-compact-chat", directory: directory))

        phase = "analysis_window_in_front"
        let progressWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        progressWindow.title = "Analysis window fixture"
        progressWindow.isReleasedWhenClosed = false
        progressWindow.center()
        defer { progressWindow.close() }
        try await foreground(progressWindow, transition: "analysis_window_front")
        try await settle(350)
        defaults.set(Date().timeIntervalSince1970, forKey: ProcessingPlan.initialCompletedKey)
        try await settle(1100)
        recordFocus("analysis_window_after_completion", target: progressWindow)
        checks["analysis_window_case_keeps_home_visible_but_not_key"] = window.isVisible
            && progressWindow.isKeyWindow && NSApp.isActive
        checks["analysis_window_does_not_consume_ready_hint"] = find("doubleTap.readyHint") == nil
            && defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == 0
        window.orderOut(nil)
        progressWindow.close()
        recordFocus("analysis_window_closed_home_hidden", target: window)
        defaults.removeObject(forKey: ProcessingPlan.initialCompletedKey)

        phase = "hidden_completion"
        presentation.surface = .suggestions
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.orderOut(nil)
        try await settle(350)
        let completion = Date().timeIntervalSince1970
        defaults.set(completion, forKey: ProcessingPlan.initialCompletedKey)
        try await settle(1000)
        checks["hidden_completion_does_not_acknowledge"] = defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == 0
        checks["hidden_home_is_inactive"] = !presentation.windowActive
        recordFocus("hidden_completion_waited", target: window)
        try await reveal("home_after_hidden_completion")
        try await settle(250)
        let keyWindow = NSApp.keyWindow
        let responder = window.firstResponder
        try await settle(850)
        checks["reactivation_shows_ready_hint"] = find("doubleTap.readyHint") != nil
        checks["ready_hint_does_not_take_focus"] = NSApp.keyWindow === keyWindow && window.firstResponder === responder
        recordFocus("ready_hint_displayed", target: window)
        captures.append(try await capture(host, name: "discovery-04-ready-hint", directory: directory))
        phase = "interrupted_hint"
        window.orderOut(nil)
        try await settle(500)
        checks["interrupted_hint_remains_pending"] = defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == 0
        recordFocus("hint_hidden_before_acknowledgement", target: window)
        try await reveal("home_after_hint_interruption")
        try await settle(1100)
        checks["interrupted_hint_reappears"] = find("doubleTap.readyHint") != nil
        recordFocus("interrupted_hint_reappeared", target: window)
        try await click("navigation.doubleTap")
        guard let readyLesson = lesson() else { throw Failure.accessibility }
        let ready = elements(readyLesson)
        checks["ready_click_acknowledges_completion"] = defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == completion
        diagnostics["ready_lesson"] = describe(ready)
        checks["ready_click_opens_correct_instructions"] = ready.contains {
            $0.label.contains("Click a reply box, then tap") && $0.label.contains(ShortcutKey.leftOption.label)
        } && !ready.contains { $0.label == "Ready after your first analysis." }
        captures.append(try await capture(host, name: "discovery-05-ready-lesson", directory: directory, includingChild: readyLesson.window))
        try await dismissLesson()
        phase = "remount"
        host.rootView = AnyView(Color.black)
        try await settle(120)
        host.rootView = home()
        try await reveal("home_remounted")
        try await settle(1100)
        checks["remount_does_not_repeat_acknowledged_hint"] = find("doubleTap.readyHint") == nil
            && defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == completion
        phase = "automatic_acknowledgement"
        try await reveal("home_before_automatic_hint")
        let anotherCompletion = completion + 1
        hintObservationStartedAt = ProcessInfo.processInfo.systemUptime
        defaults.set(anotherCompletion, forKey: ProcessingPlan.initialCompletedKey)
        try await settle(1100)
        checks["new_completion_gets_its_own_hint"] = find("doubleTap.readyHint") != nil
        var automaticSamples: [[String: Any]] = [hintState()]
        // Observe the real acknowledgement with a bounded margin for native presentation.
        // Do not treat a completed animation's lingering AX node as a timer failure.
        for _ in 0..<24 {
            try await settle(300)
            automaticSamples.append(hintState())
            if defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == anotherCompletion,
               find("doubleTap.readyHint") == nil { break }
        }
        diagnostics["automatic_hint_samples"] = automaticSamples
        checks["automatic_hint_viewing_stays_active"] = automaticSamples.allSatisfy {
            $0["home_active"] as? Bool == true && $0["app_active"] as? Bool == true && $0["home_key"] as? Bool == true
        }
        checks["full_viewing_auto_acknowledges_and_hides"] = defaults.double(forKey: SidekickDiscovery.readyHintSeenKey) == anotherCompletion
            && find("doubleTap.readyHint") == nil

        phase = "notch_action"
        notch.start()
        try await settle(300)
        try await click("sidekick.notchHint")
        try await settle(650)
        diagnostics["notch_state"] = ["phase": String(describing: app.commandCoordinator.phase),
            "visible": notch.panelForTesting?.isVisible ?? false, "key_window": NSApp.keyWindow?.windowNumber ?? -1]
        checks["home_cue_opens_real_notch_typing"] = app.commandCoordinator.phase == .typing && notch.panelForTesting?.isVisible == true
        checks["notch_click_preference_stays_disabled"] = !defaults.bool(forKey: NotchPreferences.clickEnabledKey)
        guard let panel = notch.panelForTesting, let notchView = panel.contentView, panel.isVisible else { throw Failure.accessibility }
        captures.append(try await capture(notchView, name: "discovery-06-real-notch", directory: directory))
        app.commandCoordinator.dismissTyping()
        try await settle(700)
        try await reveal("home_after_notch_dismissed")
        // Simulate the persisted counter's three successful notch-use notifications. Never
        // submit synthetic work merely to exercise a local discovery preference.
        for _ in 0..<SidekickDiscovery.notchLearningUses { SidekickDiscovery.recordNotchUse() }
        try await settle(400)
        checks["three_uses_retire_notch_cue"] = defaults.integer(forKey: SidekickDiscovery.notchUsesKey) == 3
            && find("sidekick.notchHint") == nil
        checks["discovery_does_not_start_analysis"] = !app.processing.isBusy
        let after = try store.latestSequence
        checks["discovery_does_not_run_tasks_or_change_history"] = !run.isRunning && run.interaction == nil && after == before
        checks["saved_instructions_preserved"] = try SidekickInstructionStore.read().text == memory
        checks["six_own_window_captures"] = captures.count == 6
        completed = true; phase = "complete"
        return checks
    }

    static func runInvitation(app: AppState, root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-invitation",
              let configuredRoot = ProcessInfo.processInfo.environment["LAB_SIDEKICK_ROOT"],
              root.standardizedFileURL == URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: NotchPreferences.clickEnabledKey)
        defaults.set(ShortcutKey.rightCommand.rawValue, forKey: ShortcutPreferences.storageKey)
        var filmOrigin = "https://sentient-os.ai"
        let originFile = root.appendingPathComponent("onboarding-film-origin.txt")
        if let candidate = try? String(contentsOf: originFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: candidate), ["localhost", "127.0.0.1", "sentient-os.ai"].contains(url.host ?? ""),
           ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil {
            filmOrigin = candidate
        }
        defaults.set(filmOrigin + "/onboarding?end=0.707&duration=1&delay=0", forKey: "dev.film.url")
        let coordinator = app.commandCoordinator
        coordinator.run.preventsTaskExecutionForUIFixture = true
        let notch = NotchWindowController(coordinator: coordinator)
        notch.start()
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        var completed = false
        defer {
            let manifest: [String: Any] = ["checks": checks, "captures": captures, "completed": completed,
                "provider_calls": 0, "capture_scope": "current_process_windows_only",
                "render_mode": FileManager.default.fileExists(atPath: root.appendingPathComponent("onboarding-offscreen-render").path) ? "controlled-occlusion" : "onscreen"]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("invitation-manifest.json"))
            }
            coordinator.disarmOnboardingNotchDemo(); coordinator.dismissTyping(); notch.shutdownForTesting()
        }
        func film() -> AnyView {
            AnyView(OnboardingCanvas(scale: 1) {
                OnboardingFilmView.invitationForTesting()
            }.environment(app).environment(\.accessibilityEnabled, true).preferredColorScheme(.dark))
        }
        let host = NSHostingView(rootView: film())
        let window = FilmFixtureWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sidekick onboarding · isolated preview"
        window.rendersWhileOccluded = FileManager.default.fileExists(atPath: root.appendingPathComponent("onboarding-offscreen-render").path)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; window.center()
        defer { window.close() }
        func reveal() async throws {
            var stable = 0
            for _ in 0..<45 {
                if !window.isKeyWindow || !NSApp.isActive {
                    stable = 0
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                }
                try await settle(100)
                if window.isKeyWindow && NSApp.isActive { stable += 1 } else { stable = 0 }
                if stable >= 8 { return }
            }
            throw Failure.foreground
        }
        func probe(_ view: NSView) -> OnboardingNotchPointer.Probe? {
            if let found = view as? OnboardingNotchPointer.Probe { return found }
            return view.subviews.lazy.compactMap { probe($0) }.first
        }
        func waitForInvitation() async throws {
            for _ in 0..<50 {
                if probe(host) != nil { try await settle(500); return }
                try await settle(400)
            }
            func findWeb(_ view: NSView) -> WKWebView? {
                if let web = view as? WKWebView { return web }
                return view.subviews.lazy.compactMap { findWeb($0) }.first
            }
            if let web = findWeb(host) {
                let diagnostic = try? await web.evaluateJavaScript("JSON.stringify({visibility:document.visibilityState,url:location.href,scroll:scrollY,height:innerHeight,film:document.querySelector('main > section')?.offsetHeight,autopilot:typeof window.__sentientAutopilot,body:document.body.innerText.slice(0,300)})")
                Log("Invitation film diagnostic: \(String(describing: diagnostic))")
                Log("Invitation native geometry: host=\(host.frame), web=\(web.frame), hidden=\(web.isHiddenOrHasHiddenAncestor), alpha=\(web.alphaValue), visible=\(web.visibleRect), windowVisible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue)")
                var parent: NSView? = web
                while let current = parent { Log("Invitation ancestor: \(type(of: current)) frame=\(current.frame) hidden=\(current.isHidden) alpha=\(current.alphaValue)"); parent = current.superview }
            }
            _ = try? await capture(host, name: "invitation-failure", directory: directory)
            throw Failure.unavailable
        }
        try await reveal()
        try await waitForInvitation()
        try await reveal()
        guard let pointerProbe = probe(host) else { throw Failure.unavailable }
        Log("Invitation geometry: bounds=\(pointerProbe.bounds), root=\(window.convertToScreen(pointerProbe.convert(pointerProbe.bounds, to: nil))), screen=\(String(describing: window.screen?.frame)), key=\(window.isKeyWindow)")
        let physical = OnboardingNotchPointer.hasPhysicalTarget
        checks["instruction_matches_actual_hardware"] = elements(host).contains {
            $0.label == (physical ? "Click your notch" : "Press right Command")
        }
        checks["real_demo_is_armed"] = coordinator.onboardingDemoArmed
        checks["pointer_does_not_take_keyboard_focus"] = window.isKeyWindow
        if physical {
            guard let pointer = pointerProbe.pointer, let screen = window.screen, let notchSize = screen.notchSize else { throw Failure.unavailable }
            checks["pointer_is_visible_and_click_through"] = pointer.isVisible && pointer.ignoresMouseEvents && !pointer.canBecomeKey
            checks["arrow_tip_targets_real_camera_cutout"] = abs(pointer.frame.midX - screen.frame.midX) < 1
                && abs(pointer.frame.maxY - 8 - (screen.frame.maxY - notchSize.height - 10)) < 1
            let cta = elements(host).first { $0.identifier == "onboarding.sidekick.instruction" && $0.role == NSAccessibility.Role.button.rawValue }
            checks["arrow_and_cta_share_centerline"] = cta.map { abs($0.frame.midX - pointer.frame.midX) < 1 } == true
            checks["arrow_has_exact_button_clearance"] = cta.map { abs(pointer.frame.minY + 8 - $0.frame.maxY - 12) < 1 } == true
            captures.append(try await captureDisplay(windows: [window, pointer], screen: screen,
                name: "invitation-01-physical-notch", directory: directory))
            let anchored = pointer.frame
            window.setFrameOrigin(CGPoint(x: window.frame.minX + 35, y: window.frame.minY - 25))
            try await settle(200)
            checks["arrow_stays_at_hardware_when_app_moves"] = abs(pointer.frame.midX - anchored.midX) < 1
                && abs(pointer.frame.maxY - anchored.maxY) < 1
            let movedCTA = elements(host).first { $0.identifier == "onboarding.sidekick.instruction" && $0.role == NSAccessibility.Role.button.rawValue }
            Log("Invitation moved: CTA=\(String(describing: movedCTA?.frame)), pointer=\(pointer.frame), probe=\(window.convertToScreen(pointerProbe.convert(pointerProbe.bounds, to: nil))), visible=\(pointer.isVisible)")
            checks["moved_cta_preserves_arrow_alignment"] = movedCTA.map { abs($0.frame.midX - pointer.frame.midX) < 1
                && abs(pointer.frame.minY + 8 - $0.frame.maxY - 12) < 1 } == true
            let windowedFrame = window.frame
            window.setFrame(screen.visibleFrame, display: true)
            try await reveal()
            let largeCTA = elements(host).first { $0.identifier == "onboarding.sidekick.instruction" && $0.role == NSAccessibility.Role.button.rawValue }
            checks["maximized_cta_preserves_arrow_clearance"] = largeCTA.map { abs($0.frame.midX - pointer.frame.midX) < 1
                && abs(pointer.frame.minY + 8 - $0.frame.maxY - 12) < 1 } == true
            captures.append(try await captureDisplay(windows: [window, pointer], screen: screen,
                name: "invitation-04-maximized", directory: directory))
            window.setFrame(windowedFrame, display: true)
            window.orderOut(nil); try await settle(200)
            checks["pointer_hides_with_onboarding_window"] = !pointer.isVisible
            try await reveal()
            checks["pointer_returns_without_taking_focus"] = pointer.isVisible && window.isKeyWindow
        } else {
            checks["no_false_hardware_arrow"] = pointerProbe.pointer?.isVisible != true
            captures.append(try await capture(host, name: "invitation-01-hardware-fallback", directory: directory))
            captures.append(try await capture(host, name: "invitation-04-no-hardware", directory: directory))
        }
        for frame in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 600, width: 1728, height: 1117)] {
            let button = CGRect(x: frame.midX - 100, y: frame.maxY - 210, width: 200, height: 48)
            let placement = OnboardingNotchPointer.panelFrame(screen: frame, notchHeight: 32, button: button)!
            checks["screen_origin_\(Int(frame.minX))"] = placement.midX == frame.midX && placement.maxY == frame.maxY - 34
                && placement.minY + 8 == button.maxY + 12
        }

        // Wrong-side feedback uses actual local NSEvents in this owned window.
        // The events never enter the global keyboard stream or any other application.
        func hintProbe(_ view: NSView) -> OnboardingWrongCommandMonitor.Probe? {
            if let found = view as? OnboardingWrongCommandMonitor.Probe { return found }
            return view.subviews.lazy.compactMap { hintProbe($0) }.first
        }
        func modifier(_ down: Bool) throws {
            let flags = down ? NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue
                | UInt(ShortcutKey.leftCommand.deviceBit)) : []
            guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: ShortcutKey.leftCommand.keyCode) else { throw Failure.accessibility }
            NSApp.postEvent(event, atStart: false)
        }
        func leftCommandTap() async throws {
            try modifier(true); try await settle(45); try modifier(false); try await settle(45)
        }
        guard let sidekickHint = hintProbe(host) else { throw Failure.unavailable }
        try await leftCommandTap()
        checks["wrong_command_lights_sidekick_instruction"] = sidekickHint.hint.isActive
            && sidekickHint.hint.pulseCount == 1 && coordinator.onboardingDemoArmed && !coordinator.run.isRunning
        try await settle(350)
        captures.append(try await capture(host, name: "shortcut-sidekick-glow", directory: directory))
        try await settle(900)
        checks["sidekick_correction_expires"] = !sidekickHint.hint.isActive
        let beforeChord = sidekickHint.hint.pulseCount
        try modifier(true); try await settle(30)
        guard let chord = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 8) else { throw Failure.accessibility }
        NSApp.postEvent(chord, atStart: false); try await settle(30); try modifier(false); try await settle(80)
        checks["modified_key_does_not_flash_correction"] = sidekickHint.hint.pulseCount == beforeChord
        ShortcutPreferences.setRecording(true)
        try await leftCommandTap()
        checks["recording_does_not_flash_correction"] = sidekickHint.hint.pulseCount == beforeChord
        ShortcutPreferences.setRecording(false)
        try await leftCommandTap()
        let beforeFocusChange = sidekickHint.hint.pulseCount
        try modifier(true); try await settle(30)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 120, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.title = "Owned focus check"
        other.makeKeyAndOrderFront(nil); try await settle(80)
        checks["focus_loss_clears_correction"] = !sidekickHint.hint.isActive
        try modifier(false); try await settle(50)
        checks["another_window_cannot_trigger_correction"] = sidekickHint.hint.pulseCount == beforeFocusChange
        other.close(); try await reveal()

        // Exercise the keyboard fallback in the same native film, including compact layout.
        defaults.set(false, forKey: NotchPreferences.clickEnabledKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await reveal()
        checks["disabled_notch_clicks_show_real_keyboard_instruction"] = elements(host).contains { $0.label == "Press right Command" }
            && pointerProbe.pointer?.isVisible != true
        captures.append(try await capture(host, name: "invitation-02-right-command", directory: directory))
        checks["keyboard_capture_is_full_size"] = (captures.last?["width"] as? Int ?? 0) >= 1000
        host.rootView = AnyView(Color.black); try await settle(350)
        checks["pointer_resources_removed_on_step_exit"] = pointerProbe.pointer == nil
        window.setContentSize(CGSize(width: 640, height: 540))
        host.rootView = film()
        try await reveal()
        try await waitForInvitation()
        try await reveal()
        captures.append(try await capture(host, name: "invitation-03-compact", directory: directory))
        checks["compact_instruction_visible"] = elements(host).contains { $0.label == "Press right Command" }
        checks["no_explanatory_screen"] = !elements(host).contains { $0.label.contains("camera cutout") || $0.label == "YOUR TURN" }
        let key = elements(host).first { $0.label == "Press right Command" && $0.role == NSAccessibility.Role.button.rawValue }
        guard let key else { throw Failure.accessibility }
        try postClick(window: window, screenPoint: CGPoint(x: key.frame.midX, y: key.frame.midY))
        try await settle(450)
        checks["key_opens_actual_notch_demo"] = coordinator.phase == .typing && notch.panelForTesting?.isVisible == true
        checks["instruction_yields_when_notch_opens"] = !elements(host).contains { $0.label == "Press right Command" }
        checks["no_real_task_started"] = !coordinator.run.isRunning
        window.setContentSize(CGSize(width: 1100, height: 760))
        window.center()
        let firstTaskBefore = defaults.bool(forKey: PersonalSetupProgress.firstTaskKey)
        for _ in 0..<400 {
            if coordinator.run.isRunning && coordinator.run.isDemo { break }
            try await settle(10)
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        checks["demo_starts_with_computer_use_caption"] = coordinator.run.statusLine == "Starting computer use…"
        for _ in 0..<150 {
            if coordinator.run.onboardingDemoBeat != .read { break }
            try await settle(10)
        }
        let startingDuration = ProcessInfo.processInfo.systemUptime - startedAt
        Log("Restaurant starting caption duration: \(startingDuration)")
        checks["starting_caption_lasts_half_a_second"] = (0.35...0.68).contains(startingDuration)
            && coordinator.run.onboardingDemoBeat == .remember
        func waitForBeat(_ beat: OnboardingRestaurantStory.Beat) async throws {
            for _ in 0..<150 {
                if let current = coordinator.run.onboardingDemoBeat, current.index >= beat.index { return }
                try await settle(200)
            }
            throw Failure.unavailable
        }
        for (beat, name) in [(OnboardingRestaurantStory.Beat.remember, "restaurant-05-remembering"),
                             (.time, "restaurant-06-booking"), (.confirmed, "restaurant-07-confirmed"),
                             (.done, "restaurant-08-replied")] {
            try await waitForBeat(beat)
            try await settle(beat == .remember ? 950 : 350)
            checks["film_narrates_" + beat.rawValue] = (coordinator.run.onboardingDemoBeat?.index ?? -1) >= beat.index
            if beat == .remember { checks["native_remembering_is_weekend_plan"] = coordinator.run.remembering == "Weekend plan" }
            if let panel = notch.panelForTesting, let screen = window.screen {
                captures.append(try await captureDisplay(windows: [window, panel], screen: screen, name: name, directory: directory))
            } else { throw Failure.unavailable }
        }
        checks["scripted_run_finishes_without_provider"] = coordinator.run.isDemo && !coordinator.run.isRunning
            && coordinator.run.interaction == nil
        checks["demo_does_not_claim_first_successful_task"] = defaults.bool(forKey: PersonalSetupProgress.firstTaskKey) == firstTaskBefore
        coordinator.run.advanceOnboardingDemo(.read)
        checks["late_film_message_cannot_restart_run"] = !coordinator.run.isRunning && coordinator.run.onboardingDemoBeat == .done
        coordinator.run.startOnboardingDemo()
        coordinator.run.advanceOnboardingDemo(.remember)
        coordinator.disarmOnboardingNotchDemo()
        checks["leaving_film_cancels_demo_and_memory"] = !coordinator.run.isRunning && coordinator.run.remembering == nil
        checks["sidekick_hint_monitor_detaches"] = !sidekickHint.isMonitoring && !sidekickHint.hint.acceptsInput

        func waitButton(_ label: String) async throws -> Element {
            for _ in 0..<100 {
                if let button = elements(host, maximumDepth: 80).first(where: {
                    $0.label == label && $0.role == NSAccessibility.Role.button.rawValue && $0.frame.width > 0
                }) { return button }
                _ = await activateOwnAccessibility()
                try await settle(80)
            }
            throw Failure.accessibility
        }
        func click(_ label: String) async throws {
            let button = try await waitButton(label)
            try postClick(window: window, screenPoint: CGPoint(x: button.frame.midX, y: button.frame.midY))
            try await settle(100)
        }
        window.setContentSize(CGSize(width: 1180, height: 880)); window.center()
        try await click("Continue")
        // Both real Double Tap samples use the same correction. Wrong taps cannot
        // draft or advance either sample; ordinary clicks still complete the lesson.
        for (index, name) in ["shortcut-double-tap-email-glow", "shortcut-double-tap-messages-glow"].enumerated() {
            _ = try await waitButton("right Command key")
            var currentHint: OnboardingWrongCommandMonitor.Probe?
            for _ in 0..<60 {
                if let found = hintProbe(host), found.isMonitoring, found.hint.acceptsInput { currentHint = found; break }
                try await settle(60)
            }
            guard let currentHint else {
                func logHints(_ view: NSView) {
                    if let probe = view as? OnboardingWrongCommandMonitor.Probe {
                        Log("Hint probe: monitoring=\(probe.isMonitoring), accepts=\(probe.hint.acceptsInput), active=\(probe.hint.isActive), window=\(String(describing: probe.window?.title))")
                    }
                    view.subviews.forEach(logHints)
                }
                logHints(host)
                Log("Double Tap hint AX: \(elements(host, maximumDepth: 80).map(\.label))")
                _ = try? await capture(host, name: "shortcut-hint-failure", directory: directory)
                throw Failure.unavailable
            }
            let before = currentHint.hint.pulseCount
            try await leftCommandTap(); try await leftCommandTap()
            checks["wrong_double_tap_only_hints_\(index)"] = currentHint.hint.isActive
                && currentHint.hint.pulseCount == before + 1
            try await settle(280)
            captures.append(try await capture(host, name: name, directory: directory))
            try await settle(900)
            checks["double_tap_hint_expires_\(index)"] = !currentHint.hint.isActive
            let button = try await waitButton("right Command key")
            let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
            try postClick(window: window, screenPoint: point)
            try await settle(80)
            try postClick(window: window, screenPoint: point)
            try await settle(120)
            checks["correction_stops_during_drafting_\(index)"] = !currentHint.isMonitoring
            let count = currentHint.hint.pulseCount
            try await leftCommandTap()
            checks["drafting_ignores_wrong_key_\(index)"] = currentHint.hint.pulseCount == count
            if index == 0 { try await click("Next: iMessage demo") }
        }
        _ = try await waitButton("Continue")
        checks["double_tap_completes_after_correct_input"] = true
        completed = true
        return checks
    }

    static func runSmallOnboarding(app: AppState, root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-small-onboarding" else { throw Failure.isolation }
        if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { throw Failure.screenLocked }
        app.commandCoordinator.run.preventsTaskExecutionForUIFixture = true
        var checks: [String: Bool] = [:]
        var captures: [[String: Any]] = []
        var completed = false
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            let manifest: [String: Any] = ["checks": checks, "captures": captures, "completed": completed, "provider_calls": 0]
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("small-onboarding-manifest.json"))
            }
        }
        // Logical display sizes, including a bottom/side Dock and a display with a negative origin.
        for (index, visible) in [CGRect(x: 0, y: 72, width: 1280, height: 704),
                                 CGRect(x: 0, y: 84, width: 1366, height: 660),
                                 CGRect(x: -1440, y: 0, width: 1340, height: 876),
                                 CGRect(x: 0, y: 70, width: 1512, height: 874)].enumerated() {
            let scale = OnboardingWindowLayout.scale(visibleSize: visible.size)
            let size = OnboardingWindowLayout.initialSize(visibleSize: visible.size)
            checks["initial_size_fits_visible_display_\(index)"] = size.height + 32 + 24 <= visible.height + 0.5
                && size.width + 24 <= visible.width + 0.5
            let fit = OnboardingWindowLayout.fittedFrame(CGRect(x: visible.minX - 90, y: visible.minY - 100,
                width: 1400, height: 950), visibleFrame: visible)
            checks["oversized_window_fits_above_dock_\(index)"] = visible.insetBy(dx: 12, dy: 12).contains(fit)
            checks["scaled_minimum_fits_initial_window_\(index)"] = OnboardingWindowLayout.minimum.width * scale <= size.width
                && OnboardingWindowLayout.minimum.height * scale <= size.height
        }
        checks["small_display_is_about_eighty_percent"] = (0.77...0.82).contains(OnboardingWindowLayout.scale(visibleSize: CGSize(width: 1280, height: 704)))
        checks["larger_display_keeps_full_size"] = OnboardingWindowLayout.scale(visibleSize: CGSize(width: 1512, height: 900)) == 1

        let host = NSHostingView(rootView: AnyView(Color.black))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 650),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Small-screen onboarding · isolated preview"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua); window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func setViewport(_ size: CGSize) {
            // SwiftUI's scene size describes usable content. This AppKit fixture uses a
            // full-size content view, so explicitly add its titlebar to match that proposal.
            let titlebar = window.frame.height - window.contentLayoutRect.height
            window.setContentSize(CGSize(width: size.width, height: size.height + titlebar))
        }
        var continued = 0
        for (index, visibleSize) in [CGSize(width: 1280, height: 704), CGSize(width: 1366, height: 660)].enumerated() {
            let scale = OnboardingWindowLayout.scale(visibleSize: visibleSize)
            let size = OnboardingWindowLayout.initialSize(visibleSize: visibleSize)
            let demo = OnboardingDoubleTapDemo.preview(sample: index == 0 ? .email : .message, completed: true)
            setViewport(size)
            host.rootView = AnyView(OnboardingCanvas(scale: scale) {
                OnboardingDoubleTapView(onContinue: { continued += 1 }, demo: demo)
            }.id(index).preferredColorScheme(.dark))
            window.center()
            for _ in 0..<20 {
                if !window.isKeyWindow || !NSApp.isActive {
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                }
                try await settle(100)
                if window.isKeyWindow && NSApp.isActive { break }
            }
            try await settle(400)
            let title = index == 0 ? "Next: iMessage demo" : "Continue"
            guard let button = elements(host).first(where: { $0.label == title && $0.role == NSAccessibility.Role.button.rawValue }) else { throw Failure.accessibility }
            let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
            checks["bottom_action_fully_visible_\(index)"] = viewport.contains(button.frame) && button.frame.minY >= viewport.minY + 4
            checks["bottom_action_remains_readable_\(index)"] = button.frame.height >= 29 && button.frame.width >= 65
            captures.append(try await capture(host, name: index == 0 ? "small-01-next-13inch" : "small-02-continue-11inch", directory: directory))
            try postClick(window: window, screenPoint: CGPoint(x: button.frame.midX, y: button.frame.midY))
            try await settle(200)
            checks["scaled_action_receives_click_\(index)"] = index == 0 ? demo.phase == .switching : continued == 1
            demo.stop()
        }
        // The production hidden-titlebar window allows the film and GitHub mark to paint
        // above the safe-area boundary. A canvas clip used to cut both in half, even at 100%.
        UserDefaults.standard.set(0, forKey: "onboarding.step")
        UserDefaults.standard.set("https://sentient-os.ai/onboarding?end=0.42&duration=1&delay=0", forKey: "dev.film.url")
        func filmWebView(_ view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { filmWebView($0) }.first
        }
        for (index, visibleSize) in [CGSize(width: 1512, height: 874), CGSize(width: 1280, height: 704)].enumerated() {
            let scale = OnboardingWindowLayout.scale(visibleSize: visibleSize)
            setViewport(OnboardingWindowLayout.initialSize(visibleSize: visibleSize))
            host.rootView = AnyView(ZStack {
                Color.black.ignoresSafeArea()
                OnboardingCanvas(scale: scale) { OnboardingView(onFinished: {}) }
            }.environment(app).id("film-\(index)").preferredColorScheme(.dark))
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            var ready = false
            for _ in 0..<60 {
                try await settle(250)
                if let web = filmWebView(host), !web.isLoading,
                   (try? await web.evaluateJavaScript("document.querySelector('.film-logo-link') !== null")) as? Bool == true,
                   elements(host).contains(where: { $0.label == "Continue" }) { ready = true; break }
            }
            guard ready else { throw Failure.unavailable }
            try await settle(1400)
            let shot = try await capture(host, name: index == 0 ? "small-03-film-14inch" : "small-04-film-13inch", directory: directory)
            captures.append(shot)
            let path = directory.appendingPathComponent((shot["name"] as! String) + ".png")
            guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path)) else { throw Failure.capture }
            let pixelsPerPoint = CGFloat(bitmap.pixelsWide) / window.frame.width
            let titlebarHeight = host.bounds.maxY - window.contentLayoutRect.maxY
            var headerPixels = 0
            // Only the centered brand lives in this titlebar strip. Window borders and
            // traffic lights are excluded, so clipped header ink cannot pass this check.
            for y in Int(4 * pixelsPerPoint)..<max(Int(4 * pixelsPerPoint), Int(titlebarHeight * pixelsPerPoint)) {
                for x in Int(CGFloat(bitmap.pixelsWide) * 0.4)..<Int(CGFloat(bitmap.pixelsWide) * 0.6) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 { headerPixels += 1 }
                }
            }
            checks["film_brand_renders_in_titlebar_\(index)"] = titlebarHeight > 0 && headerPixels > 12
            Log("Onboarding header fixture: scale=\(scale), titlebar=\(titlebarHeight), visible brand pixels=\(headerPixels)")
            if let button = elements(host).first(where: { $0.label == "Continue" && $0.role == NSAccessibility.Role.button.rawValue }) {
                checks["film_continue_visible_\(index)"] = window.convertToScreen(host.bounds).contains(button.frame)
            } else { checks["film_continue_visible_\(index)"] = false }
        }
        // The physical-notch overlay must remain in screen points while its CTA scales.
        UserDefaults.standard.set(true, forKey: NotchPreferences.clickEnabledKey)
        window.setContentSize(CGSize(width: 880, height: 656))
        host.rootView = AnyView(OnboardingCanvas(scale: 0.8) {
            ZStack { Color.black; OnboardingSidekickInvitation(onOpen: {}) }
        }.id("scaled-invitation").preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await settle(650)
        func pointerProbe(_ view: NSView) -> OnboardingNotchPointer.Probe? {
            if let result = view as? OnboardingNotchPointer.Probe { return result }
            return view.subviews.lazy.compactMap { pointerProbe($0) }.first
        }
        if OnboardingNotchPointer.hasPhysicalTarget {
            guard let probe = pointerProbe(host), let pointer = probe.pointer,
                  let cta = elements(host).first(where: { $0.identifier == "onboarding.sidekick.instruction" && $0.role == NSAccessibility.Role.button.rawValue }) else { throw Failure.accessibility }
            checks["scaled_notch_arrow_matches_cta"] = abs(cta.frame.midX - pointer.frame.midX) < 1
                && abs(pointer.frame.minY + 8 - cta.frame.maxY - 12) < 1
        }
        // Exercise the real AppKit fitting code, with no display preference changes.
        var publishedScale: CGFloat = 0
        host.rootView = AnyView(Color.black.background(OnboardingWindowFit(active: true) { publishedScale = $0 }))
        guard let screen = window.screen else { throw Failure.unavailable }
        window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - window.frame.width / 2, y: screen.visibleFrame.minY - 80))
        try await settle(350)
        checks["native_window_fit_keeps_bottom_above_dock"] = window.frame.minY >= screen.visibleFrame.minY + 11.5
        checks["native_window_fit_publishes_scale"] = publishedScale > 0 && publishedScale <= 1
        checks["no_provider_or_analysis_started"] = !app.commandCoordinator.run.isRunning && !app.processing.isBusy
        completed = true
        return checks
    }

    private static func captureDisplay(windows: [NSWindow], screen: NSScreen, name: String, directory: URL) async throws -> [String: Any] {
        let content = try await SCShareableContent.currentProcess
        let ids = windows.map { CGWindowID($0.windowNumber) }
        let owned = content.windows.filter { ids.contains($0.windowID) && $0.owningApplication?.processID == getpid() }
        guard owned.count == windows.count, let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw Failure.capture }
        let filter = SCContentFilter(display: display, including: owned)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false; configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.capture }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        return ["name": name, "file": "polish-snapshots/" + name + ".png", "bytes": png.count, "owning_process_id": getpid()]
    }

    private struct LateGiftFixture: View {
        @Namespace private var ticket
        let onClose: () -> Void
        var body: some View {
            InviteCelebration(ticketNamespace: ticket, lateGift: true, continueTitle: "Continue", onClose: onClose)
                .preferredColorScheme(.dark)
        }
    }

    static func runLateGift(root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-late-gift" else { throw Failure.isolation }
        let directory = root.appendingPathComponent("polish-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var closed = false
        let host = NSHostingView(rootView: LateGiftFixture(onClose: { closed = true }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Late gift · synthetic preview"
        window.appearance = NSAppearance(named: .darkAqua); window.isReleasedWhenClosed = false
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await settle(3000)
        let before = elements(host)
        var checks = ["late_letter_copy_visible": before.contains { $0.label.contains(InviteLateUse.message) },
                      "late_gift_does_not_offer_lifetime": !before.contains { $0.label.localizedCaseInsensitiveContains("lifetime") || $0.label.localizedCaseInsensitiveContains("forever") }]
        var captures = [try await capture(host, name: "late-gift-01-letter", directory: directory)]
        guard let button = before.first(where: { $0.label == "Enjoy Sentient!" && $0.role == NSAccessibility.Role.button.rawValue }) else { throw Failure.accessibility }
        try postClick(window: window, screenPoint: CGPoint(x: button.frame.midX, y: button.frame.midY))
        try await settle(1000)
        let after = elements(host)
        checks["saved_gift_is_not_lifetime_pass"] = !after.contains { $0.label.localizedCaseInsensitiveContains("lifetime") }
        captures.append(try await capture(host, name: "late-gift-02-saved", directory: directory))
        guard let done = after.first(where: { $0.label == "Continue" && $0.role == NSAccessibility.Role.button.rawValue }) else { throw Failure.accessibility }
        try postClick(window: window, screenPoint: CGPoint(x: done.frame.midX, y: done.frame.midY))
        try await settle(100)
        checks["gift_can_close"] = closed
        let manifest: [String: Any] = ["checks": checks, "captures": captures, "provider_calls": 0, "completed": true]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("late-gift-manifest.json"))
        return checks
    }

    static func postClick(window: NSWindow, screenPoint: CGPoint) throws {
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw Failure.accessibility }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func activity(_ recording: SidekickConversationRun, index: Int, title: String) throws {
        let item: [String: Any] = ["id": "polish-activity-\(index)", "type": "mcp_tool_call", "server": "sentient_native",
            "tool": "get_app_state", "arguments": ["app": "com.spotify.client", "description": title], "status": "completed",
            "result": ["content": [["type": "text", "text": "Synthetic fixture state."]]]]
        for kind in ["item.started", "item.completed"] {
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["type": kind, "item": item]), as: UTF8.self)
            try recording.observe(raw, streamID: recording.taskID)
        }
    }
    private static func notchView(phase: NotchPhase, metrics: NotchMetrics, activity: SidekickActivityPresentation.Step?) -> AnyView {
        AnyView(ZStack(alignment: .top) {
            Color(white: 0.055)
            NotchContent(phase: phase, readBack: nil,
                statusLine: phase == .running ? "→ sentient_native.get_app_state" : "", activity: activity,
                demoText: phase == .typing ? "Help me with this" : nil, metrics: metrics)
        }.environment(\.colorScheme, .dark))
    }
    static func settle(_ milliseconds: Int) async throws {
        await Task.yield(); try await Task.sleep(for: .milliseconds(milliseconds))
    }
    /// SwiftUI exposes semantic nodes lazily when a real assistive client reads them.
    /// Query only our process through the public AX API, off-main so AppKit can answer.
    /// Include scroll contents/visible children: warming only the native window/footer can
    /// otherwise leave a newly attached sheet's choice buttons as in-process AXUnknown nodes.
    static func activateOwnAccessibility() async -> Int {
        let pid = getpid()
        return await Task.detached(priority: .userInitiated) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
            guard result == .success, let windows = raw as? [AXUIElement] else { return Int(result.rawValue) }
            let deadline = Date().addingTimeInterval(3)
            var pending = windows, visited: [AXUIElement] = []
            var index = 0
            while index < pending.count, visited.count < 192, Date() < deadline {
                let node = pending[index]; index += 1
                guard !visited.contains(where: { CFEqual($0, node) }) else { continue }
                visited.append(node)
                AXUIElementSetMessagingTimeout(node, 0.15)
                for attribute in [kAXRoleAttribute, kAXIdentifierAttribute] {
                    var value: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
                }
                for attribute in [kAXChildrenAttribute, kAXContentsAttribute, kAXVisibleChildrenAttribute] {
                    guard Date() < deadline else { break }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(node, attribute as CFString, &children) == .success,
                       let values = children as? [AXUIElement] {
                        pending.append(contentsOf: values.prefix(32))
                    }
                }
            }
            return Int(result.rawValue)
        }.value
    }

    static func elements(_ view: NSView, maximumDepth: Int = 35) -> [Element] {
        var result: [Element] = []
        var visited = Set<ObjectIdentifier>()
        func text(_ value: Any?) -> String? {
            let value = (value as? NSAttributedString)?.string ?? (value as? String)
            return value?.isEmpty == false ? value : nil
        }
        func enabled(_ value: Any) -> Bool? {
            guard let node = value as? NSObject,
                  node.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
                    || node.responds(to: NSSelectorFromString("accessibilityEnabled")) else { return nil }
            return node.value(forKey: "accessibilityEnabled") as? Bool
        }
        @MainActor func walk(_ value: Any, depth: Int) {
            guard depth < maximumDepth, result.count < 6000 else { return }
            let identity = ObjectIdentifier(value as AnyObject)
            guard visited.insert(identity).inserted else { return }
            var children: [Any] = []
            if let node = value as? NSView {
                result.append(Element(identifier: node.accessibilityIdentifier(),
                    label: text(node.accessibilityLabel()) ?? text(node.accessibilityTitle()) ?? text(node.accessibilityValue()) ?? "",
                    role: node.accessibilityRole()?.rawValue ?? "", frame: node.accessibilityFrame(), enabled: enabled(node)))
                children = (node.accessibilityChildren() ?? []) + node.subviews
            } else if let node = value as? NSAccessibilityElement {
                result.append(Element(identifier: node.accessibilityIdentifier() ?? "",
                    label: text(node.accessibilityLabel()) ?? text(node.accessibilityTitle()) ?? text(node.accessibilityValue()) ?? "",
                    role: node.accessibilityRole()?.rawValue ?? "", frame: node.accessibilityFrame(), enabled: enabled(node)))
                children = node.accessibilityChildren() ?? []
            } else if let node = value as? any NSAccessibilityProtocol {
                result.append(Element(identifier: node.accessibilityIdentifier() ?? "",
                    label: text(node.accessibilityLabel()) ?? text(node.accessibilityTitle()) ?? text(node.accessibilityValue()) ?? "",
                    role: node.accessibilityRole()?.rawValue ?? "", frame: node.accessibilityFrame(), enabled: enabled(node)))
                children = node.accessibilityChildren() ?? []
            } else if let node = value as? NSObject {
                // SwiftUI AccessibilityNode implements AppKit's informal getters without
                // declaring NSAccessibilityProtocol. KVC boxes its public NSRect getter.
                func attribute(_ key: String) -> Any? {
                    node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
                }
                if let frame = attribute("accessibilityFrame") as? NSValue {
                    result.append(Element(identifier: text(attribute("accessibilityIdentifier")) ?? "",
                        label: text(attribute("accessibilityLabel")) ?? text(attribute("accessibilityTitle")) ?? text(attribute("accessibilityValue")) ?? "",
                        role: text(attribute("accessibilityRole")) ?? "", frame: frame.rectValue, enabled: enabled(node)))
                }
                // Some SwiftUI container nodes expose children without their own frame.
                // They are transparent to navigation, not the end of the accessibility tree.
                children = attribute("accessibilityChildren") as? [Any] ?? []
            }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return result
    }
    private static func openMenu(window: NSWindow, screenPoint: CGPoint) async throws -> Bool {
        let observation = MenuObservation()
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let menu = note.object as? NSMenu else { return }
                observation.opened += 1
                observation.names = menu.items.map(\.title)
                // Let AppKit enter tracking before closing it. Synchronous cancellation
                // during didBeginTracking leaves the next click dismissing the old menu.
                DispatchQueue.main.async { menu.cancelTracking() }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw Failure.accessibility }
            NSApp.postEvent(event, atStart: false)
        }
        try await settle(300)
        return observation.opened > 0
    }
    static func capture(_ view: NSView, name: String, directory: URL, includingChild: NSWindow? = nil) async throws -> [String: Any] {
        guard let window = view.window, window.isVisible else { throw Failure.capture }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw Failure.capture }
        if let child = includingChild {
            guard child.isVisible, child.parent === window,
                  content.windows.contains(where: { $0.windowID == CGWindowID(child.windowNumber) && $0.owningApplication?.processID == getpid() })
            else { throw Failure.capture }
        }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(own.frame.width * CGFloat(filter.pointPixelScale)))
        configuration.height = Int(ceil(own.frame.height * CGFloat(filter.pointPixelScale)))
        configuration.showsCursor = false; configuration.capturesAudio = false; configuration.captureMicrophone = false
        configuration.includeChildWindows = includingChild != nil
        configuration.ignoreShadowsSingleWindow = true; configuration.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.capture }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        return ["name": name, "file": "polish-snapshots/" + name + ".png", "bytes": png.count,
            "width": image.width, "height": image.height, "owning_process_id": getpid(), "window_id": own.windowID,
            "includes_owned_child": includingChild != nil]
    }
}
#endif
