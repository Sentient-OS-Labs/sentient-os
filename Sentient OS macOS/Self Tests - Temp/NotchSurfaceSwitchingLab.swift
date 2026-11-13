#if DEBUG
// Real Home + production notch controller, isolated defaults/data, no provider or microphone.
import AppKit
import SwiftUI

@MainActor enum NotchSurfaceSwitchingLab {
    static func run(app: AppState, root: URL) async throws -> [String: Bool] {
        let coordinator = app.commandCoordinator
        coordinator.run.preventsTaskExecutionForUIFixture = true
        UserDefaults.standard.set(true, forKey: AppState.onboardingKey)
        UserDefaults.standard.set(true, forKey: NotchPreferences.clickEnabledKey)
        let host = NSHostingView(rootView: HomeView(deck: .jesai).environment(app).preferredColorScheme(.dark))
        host.sizingOptions = []
        let home = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 1000, height: 760),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        home.identifier = NSUserInterfaceItemIdentifier("home")
        home.title = "Surface switching · isolated fixture"
        home.isReleasedWhenClosed = false
        home.contentView = host
        home.collectionBehavior = [.canJoinAllApplications, .stationary]
        home.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let controller = NotchWindowController(coordinator: coordinator)
        controller.start()
        defer { coordinator.dismissTyping(); controller.shutdownForTesting(); home.close() }
        try await Task.sleep(for: .milliseconds(500))
        guard let panel = controller.panelForTesting, let notchHost = panel.contentView as? NotchHostingView else {
            return ["production_panel_created": false]
        }
        _ = try await SidekickPolishLab.capture(host, name: "home-composer", directory: root)
        let initialHost = ObjectIdentifier(notchHost)
        var checks = ["notch_disables_automatic_window_sizing": notchHost.sizingOptions.isEmpty,
                      "notch_owns_safe_area_geometry": notchHost.safeAreaRegions.isEmpty,
                      "one_entry_per_display": controller.entryPanelsForTesting.count == NSScreen.screens.count]
        let displays = NSScreen.screens
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("island-only").path) {
            guard let screen = displays.first(where: { $0.notchSize == nil }),
                  let entry = controller.entryPanelsForTesting[screen.displayID] else { return ["external_display_available": false] }
            NSApp.activate(ignoringOtherApps: true)
            home.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            coordinator.notchClicked(anchor: .display(screen.displayID))
            try await Task.sleep(for: .milliseconds(800))
            let identity = ObjectIdentifier(notchHost)
            checks["prompt_was_expanded"] = coordinator.phase == .typing
            _ = try await SidekickPolishLab.capture(notchHost, name: "island-expanded", directory: root)
            checks["expanded_launcher_hidden"] = !entry.isVisible
            controller.mouseDownForTesting(at: NSPoint(x: screen.frame.midX, y: screen.frame.minY + 80))
            for frame in 0..<8 {
                try await Task.sleep(for: .milliseconds(80))
                checks["single_surface_during_close_\(frame)"] = !entry.isVisible && panel.isVisible
                _ = try await SidekickPolishLab.capture(notchHost, name: "island-close-\(frame)", directory: root)
            }
            checks["same_host_after_close"] = panel.contentView.map(ObjectIdentifier.init) == identity
            coordinator.notchClicked(anchor: .display(screen.displayID))
            try await Task.sleep(for: .milliseconds(650))
            checks["same_host_on_reopen"] = panel.contentView.map(ObjectIdentifier.init) == identity && !entry.isVisible
            try Data("1\n".utf8).write(to: root.appendingPathComponent("surface-switch-progress.txt"))
            return checks
        }
        let draft = "Keep this unsent draft while switching displays."
        coordinator.notchDraft = draft
        for index in 0..<60 {
            let screen = displays[index % displays.count]
            let id = screen.displayID
            let entry = controller.entryPanelsForTesting[id]!
            if coordinator.phase == .hidden { controller.hoverEntryForTesting(displayID: id) }
            let activated: Bool
            if index.isMultiple(of: 2), let view = entry.contentView,
               let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: entry.windowNumber,
                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                view.mouseDown(with: down)
                coordinator.notchPress.releaseForTesting()
                activated = true
            } else {
                activated = entry.contentView?.accessibilityPerformPress() == true
            }
            try await Task.sleep(for: .milliseconds(index < 6 ? 450 : index % 3 == 0 ? 120 : 60))
            checks["entry_activation_\(index)"] = activated && coordinator.phase == .typing
                && coordinator.notchAnchor == .display(id) && panel.screen?.displayID == id
            checks["typing_focus_owned_\(index)"] = panel.isKeyWindow
            if coordinator.phase != .typing || !panel.isKeyWindow {
                Log("surface fixture step \(index): phase=\(coordinator.phase), panelKey=\(panel.isKeyWindow), homeKey=\(home.isKeyWindow), frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), fixturePID=\(getpid())")
            }
            checks["draft_preserved_\(index)"] = coordinator.notchDraft == draft
            checks["host_reused_\(index)"] = panel.contentView.map(ObjectIdentifier.init) == initialHost
            checks["other_display_entries_visible_\(index)"] = controller.entryPanelsForTesting
                .filter { $0.key != id }.values.allSatisfy(\.isVisible)
            if index % 3 == 0 {
                // Actual outside-click routing, followed by Home becoming key, then a
                // new entry press before the old retract's order-out deadline.
                let outside = NSPoint(x: screen.frame.midX, y: screen.frame.minY + 80)
                controller.mouseDownForTesting(at: outside)
                home.makeKeyAndOrderFront(nil)
                checks["home_handoff_\(index)"] = coordinator.phase == .hidden
                try await Task.sleep(for: .milliseconds(40))
            }
            if index % 10 == 9, index % 3 != 0 {
                try await Task.sleep(for: .milliseconds(450))
                checks["no_stale_dismissal_\(index)"] = coordinator.phase == .typing && panel.isVisible
            }
            try Data("\(index + 1)\n".utf8).write(to: root.appendingPathComponent("surface-switch-progress.txt"), options: .atomic)
        }
        // Match the reported click/defocus → hover on the other display sequence.
        let captures = root.appendingPathComponent("hover-handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        for index in 0..<displays.count * 2 {
            let source = displays[index % displays.count]
            let destination = displays[(index + 1) % displays.count]
            coordinator.notchClicked(anchor: .display(source.displayID))
            try await Task.sleep(for: .milliseconds(100))
            controller.mouseDownForTesting(at: NSPoint(x: source.frame.midX, y: source.frame.minY + 80))
            controller.hoverEntryForTesting(displayID: destination.displayID)
            let firstFrame = panel.frame
            checks["hover_destination_initialized_\(index)"] = notchHost.rootView.displayID == destination.displayID
                && abs(firstFrame.midX - destination.frame.midX) < 1
                && abs(firstFrame.maxY - destination.frame.maxY) < 1
            try await Task.sleep(for: .milliseconds(30))
            _ = try await SidekickPolishLab.capture(notchHost, name: "\(index)-arrival", directory: captures)
            try await Task.sleep(for: .milliseconds(250))
            checks["hover_does_not_reposition_later_\(index)"] = panel.frame == firstFrame
            _ = try await SidekickPolishLab.capture(notchHost, name: "\(index)-settled", directory: captures)
        }
        // Let the delayed hardware glass settle once, then move the live composer again.
        coordinator.notchClicked(anchor: .display(displays[0].displayID))
        try await Task.sleep(for: .milliseconds(2800))
        for screen in displays.reversed() {
            coordinator.notchClicked(anchor: .display(screen.displayID))
            try await Task.sleep(for: .milliseconds(150))
            checks["settled_glass_handoff_\(screen.displayID)"] = panel.screen?.displayID == screen.displayID
                && coordinator.phase == .typing && coordinator.notchDraft == draft
        }
        checks["no_agent_execution"] = !coordinator.run.isRunning && coordinator.run.interaction == nil
        return checks
    }
}
#endif
