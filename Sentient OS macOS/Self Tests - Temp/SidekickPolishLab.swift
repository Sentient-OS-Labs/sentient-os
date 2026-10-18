#if DEBUG
// Targeted native UI checks after SidekickAppLab isolates defaults and support files.
// Five captures of this process's windows only. No provider, computer-use helper or other app.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI

@MainActor enum SidekickPolishLab {
    enum Failure: String, Error { case isolation, screenLocked, unavailable, capture, accessibility }
    private struct Element {
        let identifier: String
        let label: String
        let role: String
        let frame: CGRect
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
    private static func settle(_ milliseconds: Int) async throws {
        await Task.yield(); try await Task.sleep(for: .milliseconds(milliseconds))
    }
    private static func elements(_ view: NSView) -> [Element] {
        var result: [Element] = []
        var visited = Set<ObjectIdentifier>()
        func text(_ value: Any?) -> String? {
            let value = (value as? NSAttributedString)?.string ?? (value as? String)
            return value?.isEmpty == false ? value : nil
        }
        @MainActor func walk(_ value: Any, depth: Int) {
            guard depth < 35, result.count < 3000 else { return }
            let identity = ObjectIdentifier(value as AnyObject)
            guard visited.insert(identity).inserted else { return }
            var children: [Any] = []
            if let node = value as? NSView {
                result.append(Element(identifier: node.accessibilityIdentifier(),
                    label: text(node.accessibilityLabel()) ?? text(node.accessibilityTitle()) ?? text(node.accessibilityValue()) ?? "",
                    role: node.accessibilityRole()?.rawValue ?? "", frame: node.accessibilityFrame()))
                children = (node.accessibilityChildren() ?? []) + node.subviews
            } else if let node = value as? NSAccessibilityElement {
                result.append(Element(identifier: node.accessibilityIdentifier() ?? "",
                    label: text(node.accessibilityLabel()) ?? text(node.accessibilityTitle()) ?? text(node.accessibilityValue()) ?? "",
                    role: node.accessibilityRole()?.rawValue ?? "", frame: node.accessibilityFrame()))
                children = node.accessibilityChildren() ?? []
            } else if let node = value as? any NSAccessibilityProtocol {
                result.append(Element(identifier: node.accessibilityIdentifier() ?? "",
                    label: text(node.accessibilityLabel()) ?? text(node.accessibilityTitle()) ?? text(node.accessibilityValue()) ?? "",
                    role: node.accessibilityRole()?.rawValue ?? "", frame: node.accessibilityFrame()))
                children = node.accessibilityChildren() ?? []
            } else if let node = value as? NSObject {
                // SwiftUI AccessibilityNode implements AppKit's informal getters without
                // declaring NSAccessibilityProtocol. KVC boxes its public NSRect getter.
                func attribute(_ key: String) -> Any? {
                    node.responds(to: NSSelectorFromString(key)) ? node.value(forKey: key) : nil
                }
                guard let frame = attribute("accessibilityFrame") as? NSValue else { return }
                result.append(Element(identifier: text(attribute("accessibilityIdentifier")) ?? "",
                    label: text(attribute("accessibilityLabel")) ?? text(attribute("accessibilityTitle")) ?? text(attribute("accessibilityValue")) ?? "",
                    role: text(attribute("accessibilityRole")) ?? "", frame: frame.rectValue))
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
    private static func capture(_ view: NSView, name: String, directory: URL) async throws -> [String: Any] {
        guard let window = view.window, window.isVisible else { throw Failure.capture }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw Failure.capture }
        let filter = SCContentFilter(desktopIndependentWindow: own)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(own.frame.width * CGFloat(filter.pointPixelScale)))
        configuration.height = Int(ceil(own.frame.height * CGFloat(filter.pointPixelScale)))
        configuration.showsCursor = false; configuration.capturesAudio = false; configuration.captureMicrophone = false
        configuration.ignoreShadowsSingleWindow = true; configuration.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.capture }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        return ["name": name, "file": "polish-snapshots/" + name + ".png", "bytes": png.count,
            "width": image.width, "height": image.height, "owning_process_id": getpid(), "window_id": own.windowID]
    }
}
#endif
