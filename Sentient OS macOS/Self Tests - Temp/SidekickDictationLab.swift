#if DEBUG
// Render actual dictation/Sidekick views with synthetic text and volume. Only owned windows
// are captured; no microphone, provider, or task is started.
// Doc: ../Documentation - General - Self-Testing (Eval Harness).md
import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor enum SidekickDictationLab {
    static func run(root: URL) async throws -> [String: Bool] {
        let directory = root.appendingPathComponent("dictation-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var captures: [[String: Any]] = []
        var checks: [String: Bool] = [:]
        let presentation = DictationPresentation()
        presentation.capturing = true; presentation.connected = true
        presentation.text = "Send the updated proposal and ask whether Friday afternoon works."
        for i in 0..<24 { presentation.push(Float(i % 7) / 7) }
        let variants: [(String, NotchMetrics, NotchPhase)] = [
            ("01-recording-notched", NotchMetrics(availableSize: CGSize(width: 1440, height: 900),
                hardwareNotch: CGSize(width: 200, height: 37)), .listening),
            ("02-recording-external", NotchMetrics(availableSize: CGSize(width: 1440, height: 900),
                hardwareNotch: nil), .listening),
            ("03-finalizing", NotchMetrics.preview, .transcribing),
            ("04-running", NotchMetrics.preview, .running),
            ("05-running-compact", NotchMetrics(hardwareNotch: CGSize(width: 200, height: 37), compactMode: true), .running),
        ]
        let island = NotchMetrics(hardwareNotch: nil)
        let islandVariants: [(String, NotchMetrics, NotchPhase)] = [
            ("09-island-resting", island, .hidden),
            ("10-island-hover", island, .hidden),
            ("11-island-typing", island, .typing),
            ("12-island-compact", NotchMetrics(hardwareNotch: nil, compactMode: true), .running),
            ("17-notched-typing", .preview, .typing),
            ("18-notched-compact", NotchMetrics(hardwareNotch: CGSize(width: 200, height: 37), compactMode: true), .running),
        ]
        for (name, metrics, phase) in variants + islandVariants {
            let view = NotchContent(phase: phase, readBack: phase == .running ? presentation.text : nil,
                statusLine: "Preparing your request", dictation: presentation, hovering: name == "10-island-hover", metrics: metrics)
                .frame(width: 1440, height: 180)
                .background(Color(red: 0.12, green: 0.13, blue: 0.15))
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 100, width: 1440, height: 180),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host; window.orderFrontRegardless()
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(metrics.hasPhysicalNotch && metrics.usesGlassSurface(for: phase) ? 2800 : 400))
            captures.append(try await capture(host, name: name, directory: directory))
            if phase == .listening {
                let size = metrics.size(for: phase)
                checks[name + "-sidekick-width"] = size.width == metrics.size(for: .running).width
                checks[name + "-bottom-transcript"] = size.height == metrics.topRowHeight + metrics.captionHeight + metrics.bottomPad
                checks[name + "-camera-clearance"] = metrics.dictationLeftWidth * 2
                    + (metrics.hardwareNotch?.width ?? 0) == size.width
                checks[name + "-matches-status-height"] = size.height == metrics.runningHeight(caption: metrics.captionHeight)
                checks[name + "-waveform-clears-camera"] = size.width - 2 * metrics.hPad > 48
            }
        }
        let response = SidekickConversationStore.Record(sequence: 1, event: .init(taskID: UUID(),
            kind: .assistantMessage, text: "I can work on your Mac for you, using apps and the web.\n\n- **Apps and files:** open and operate your apps.\n- **Research:** find sources and summarize what matters.\n- **Your knowledge:** use your notes and context."))
        let responseHost = NSHostingView(rootView: NotchContent(phase: .message, readBack: nil, statusLine: "",
            metrics: .preview, message: response).frame(width: 800, height: 340)
            .background(Color(white: 0.13)).preferredColorScheme(.dark))
        responseHost.sizingOptions = []
        let responseWindow = NotchPanel(contentRect: NSRect(x: 100, y: 150, width: 800, height: 340),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        responseWindow.isReleasedWhenClosed = false
        responseWindow.collectionBehavior = [.canJoinAllApplications, .stationary]
        responseWindow.contentView = responseHost; responseWindow.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(2800))
        captures.append(try await capture(responseHost, name: "19-response-header", directory: directory))
        let spokenReply = DictationPresentation()
        spokenReply.reset(context: .reply(response)); spokenReply.capturing = true; spokenReply.connected = true
        spokenReply.text = ""
        for i in 0..<24 { spokenReply.push(Float(i % 6) / 6) }
        let replyMetrics = NotchMetrics.preview
        responseHost.rootView = NotchContent(phase: .listening, readBack: nil, statusLine: "", dictation: spokenReply,
            metrics: replyMetrics, message: response).frame(width: 800, height: 340)
            .background(Color(white: 0.13)).preferredColorScheme(.dark)
        try await Task.sleep(for: .milliseconds(300))
        captures.append(try await capture(responseHost, name: "20a-response-waveform", directory: directory))
        spokenReply.text = "Can you explain the research part and show me an example?"
        try await Task.sleep(for: .milliseconds(700))
        captures.append(try await capture(responseHost, name: "20-response-dictation", directory: directory))
        spokenReply.capturing = false; spokenReply.finalizing = true
        responseHost.rootView = NotchContent(phase: .transcribing, readBack: nil, statusLine: "", dictation: spokenReply,
            metrics: replyMetrics, message: response).frame(width: 800, height: 340)
            .background(Color(white: 0.13)).preferredColorScheme(.dark)
        try await Task.sleep(for: .milliseconds(300))
        captures.append(try await capture(responseHost, name: "21-response-release", directory: directory))
        checks["response-dictation-preserves-size-through-release"] = replyMetrics.size(for: spokenReply.layoutPhase(for: .listening), messageContent: response)
            == replyMetrics.size(for: spokenReply.layoutPhase(for: .transcribing), messageContent: response)
        responseWindow.close()
        let comparison = NSHostingView(rootView: IslandGlassComparison(dictation: presentation))
        let comparisonWindow = NSWindow(contentRect: CGRect(x: 100, y: 120, width: 1280, height: 812),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
        comparisonWindow.isReleasedWhenClosed = false
        comparisonWindow.contentView = comparison
        comparisonWindow.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(700))
        captures.append(try await capture(comparison, name: "14-black-vs-liquid-glass", directory: directory))
        comparisonWindow.close()
        // Behind-window material validation requires the window server capture path.
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent("view-raster-capture").path) {
            let focusBlur = try await IslandFocusBlurLab.capture(directory: directory)
            checks.merge(focusBlur.checks) { _, new in new }
            captures.append(contentsOf: focusBlur.captures)
        }
        presentation.text = String(repeating: "A longer spoken request with context and details. ", count: 8)
        let overflow = NSHostingView(rootView: NotchContent(phase: .listening, readBack: nil, statusLine: "",
            dictation: presentation, metrics: .preview).frame(width: 1440, height: 180)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15)).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 100, width: 1440, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = overflow; window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        presentation.text += "Keep this final sentence visible."
        try await Task.sleep(for: .milliseconds(200))
        captures.append(try await capture(overflow, name: "06-overflow", directory: directory))
        window.close()
        let morph = MorphState()
        let morphHost = NSHostingView(rootView: MorphView(state: morph, presentation: presentation))
        let morphWindow = NSWindow(contentRect: CGRect(x: 0, y: 100, width: 1440, height: 180),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        morphWindow.isReleasedWhenClosed = false; morphWindow.contentView = morphHost; morphWindow.orderFrontRegardless()
        defer { morphWindow.close() }
        try await Task.sleep(for: .milliseconds(300))
        morph.phase = .listening
        for (index, delay) in [10, 40, 80, 160].enumerated() {
            try await Task.sleep(for: .milliseconds(delay))
            let name = "07-entry-\(index)"
            captures.append(try await capture(morphHost, name: name, directory: directory))
            checks[name + "-has-transcript-row"] = NotchMetrics.preview.dictationHeight > NotchMetrics.preview.topRowHeight
        }
        morph.phase = .transcribing
        try await Task.sleep(for: .milliseconds(350))
        captures.append(try await capture(morphHost, name: "08-release", directory: directory))
        // Real external-display panel lifecycle, with execution and selection capture disabled.
        let app = AppState()
        let coordinator = app.commandCoordinator
        coordinator.run.preventsTaskExecutionForUIFixture = true
        UserDefaults.standard.set(true, forKey: AppState.onboardingKey)
        UserDefaults.standard.set(true, forKey: NotchPreferences.clickEnabledKey)
        let controller = NotchWindowController(coordinator: coordinator)
        controller.start()
        defer { coordinator.dismissTyping(); controller.shutdownForTesting() }
        try await Task.sleep(for: .milliseconds(300))
        let launchers = controller.islandPanelsForTesting
        checks["island-one-launcher-per-notchless-display"] = launchers.count == NSScreen.screens.filter { $0.notchSize == nil }.count
        for (id, launcher) in launchers {
            checks["island-idle-visible-\(id)"] = launcher.isVisible && !launcher.isKeyWindow
            if let screen = NSScreen.screens.first(where: { $0.displayID == id }) {
                checks["island-handle-inside-menu-bar-\(id)"] = launcher.frame.maxY <= screen.frame.maxY
                    && launcher.frame.minY >= screen.frame.maxY - 24
                    && abs(launcher.frame.midX - screen.frame.midX) < 1
            }
            let activated = launcher.contentView?.accessibilityPerformPress() == true
            try await Task.sleep(for: .milliseconds(700))
            checks["island-click-opens-on-own-display-\(id)"] = activated && coordinator.phase == .typing
                && coordinator.notchAnchor == .display(id) && controller.panelForTesting?.screen?.displayID == id
            checks["island-hides-idle-handle-while-open-\(id)"] = !launcher.isVisible
            let canvas = controller.panelForTesting?.frame
            if let host = controller.panelForTesting?.contentView {
                captures.append(try await capture(host, name: "13-native-island-\(id)", directory: directory))
            }
            coordinator.dismissTyping()
            try await Task.sleep(for: .milliseconds(800))
            checks["island-retract-restores-handle-\(id)"] = launcher.isVisible && controller.panelForTesting?.isVisible == false
                && controller.panelForTesting?.frame == canvas
            coordinator.notchClicked(anchor: .display(id))
            try await Task.sleep(for: .milliseconds(100))
            coordinator.dismissTyping()
            try await Task.sleep(for: .milliseconds(100))
            coordinator.notchClicked(anchor: .display(id))
            try await Task.sleep(for: .milliseconds(700))
            checks["island-reopen-survives-old-retract-\(id)"] = coordinator.phase == .typing
                && controller.panelForTesting?.isVisible == true && controller.panelForTesting?.frame == canvas
            coordinator.dismissTyping()
            try await Task.sleep(for: .milliseconds(700))
        }
        UserDefaults.standard.set(false, forKey: NotchPreferences.clickEnabledKey)
        NotificationCenter.default.post(name: .notchInteractionChanged, object: nil)
        checks["island-respects-disabled-click-preference"] = controller.islandPanelsForTesting.values.allSatisfy { !$0.isVisible }
        controller.shutdownForTesting()
        checks["island-releases-native-resources"] = controller.resourcesReleasedForTesting
        for index in captures.indices { captures[index]["file"] = "dictation-snapshots/" + (captures[index]["name"] as! String) + ".png" }
        let manifest: [String: Any] = ["checks": checks, "captures": captures, "microphone_used": false, "provider_calls": 0]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("dictation-manifest.json"), options: .atomic)
        return checks
    }

    private static func capture(_ view: NSView, name: String, directory: URL) async throws -> [String: Any] {
        let marker = directory.deletingLastPathComponent().appendingPathComponent("view-raster-capture")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            return try await SidekickPolishLab.capture(view, name: name, directory: directory)
        }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "ViewSnapshot", code: 1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ViewSnapshot", code: 2)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        return ["name": name, "capture_method": "owned_view_raster", "bytes": png.count]
    }

    @Observable final class MorphState { var phase = NotchPhase.typing }
    private struct MorphView: View {
        let state: MorphState
        let presentation: DictationPresentation
        var body: some View {
            NotchContent(phase: state.phase, readBack: nil, statusLine: "", dictation: presentation, metrics: .preview)
                .frame(width: 1440, height: 180)
                .background(Color(red: 0.12, green: 0.13, blue: 0.15)).preferredColorScheme(.dark)
        }
    }
}

/// Exercise actual hidden → typing → hidden transitions, rather than static phase renders.
@MainActor enum NotchOpeningLab {
    @available(macOS 15.0, *)
    private final class Recorder: NSObject, SCRecordingOutputDelegate {
        var finished = false
        var failed = false
        nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            Task { @MainActor in self.finished = true }
        }
        nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
            Task { @MainActor in self.failed = true }
        }
    }
    @Observable final class State {
        var phase = NotchPhase.hidden
        let speech = DictationPresentation()
        let message = SidekickConversationStore.Record(sequence: 1,
            event: .init(taskID: UUID(), kind: .assistantMessage,
                text: "Here's a small surprise: **octopuses can taste with their arms.**\n\nTheir suckers sense chemicals as they explore, helping them identify food without bringing it to their mouths."))
    }
    private struct Surface: View {
        let state: State
        var island = false
        var responseMotion = false
        var completionMotion = false
        var body: some View {
            NotchContent(phase: state.phase, readBack: nil, statusLine: "Thinking it through…", dictation: state.speech, workAppIdentifier: completionMotion ? "com.apple.Notes" : nil,
                         metrics: island ? NotchMetrics(hardwareNotch: nil) : .preview, message: state.message)
                .frame(width: 800, height: responseMotion ? 440 : 220)
                .background(Color(white: 0.12)).preferredColorScheme(.dark)
        }
    }
    private static func recordResponseMotion(state: State, window: NSWindow, directory: URL, completion: Bool = false) async throws -> [String: Bool] {
        state.phase = .running
        try await Task.sleep(for: .milliseconds(800))
        let content = try await SCShareableContent.currentProcess
        guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return ["response_capture_window": false] }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let config = SCStreamConfiguration()
        config.width = 1600; config.height = 880
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
        config.ignoreShadowsSingleWindow = true
        let output = SCRecordingOutputConfiguration()
        output.outputURL = directory.appendingPathComponent("response-motion.mp4")
        let delegate = Recorder()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: delegate))
        try await stream.startCapture()
        let originalFrame = window.frame
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(400))
            if completion {
                state.phase = .finishing(.success)
                try await Task.sleep(for: .milliseconds(1150))
                state.phase = .hidden
                try await Task.sleep(for: .milliseconds(700))
                state.phase = .running
                continue
            }
            state.phase = .message
            try await Task.sleep(for: .milliseconds(1200))
            state.speech.reset(context: .reply(state.message))
            state.phase = .listening
            state.speech.text = "Tell me something else."
            try await Task.sleep(for: .milliseconds(400))
            state.phase = .transcribing
            try await Task.sleep(for: .milliseconds(200))
            state.phase = .running
            state.speech.endContext()
            try await Task.sleep(for: .milliseconds(1000))
        }
        if !completion {
            state.phase = .message
            try await Task.sleep(for: .milliseconds(90))
        }
        state.phase = .hidden
        try await Task.sleep(for: .milliseconds(700))
        try await stream.stopCapture()
        for _ in 0..<100 {
            if delegate.finished || delegate.failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return ["response_motion_recorded": delegate.finished && !delegate.failed,
                "response_window_frame_stable": window.frame == originalFrame,
                "response_interrupted_close": state.phase == .hidden]
    }

    static func run(root: URL) async throws -> [String: Bool] {
        let directory = root.appendingPathComponent("motion-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = State()
        let island = FileManager.default.fileExists(atPath: root.appendingPathComponent("island-motion").path)
        let completionMotion = FileManager.default.fileExists(atPath: root.appendingPathComponent("completion-motion").path)
        let responseMotion = completionMotion || FileManager.default.fileExists(atPath: root.appendingPathComponent("response-motion").path)
        let host = NSHostingView(rootView: Surface(state: state, island: island, responseMotion: responseMotion, completionMotion: completionMotion))
        host.sizingOptions = []
        host.safeAreaRegions = []
        let window = NotchPanel(contentRect: NSRect(x: 200, y: 200, width: 800, height: responseMotion ? 440 : 220),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllApplications, .stationary]
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        if responseMotion {
            return try await recordResponseMotion(state: state, window: window, directory: directory, completion: completionMotion)
        }
        func liveBackdrops(_ view: NSView) -> Int {
            (view.identifier?.rawValue == "sentient.island.backdrop" ? 1 : 0)
                + view.subviews.reduce(0) { $0 + liveBackdrops($1) }
        }
        try await Task.sleep(for: .milliseconds(200))
        let frame = window.frame
        var checks = ["hidden_has_no_live_material": liveBackdrops(host) == 0]
        _ = try await SidekickPolishLab.capture(host, name: "00-hidden", directory: directory)
        state.phase = .typing
        try await Task.sleep(for: .milliseconds(100))
        checks["opening_does_not_create_live_blur"] = liveBackdrops(host) == 0
        _ = try await SidekickPolishLab.capture(host, name: "01-opening", directory: directory)
        try await Task.sleep(for: .milliseconds(island ? 150 : 400))
        checks["opening_has_a_black_pause_before_color"] = liveBackdrops(host) == 0
        try await Task.sleep(for: .milliseconds(2200))
        checks["settled_opening_has_glass"] = liveBackdrops(host) == 1
        _ = try await SidekickPolishLab.capture(host, name: "02-open", directory: directory)
        state.phase = .hidden
        try await Task.sleep(for: .milliseconds(100))
        checks["closing_releases_live_material"] = liveBackdrops(host) == 0
        try await Task.sleep(for: .milliseconds(600))
        _ = try await SidekickPolishLab.capture(host, name: "03-closed", directory: directory)
        state.phase = .typing
        try await Task.sleep(for: .milliseconds(100))
        checks["reopening_does_not_reuse_stale_settle"] = liveBackdrops(host) == 0
        state.phase = .hidden
        try await Task.sleep(for: .milliseconds(1100))
        checks["interrupted_opening_cannot_show_late_material"] = liveBackdrops(host) == 0
        state.phase = .typing
        try await Task.sleep(for: .milliseconds(1300))
        checks["fresh_open_after_interrupt_has_glass"] = liveBackdrops(host) == 1
        checks["window_canvas_remains_fixed"] = window.frame == frame
        // Exercise the real controller's outside-click path, including the old key-focus
        // grace window and a subsequent app activation. No global clicks are synthesized.
        let app = AppState()
        let coordinator = app.commandCoordinator
        coordinator.run.preventsTaskExecutionForUIFixture = true
        UserDefaults.standard.set(true, forKey: AppState.onboardingKey)
        UserDefaults.standard.set(true, forKey: NotchPreferences.clickEnabledKey)
        let controller = NotchWindowController(coordinator: coordinator)
        controller.start()
        defer { coordinator.dismissTyping(); controller.shutdownForTesting() }
        try await Task.sleep(for: .milliseconds(150))
        coordinator.openNotchFromHome()
        try await Task.sleep(for: .milliseconds(80))
        if let panel = controller.panelForTesting, let screen = panel.screen {
            let outside = NSPoint(x: screen.frame.midX, y: screen.frame.minY + 80)
            controller.mouseDownForTesting(at: NSPoint(x: screen.frame.midX, y: screen.frame.maxY - 20))
            checks["inside_click_keeps_prompt_open"] = coordinator.phase == .typing
            controller.mouseDownForTesting(at: outside)
            checks["first_outside_click_dismisses_during_opening"] = coordinator.phase == .hidden
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            try await Task.sleep(for: .milliseconds(100))
            checks["activation_and_pending_focus_cannot_reopen"] = coordinator.phase == .hidden && !panel.isKeyWindow
            try await Task.sleep(for: .milliseconds(600))
            checks["retract_keeps_external_pill_or_hides_hardware_notch"] = panel.isVisible == (screen.notchSize == nil)
            coordinator.openNotchFromHome()
            try await Task.sleep(for: .milliseconds(80))
            panel.resignKey()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            checks["activation_does_not_reclaim_key"] = !panel.isKeyWindow
            controller.mouseDownForTesting(at: outside)
            checks["one_click_dismisses_nonkey_prompt"] = coordinator.phase == .hidden
        } else { checks["controller_fixture_presented"] = false }
        controller.shutdownForTesting()
        if #available(macOS 15.0, *) {
            state.phase = .hidden
            try await Task.sleep(for: .milliseconds(750))
            let content = try await SCShareableContent.currentProcess
            if let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) {
                let filter = SCContentFilter(desktopIndependentWindow: owned)
                let configuration = SCStreamConfiguration()
                configuration.width = 1600; configuration.height = 440
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.showsCursor = false; configuration.capturesAudio = false
                configuration.captureMicrophone = false; configuration.ignoreShadowsSingleWindow = true
                let outputConfiguration = SCRecordingOutputConfiguration()
                outputConfiguration.outputURL = directory.appendingPathComponent("opening-motion.mp4")
                let delegate = Recorder()
                let recording = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addRecordingOutput(recording)
                try await stream.startCapture()
                try await Task.sleep(for: .milliseconds(200))
                for _ in 0..<2 {
                    state.phase = .typing
                    try await Task.sleep(for: .milliseconds(3400))
                    state.phase = .running
                    try await Task.sleep(for: .milliseconds(1000))
                    state.phase = .typing
                    try await Task.sleep(for: .milliseconds(1200))
                    state.phase = .hidden
                    try await Task.sleep(for: .milliseconds(850))
                }
                try await stream.stopCapture()
                for _ in 0..<100 {
                    if delegate.finished || delegate.failed { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                checks["actual_motion_recording_completed"] = delegate.finished && !delegate.failed
            }
        }
        return checks
    }
}
#endif
