#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor enum PhysicalTapLab {
    static func run(root: URL) async throws -> [String: Bool] {
        // The caller has already replaced standard defaults and support paths with a fixture.
        guard ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "sidekickapp",
              ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-physical-tap" else { throw Failure.fixture }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: AppState.onboardingKey)
        defaults.set(true, forKey: NotchPreferences.physicalTapEnabledKey)
        defaults.set(PhysicalTapAction.close.rawValue, forKey: NotchPreferences.secondPhysicalTapKey)
        var checks: [String: Bool] = ["second_tap_defaults_close": NotchPreferences.secondPhysicalTap() == .close]
        for action in PhysicalTapAction.allCases {
            defaults.set(action.rawValue, forKey: NotchPreferences.secondPhysicalTapKey)
            checks["setting_" + action.rawValue] = NotchPreferences.secondPhysicalTap() == action
        }
        defaults.set(PhysicalTapAction.close.rawValue, forKey: NotchPreferences.secondPhysicalTapKey)
        let calibration = NotchTouchCalibration.shared
        try await render(NotchTouchCalibrationView(calibration: calibration).preferredColorScheme(.dark),
                         size: NSSize(width: 560, height: 540), to: root.appendingPathComponent("touch-calibration.png"))
        try await render(NotchCalibrationIllustration().frame(width: 496, height: 152).preferredColorScheme(.dark),
                         size: NSSize(width: 496, height: 152), to: root.appendingPathComponent("notch-sensor-glow.png"))
        let settings = NotchShortcutsPane().frame(width: 700, height: 900)
            .background(Color(white: 0.045)).environment(\.colorScheme, .dark)
        try await render(settings, size: NSSize(width: 700, height: 900), to: root.appendingPathComponent("physical-tap-settings.png"))
        let notch = NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: .preview)
            .frame(width: 700, height: 180).background(Color(white: 0.08))
            .environment(\.sidekickReduceMotionOverride, true)
        try await render(notch, size: NSSize(width: 700, height: 180), to: root.appendingPathComponent("physical-tap-notch.png"))
        let locationGuide = VStack(alignment: .leading, spacing: 0) {
            Text("HOVER · SENSOR MARKER").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,30)
            NotchContent(phase:.hidden,readBack:nil,statusLine:"",hovering:true,metrics:.preview)
                .frame(width:700,height:90)
            Text("OPEN · TAP JUST ABOVE THE ARROW").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,30)
            NotchContent(phase:.typing,readBack:nil,statusLine:"",metrics:.preview,inputReady:false)
                .frame(width:700,height:180)
            HStack(spacing:60) {
                Text("DETAIL").font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                NotchTapLocationGuide(expanded:false,visible:true).frame(width:38,height:26).scaleEffect(3)
                NotchTapLocationGuide(expanded:true,visible:true).frame(width:38,height:26).scaleEffect(3)
            }.padding(.leading,30).frame(height:100)
        }.frame(width:700,height:430).background(Color(red:0.12,green:0.15,blue:0.20))
            .preferredColorScheme(.dark).environment(\.sidekickReduceMotionOverride,true)
        try await render(locationGuide,size:NSSize(width:700,height:430),to:root.appendingPathComponent("tap-location-guide.png"))
        let guidePhases: [(String, NotchPhase, Bool)] = [
            ("hidden", .hidden, false), ("opening", .opening, false),
            ("typing", .typing, true), ("message", .message, true),
            ("recovery", .recovery, true), ("listening", .listening, false),
            ("transcribing", .transcribing, false), ("running", .running, false),
            ("done", .finishing(.success), false), ("stopped", .finishing(.stopped), false),
            ("failed", .finishing(.failed), false),
            ("notice", .notice("Open a reply field and try Magic Reply again."), false)
        ]
        for (name, phase, expected) in guidePhases {
            let content = NotchContent(phase: phase, readBack: nil, statusLine: "", metrics: .preview)
            checks["tap_guide_" + name] = content.showsTapLocationGuide == expected
            var hovered = content
            hovered.hovering = true
            checks["tap_guide_hover_" + name] = hovered.showsTapLocationGuide == (expected || phase == .hidden)
            var running = hovered
            running.isTaskRunning = true
            checks["tap_guide_active_task_" + name] = !running.showsTapLocationGuide
        }
        let composerDictation = DictationPresentation()
        composerDictation.reset(context: .composer)
        for phase in [NotchPhase.listening, .transcribing] {
            let content = NotchContent(phase: phase, readBack: nil, statusLine: "",
                dictation: composerDictation, metrics: .preview)
            checks["tap_guide_composer_voice_\(phase)"] = !content.showsTapLocationGuide
        }
        let feedbackStates = VStack(spacing: 12) {
            ForEach(["listening", "done", "notice"], id: \.self) { name in
                if let (_, phase, _) = guidePhases.first(where: { $0.0 == name }) {
                    NotchContent(phase: phase, readBack: nil, statusLine: "All set", metrics: .preview)
                        .frame(width: 700, height: 120)
                }
            }
        }.background(Color(red: 0.12, green: 0.15, blue: 0.20))
            .preferredColorScheme(.dark).environment(\.sidekickReduceMotionOverride, true)
        try await render(feedbackStates, size: NSSize(width: 700, height: 384),
            to: root.appendingPathComponent("feedback-without-tap-guide.png"))
        let coordinator = CommandCoordinator()
        coordinator.run.preventsTaskExecutionForUIFixture = true
        coordinator.run.conversation.isVisible = false
        let controller = NotchWindowController(coordinator: coordinator)
        controller.start()
        defer { controller.shutdownForTesting() }
        try await Task.sleep(for: .milliseconds(100))
        coordinator.openNotchFromHome()
        try await Task.sleep(for: .milliseconds(150))
        coordinator.dismissTypingFromPointer()
        try await Task.sleep(for: .milliseconds(300))
        checks["dismiss_holds_hover_preview"] = coordinator.phase == .hidden && coordinator.notchDismissalPreview
        checks["dismiss_preview_is_visible_without_keyboard_focus"] = controller.panelForTesting?.isVisible == true && controller.panelForTesting?.isKeyWindow == false
        if let view = controller.panelForTesting?.contentView {
            _ = try await SidekickPolishLab.capture(view, name: "dismissal-hover-preview", directory: root)
        }
        try await Task.sleep(for: .milliseconds(750))
        checks["dismiss_preview_expires_after_one_second"] = !coordinator.notchDismissalPreview
        coordinator.openNotchFromHome()
        coordinator.dismissTypingFromPointer()
        try await Task.sleep(for: .milliseconds(120))
        coordinator.openNotchFromHome()
        try await Task.sleep(for: .milliseconds(1100))
        checks["reopen_cancels_old_dismissal"] = coordinator.phase == .typing && !coordinator.notchDismissalPreview && controller.panelForTesting?.isVisible == true
        coordinator.dismissTyping()
        checks["ordinary_escape_dismissal_has_no_preview"] = !coordinator.notchDismissalPreview
        let takingOver = NotchContent(phase: .running, readBack: nil, statusLine: "Taking it from here…",
            metrics: .preview, isTaskRunning: true, isTakingOver: true)
            .frame(width: 700, height: 180).background(Color(white: 0.08))
            .environment(\.sidekickReduceMotionOverride, true)
        try await render(takingOver, size: NSSize(width: 700, height: 180), to: root.appendingPathComponent("takeover-no-tap-hint.png"))
        defaults.set(false, forKey: NotchPreferences.externalBarEnabledKey)
        NotificationCenter.default.post(name: .notchInteractionChanged, object: nil)
        try await Task.sleep(for: .milliseconds(120))
        let externalIDs = Set(NSScreen.screens.filter { CGDisplayIsBuiltin($0.displayID) == 0 }.map(\.displayID))
        if !externalIDs.isEmpty {
            checks["external_resting_handles_hidden"] = controller.entryPanelsForTesting
                .filter { externalIDs.contains($0.key) }.values.allSatisfy { !$0.isVisible }
        }
        coordinator.openNotchFromHome()
        try await Task.sleep(for: .milliseconds(150))
        checks["shortcut_surface_opens_with_external_bar_off"] = coordinator.phase == .typing && controller.panelForTesting?.isVisible == true
        coordinator.dismissTyping()
        try await Task.sleep(for: .milliseconds(120))
        if externalIDs.contains(CGMainDisplayID()) {
            checks["external_surface_hides_after_shortcut_dismissal"] = controller.panelForTesting?.isVisible == false
        }
        defaults.set(true, forKey: NotchPreferences.externalBarEnabledKey)
        NotificationCenter.default.post(name: .notchInteractionChanged, object: nil)
        checks["settings_rendered"] = true
        checks["sensor_not_started_by_ui"] = !PhysicalNotchTap.shared.isEnabled
        return checks
    }
    static func probe(root: URL) async throws -> [String: Bool] {
        guard ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "live-physical-sensor" else { throw Failure.fixture }
        var statuses: [(PhysicalTapSensor.Status, UInt64)] = []
        var taps = 0
        let capture = PhysicalTapCalibrationCapture()
        let sensor = PhysicalTapSensor(onTap: { _, _ in Task { @MainActor in taps += 1 } },
            onStatus: { status, generation in Task { @MainActor in statuses.append((status, generation)) } },
            onSample: { sample in capture.append(sample) })
        sensor.configure(enabled: true, sensitivity: 1.1, generation: 1)
        let startupBlocked = !sensor.acceptsDelivery(at: PhysicalTapClock.now, generation: 1)
        try await Task.sleep(for: .seconds(4))
        let readyAllowsDelivery = sensor.acceptsDelivery(at: PhysicalTapClock.now, generation: 1)
        sensor.configure(enabled: false, sensitivity: 1.1, generation: 2)
        let disabledBlocksDelivery = !sensor.acceptsDelivery(at: PhysicalTapClock.now, generation: 1)
        sensor.drainForTermination()
        try await Task.sleep(for: .milliseconds(150))
        sensor.configure(enabled: true, sensitivity: 1.1, generation: 3)
        try await Task.sleep(for: .seconds(4))
        sensor.configure(enabled: false, sensitivity: 1.1, generation: 4)
        sensor.drainForTermination()
        try await Task.sleep(for: .milliseconds(150))
        let samples = capture.take() ?? []
        let defaults = UserDefaults.standard
        let existingCalibration = try JSONEncoder().encode(PhysicalTapCalibrationProfile(
            version: 1, date: Date(), sensitivities: ["gentle"], baselineLux: 120))
        defaults.set(existingCalibration, forKey: NotchPreferences.physicalTapCalibrationKey)
        defaults.set("gentle", forKey: NotchPreferences.physicalTapSensitivityKey)
        defaults.set(true, forKey: NotchPreferences.physicalTapEnabledKey)
        let calibration = NotchTouchCalibration.shared
        calibration.start()
        let actionsPaused = PhysicalNotchTap.shared.isCalibrating && !PhysicalNotchTap.shared.isEnabled
        let guide = NSApp.windows.first { $0.title == "Notch calibration tap guide" && $0.isVisible }
        let guideIsPassive = guide?.ignoresMouseEvents == true && guide?.canBecomeKey == false
        let builtIn = NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID) != 0 }
        let onBuiltIn = guide?.screen?.displayID == builtIn?.displayID
        let expectedX = builtIn.map { $0.cameraCenterX - ($0.notchSize?.width ?? 0) * 54 / 370 }
        let alignedWithSensor = expectedX.map { abs((guide?.frame.midX ?? 0) - $0) < 1 } ?? false
        let expectedTop = builtIn.map { $0.frame.maxY - ($0.notchSize?.height ?? 0) + 7 }
        let alignedWithNotch = expectedTop.map { abs((guide?.frame.maxY ?? 0) - $0) < 1 } ?? false
        try await Task.sleep(for: .milliseconds(200))
        let listedWindows = try await SCShareableContent.currentProcess
        let placement: [String: Any] = ["frame": guide.map { NSStringFromRect($0.frame) } ?? "missing",
            "window": guide?.windowNumber ?? -1, "builtin": builtIn?.displayID ?? 0,
            "screen": guide?.screen?.displayID ?? 0,
            "windows": listedWindows.windows.map { ["id": $0.windowID, "title": $0.title ?? "", "frame": NSStringFromRect($0.frame)] as [String: Any] }]
        try JSONSerialization.data(withJSONObject: placement, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("calibration-guide-placement.json"))
        if let view = guide?.contentView {
            _ = try await SidekickPolishLab.capture(view, name: "calibration-live-marker", directory: root)
        }
        let cueDeadline = PhysicalTapClock.now + 16
        while !calibration.isTapCue && calibration.isRunning && PhysicalTapClock.now < cueDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let showsTapCue = calibration.isTapCue
        if showsTapCue, let view = guide?.contentView {
            try await Task.sleep(for: .milliseconds(200))
            _ = try await SidekickPolishLab.capture(view, name: "calibration-live-finger", directory: root)
        }
        calibration.cancel()
        try await Task.sleep(for: .milliseconds(150))
        var checks = ["startup_delivery_blocked": startupBlocked,
            "calibration_pauses_actions": actionsPaused,
            "calibration_guide_is_passive": guideIsPassive,
            "calibration_guide_on_builtin_display": onBuiltIn,
            "calibration_guide_aligned_with_sensor": alignedWithSensor && alignedWithNotch,
            "calibration_guide_above_notch_overlay": (guide?.level.rawValue ?? 0) > NSWindow.Level.mainMenu.rawValue + 3,
            "calibration_finger_appears_at_tap_cue": showsTapCue,
            "calibration_cancel_hides_guide": guide?.isVisible == false,
            "calibration_cancel_preserves_enabled": NotchPreferences.physicalTapEnabled() && !calibration.isRunning,
            "calibration_cancel_preserves_tuning": defaults.data(forKey: NotchPreferences.physicalTapCalibrationKey) == existingCalibration
                && NotchPreferences.physicalTapThreshold() == 0.7,
            "calibration_cancel_releases_sensor": !PhysicalNotchTap.shared.isCalibrating,
            "calibration_reads_native_samples": [PhysicalTapSample.Kind.acceleration, .rotation, .light, .lid].allSatisfy { kind in samples.contains { $0.kind == kind } },
            "ready_delivery_enabled": readyAllowsDelivery,
            "disabled_delivery_blocked": disabledBlocksDelivery,
            "signed_app_lid_settling": statuses.contains { $0.0 == .settling && $0.1 == 1 },
            "signed_app_sensor_ready": statuses.contains { $0.0 == .ready && $0.1 == 1 },
            "signed_app_sensor_restart": statuses.contains { $0.0 == .ready && $0.1 == 3 },
            "signed_app_sensor_stopped": statuses.contains { $0.0 == .stopped && $0.1 == 4 },
            "signed_app_idle_no_false_taps": taps == 0]
        defaults.set(false, forKey: NotchPreferences.physicalTapEnabledKey)
        calibration.start()
        try await Task.sleep(for: .milliseconds(250))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        checks["calibration_display_change_cancels"] = !calibration.isRunning && !NotchPreferences.physicalTapEnabled()
        checks["calibration_interruption_preserves_tuning"] = defaults.data(forKey: NotchPreferences.physicalTapCalibrationKey) == existingCalibration
        try JSONSerialization.data(withJSONObject: ["checks":checks,"idle_taps":taps,
            "statuses":statuses.map { "\($0.0):\($0.1)" }], options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("physical-sensor-receipt.json"))
        return checks
    }

    @Observable final class RhythmState {
        var open = false
        var response = 0.11
    }
    private struct RhythmSurface: View {
        let state: RhythmState
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color(red: 0.18, green: 0.24, blue: 0.34)
                NotchContent(phase: state.open ? .typing : .hidden, readBack: nil, statusLine: "",
                    physicalSpringResponse: state.response,
                    metrics: NotchMetrics(hardwareNotch: CGSize(width:200,height:37)), inputReady:false)
                (state.open ? Color.green : Color.red).frame(width:16,height:200).animation(nil,value:state.open)
            }.frame(width:700,height:240).preferredColorScheme(.dark)
        }
    }
    private final class RhythmRecording: NSObject, SCRecordingOutputDelegate {
        var done=false; var failed=false
        nonisolated func recordingOutputDidFinishRecording(_ output:SCRecordingOutput) { Task { @MainActor in self.done=true } }
        nonisolated func recordingOutput(_ output:SCRecordingOutput,didFailWithError error:Error) { Task { @MainActor in self.failed=true } }
    }
    static func rhythm(root:URL) async throws -> [String:Bool] {
        guard ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-tap-rhythm" else {throw Failure.fixture}
        let state=RhythmState(),host=NSHostingView(rootView:RhythmSurface(state:state))
        host.sizingOptions=[];host.safeAreaRegions=[]
        let window=NotchPanel(contentRect:NSRect(x:150,y:200,width:700,height:240),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.backgroundColor = .black
        window.level = .mainMenu+3;window.orderFrontRegardless()
        defer{window.close()}
        try await Task.sleep(for:.milliseconds(250))
        let content=try await SCShareableContent.currentProcess
        guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.render}
        let config=SCStreamConfiguration();config.width=1400;config.height=480
        config.minimumFrameInterval=CMTime(value:1,timescale:60);config.showsCursor=false;config.capturesAudio=false
        config.ignoreShadowsSingleWindow=true
        let output=SCRecordingOutputConfiguration();output.outputURL=root.appendingPathComponent("tap-rhythm.mp4")
        let delegate=RhythmRecording()
        let recording=SCRecordingOutput(configuration:output,delegate:delegate)
        let stream=SCStream(filter:SCContentFilter(desktopIndependentWindow:owned),configuration:config,delegate:nil)
        try stream.addRecordingOutput(recording);try await stream.startCapture()
        try await Task.sleep(for:.milliseconds(300))
        for delay in [180,100] {
            state.response=delay == 180 ? 0.18:0.11
            for _ in 0..<20 {state.open.toggle();try await Task.sleep(for:.milliseconds(delay))}
            try await Task.sleep(for:.milliseconds(400))
        }
        state.open=true;try await Task.sleep(for:.milliseconds(400))
        state.open=false;try await Task.sleep(for:.milliseconds(400))
        try await stream.stopCapture()
        for _ in 0..<100 {if delegate.done || delegate.failed {break};try await Task.sleep(for:.milliseconds(20))}
        return ["rapid_morph_recorded":delegate.done && !delegate.failed,"final_target_closed":!state.open]
    }

    private static func render<V: View>(_ content: V, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .floating
        window.collectionBehavior = [.canJoinAllApplications, .stationary]
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let available = try await SCShareableContent.currentProcess
        guard let owned = available.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) else { throw Failure.render }
        let filter = SCContentFilter(desktopIndependentWindow: owned)
        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2); config.height = Int(size.height * 2)
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.render }
        try data.write(to: url)
    }
    enum Failure: Error { case fixture, render }
}
#endif
