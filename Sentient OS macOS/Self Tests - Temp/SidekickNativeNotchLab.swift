#if DEBUG
// Exercises the real production panel, without invoking Sidekick execution, hotkeys or voice.
// ScreenCaptureKit is restricted to this process and this one owned window, never a display.
import AppKit
import CryptoKit
import Foundation
import ScreenCaptureKit

@MainActor enum SidekickNativeNotchLab {
    private enum Failure: Error { case configuration, missingQuestion, permission, panel, timeout, capture }

    static func run(coordinator: CommandCoordinator, root: URL) async throws -> [String: Bool] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SENTIENT_SELFTEST"] == "sidekickapp", environment["LAB_SIDEKICK_STAGE"] == "ui",
              let configuredRoot = environment["LAB_SIDEKICK_ROOT"], root.isFileURL,
              root.standardizedFileURL == URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL,
              root.standardizedFileURL == root.resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix("sentient-sidekick-app-"),
              try String(contentsOf: root.appendingPathComponent(".sidekick-app-fixture"), encoding: .utf8) == "1\n",
              !coordinator.run.isRunning, coordinator.run.interaction == nil else { throw Failure.configuration }
        let recovery = coordinator.run.recovery
        guard let question = recovery.content?.question else { throw Failure.missingQuestion }
        let conversation = coordinator.run.conversation
        guard let store = conversation.store else { throw Failure.configuration }
        let initialSequence = try store.latestSequence
        let originalVisible = conversation.isVisible
        let originalDraft = recovery.draft
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let originalKeyWindow = NSApp.keyWindow?.windowNumber
        let originalActive = NSApp.isActive
        let controller = NotchWindowController(coordinator: coordinator)
        defer {
            controller.shutdownForTesting()
            conversation.isVisible = originalVisible
        }
        conversation.isVisible = false
        recovery.dismiss()
        controller.start()
        try await wait { controller.panelForTesting != nil }
        guard recovery.reopen() else { throw Failure.missingQuestion }
        try await wait { coordinator.phase == .recovery && controller.panelForTesting?.isVisible == true }
        try await settle(200)
        guard let panel = controller.panelForTesting, panel.windowNumber > 0 else { throw Failure.panel }
        let firstFrame = panel.frame
        let panelNumber = panel.windowNumber
        let display = panel.screen ?? NotchWindowController.menuBarScreen()
        guard let display else { throw Failure.panel }
        func focusUnchanged() -> Bool {
            !panel.isKeyWindow && NSApp.keyWindow?.windowNumber == originalKeyWindow
                && NSApp.isActive == originalActive
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost
        }
        var checks: [String: Bool] = [
            "native_notch_real_panel_visible": panel.isVisible && panel is NotchPanel,
            "native_notch_nonactivating_panel": panel.styleMask.contains(.nonactivatingPanel),
            "native_notch_floating_panel": panel.isFloatingPanel && panel.level == .mainMenu + 3,
            "native_notch_top_flush": abs(panel.frame.maxY - display.frame.maxY) < 0.5,
            "native_notch_centered": abs(panel.frame.midX - display.frame.midX) <= 0.5,
            "native_notch_initial_focus_preserved": focusUnchanged()
        ]

        // Reopen before the 600ms retract settles. The old delayed orderOut must not hide
        // the new presentation, and the window canvas must stay fixed throughout the morph.
        recovery.dismiss()
        try await wait { coordinator.phase == .hidden }
        try await settle(120)
        let interruptedFrame = panel.frame
        guard recovery.reopen() else { throw Failure.missingQuestion }
        try await wait { coordinator.phase == .recovery && panel.isVisible }
        try await settle(700)
        checks["native_notch_interrupted_close_stays_visible"] = panel.isVisible && coordinator.phase == .recovery
        checks["native_notch_fixed_canvas_on_interrupted_reopen"] = panel.frame == firstFrame && interruptedFrame == firstFrame
        checks["native_notch_reopen_focus_preserved"] = focusUnchanged()

        // Also exercise a completed retract and a fresh reveal of the same actual NSPanel.
        recovery.dismiss()
        try await wait { coordinator.phase == .hidden }
        try await wait { !panel.isVisible }
        let hiddenFrame = panel.frame
        checks["native_notch_hidden_question_remains_pending"] = recovery.content?.id == question.id && recovery.isPending
        guard recovery.reopen() else { throw Failure.missingQuestion }
        try await wait { coordinator.phase == .recovery && panel.isVisible }
        try await settle(600)
        checks["native_notch_fixed_canvas_after_full_reopen"] = panel.frame == firstFrame && hiddenFrame == firstFrame
        checks["native_notch_same_window_reused"] = panel.windowNumber == panelNumber
        checks["native_notch_final_focus_preserved"] = focusUnchanged()
        checks["native_notch_question_and_draft_preserved"] = recovery.content?.id == question.id && recovery.draft == originalDraft
        let finalSequence = try store.latestSequence
        checks["native_notch_no_execution_or_history_mutation"] = !coordinator.run.isRunning && coordinator.run.interaction == nil
            && finalSequence == initialSequence

        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        let available = try await SCShareableContent.currentProcess
        guard let owned = available.windows.first(where: {
            $0.windowID == CGWindowID(panelNumber) && $0.owningApplication?.processID == getpid()
        }) else { throw Failure.capture }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let scale = CGFloat(filter.pointPixelScale)
        guard scale.isFinite, scale > 0, owned.frame.width > 0, owned.frame.height > 0 else { throw Failure.capture }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(owned.frame.width * scale))
        configuration.height = Int(ceil(owned.frame.height * scale))
        configuration.showsCursor = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        // Preserve raw alpha separately; flatten the review image over the bezel's black
        // so image viewers that discard alpha cannot turn faint glow pixels into bright bands.
        let rawPNG = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        guard let composite = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.capture }
        composite.setFillColor(CGColor(gray: 0, alpha: 1))
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        composite.fill(imageRect); composite.draw(image, in: imageRect)
        guard let flattened = composite.makeImage() else { throw Failure.capture }
        let bitmap = NSBitmapImageRep(cgImage: flattened)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure.capture }
        let directory = root.appendingPathComponent("ui-snapshots", isDirectory: true)
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath() else { throw Failure.configuration }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("native-notch-question.png"), options: .atomic)
        try rawPNG?.write(to: directory.appendingPathComponent("native-notch-question-alpha.png"), options: .atomic)
        var colors = Set<Int>(), samples = 0, lit = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 100)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 160)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = max(0, min(1, color.redComponent)), g = max(0, min(1, color.greenComponent)), b = max(0, min(1, color.blueComponent))
                samples += 1
                if max(r, g, b) > 0.04 && color.alphaComponent > 0.05 { lit += 1 }
                colors.insert((Int(r * 31) << 10) | (Int(g * 31) << 5) | Int(b * 31))
            }
        }
        let visibleFraction = Double(lit) / Double(max(1, samples))
        checks["native_notch_owned_window_capture"] = owned.windowID == CGWindowID(panelNumber) && owned.owningApplication?.processID == getpid()
        checks["native_notch_snapshot_has_visible_content"] = png.count > 2000 && colors.count > 8 && visibleFraction > 0.002
        controller.shutdownForTesting()
        checks["native_notch_owned_resources_released"] = controller.resourcesReleasedForTesting && !panel.isVisible
        checks["native_notch_cleanup_keeps_question_pending"] = recovery.content?.id == question.id && recovery.isPending
        let metadata: [String: Any] = [
            "schema": 1, "file": "ui-snapshots/native-notch-question.png", "review_background": "black", "capture_method": "desktop_independent_own_window",
            "window_id": panelNumber, "owning_process_id": getpid(), "included_child_windows": false,
            "captures_audio": false, "captures_microphone": false, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
            "pixel_scale": scale, "panel_frame": frame(firstFrame), "screen_frame": frame(display.frame),
            "interrupted_frame": frame(interruptedFrame), "hidden_frame": frame(hiddenFrame),
            "display_id": display.displayID, "hardware_cutout_present": display.notchSize != nil,
            "bytes": png.count, "sampled_colors": colors.count, "visible_content_fraction": visibleFraction,
            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(), "checks": checks
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("native-notch-question.json"), options: .atomic)
        return checks
    }

    private static func frame(_ value: NSRect) -> [Double] {
        [Double(value.origin.x), Double(value.origin.y), Double(value.width), Double(value.height)]
    }
    private static func settle(_ milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timeout }
            try await settle(20)
        }
    }
}
#endif
