#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor enum NotchVoiceContinuityLab {
    @Observable final class State {
        var phase: NotchPhase = .hidden
        var message: SidekickConversationStore.Record?
        var compact = false
        var readBack: String?
        var thinking = false
        var activeAppearance = false
        let speech = DictationPresentation()
    }
    final class GeometryLog {
        var active: String?
        var last: [String: CGSize] = [:]
        var samples: [String: [String: [CGSize]]] = [:]
        func record(_ surface: String, _ size: CGSize) {
            last[surface] = size
            if let active { samples[active, default: [:]][surface, default: []].append(size) }
        }
        func begin(_ key: String) {
            active = key
            samples[key] = last.mapValues { [$0] }
        }
        func stable(_ key: String, surface: String, size: CGSize) -> Bool {
            let frames = samples[key]?[surface] ?? []
            return !frames.isEmpty && frames.allSatisfy { abs($0.width-size.width)<0.6 && abs($0.height-size.height)<0.6 }
        }
    }
    private struct Surface: View {
        let state: State
        let log: GeometryLog
        let name: String
        let notch: CGSize?
        var hardwareIsland = false
        var body: some View {
            NotchContent(phase: state.phase, readBack: state.readBack, statusLine: "Thinking it through…",
                dictation: state.speech,
                isThinking: state.thinking,
                metrics: NotchMetrics(hardwareNotch: notch, hardwareIsland: hardwareIsland, compactMode: state.compact),
                message: state.speech.replyMessage ?? state.message,
                observeSurfaceSize: { log.record(name, $0) })
                .environment(\.appearsActive, state.activeAppearance)
                .frame(width: 600, height: 340)
                .background(Color(red: 0.10, green: 0.12, blue: 0.17))
        }
    }
    private final class Recording: NSObject, SCRecordingOutputDelegate {
        var done = false; var failed = false
        nonisolated func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) { Task { @MainActor in self.done = true } }
        nonisolated func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) { Task { @MainActor in self.failed = true } }
    }
    static func run(root: URL) async throws -> [String: Bool] {
        let state = State(), log = GeometryLog()
        let directory = root.appendingPathComponent("voice-continuity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let surface = HStack(spacing: 0) {
            Surface(state: state, log: log, name: "notch", notch: CGSize(width: 200, height: 37))
            Surface(state: state, log: log, name: "island", notch: nil)
            Surface(state: state, log: log, name: "hardware-island", notch: CGSize(width: 200, height: 44), hardwareIsland: true)
        }.preferredColorScheme(.dark)
        let host = NSHostingView(rootView: surface)
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = NotchPanel(contentRect: NSRect(x: 100, y: 150, width: 1800, height: 340),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let backdrop = NotchPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false; backdrop.level = .mainMenu + 2
        backdrop.hidesOnDeactivate = false
        backdrop.contentView = NSHostingView(rootView: LinearGradient(colors: [.blue, .orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
        backdrop.orderFrontRegardless()
        window.isFloatingPanel = true; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.hidesOnDeactivate = false; window.level = .mainMenu + 3
        window.isReleasedWhenClosed = false; window.collectionBehavior = [.canJoinAllApplications, .stationary]
        window.contentView = host; window.orderFrontRegardless()
        defer { window.close(); backdrop.close() }
        let windowFrame = window.frame
        try await Task.sleep(for: .milliseconds(200))
        let content = try await SCShareableContent.currentProcess
        guard let owned = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure.capture }
        let configuration = SCStreamConfiguration()
        configuration.width = 3600; configuration.height = 680
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false; configuration.capturesAudio = false; configuration.captureMicrophone = false
        configuration.ignoreShadowsSingleWindow = true
        let output = SCRecordingOutputConfiguration(); output.outputURL = directory.appendingPathComponent("continuous-voice.mp4")
        let delegate = Recording()
        // Use one retained delegate for finish/error delivery.
        let observedRecording = SCRecordingOutput(configuration: output, delegate: delegate)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration, delegate: nil)
        try stream.addRecordingOutput(observedRecording); try await stream.startCapture()
        var checks: [String: Bool] = [:]
        func pause(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
        func capture(_ name: String) async throws { _ = try await SidekickPolishLab.capture(host, name: name, directory: directory) }
        func verify(_ key: String, _ baseline: [String: CGSize]) {
            for (name,size) in baseline { checks[key+"_"+name] = log.stable(key, surface: name, size: size) }
            log.active = nil
        }
        // One activity surface: waveform -> transcript -> starting, without width changes.
        state.phase = .listening; state.speech.capturing = true; state.speech.connected = true
        for i in 0..<24 { state.speech.push(Float(i % 6)/6) }
        try await pause(800); log.begin("voice_to_starting"); var baseline = log.last
        try await capture("01-recording")
        state.speech.text = "Send the update to the team."
        try await pause(180); state.phase = .transcribing; state.speech.finalizing = true
        try await pause(180); try await capture("01b-transcript-before-release")
        state.readBack = state.speech.text; state.thinking = true
        state.phase = .running; state.speech.endContext()
        try await pause(80); try await capture("01c-transcript-after-release")
        try await pause(720); verify("voice_to_starting",baseline)
        try await capture("02-starting")
        state.readBack = nil
        try await pause(1400); try await capture("02b-thinking-color")
        try await pause(1800); try await capture("02c-thinking-color-moved")
        // The existing input composer stays in place when its microphone is pressed.
        state.thinking = false; state.phase = .typing; try await pause(900)
        log.begin("composer_voice"); baseline = log.last
        state.speech.reset(context: .composer); state.phase = .listening
        try await pause(40); try await capture("03-composer-listening")
        state.speech.text = "Add a short summary."; try await pause(250)
        state.phase = .transcribing; try await pause(200)
        state.phase = .typing; state.speech.endContext(); try await pause(350)
        verify("composer_voice",baseline)
        // Reproduce the original bug with unchanged display metrics and the source
        // message clearing after voice starts, as the attention observer does.
        let response = SidekickConversationStore.Record(sequence: 1, event: .init(taskID: UUID(),
            kind: .assistantMessage, text: "I can help with apps, research and your documents. What would you like to try?"))
        state.message = response; state.phase = .message; try await pause(2800)
        // Transfer key ownership through AppKit. Calling resignKey directly can
        // leave NSApplication.keyWindow pointing at a window whose flag was cleared.
        backdrop.makeKey(); state.activeAppearance = false; try await pause(300)
        try await capture("04-response"); log.begin("reply_voice"); baseline = log.last
        // A fixture launched in the background may not be eligible to take key status
        // until its app is active. Make that test precondition explicit and restore it.
        let previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                previousApp?.activate(options: [])
            }
        }
        window.makeKeyAndOrderFront(nil); state.activeAppearance = true
        try await pause(60); try await capture("04b-response-focused-early")
        try await pause(500); try await capture("04c-response-focused")
        checks["response_window_became_key"] = window.isKeyWindow
        for index in 0..<3 {
            state.speech.reset(context: .reply(response)); state.phase = .listening; state.message = nil
            try await pause(40)
            if index == 0 {
                try await capture("05-response-listening")
                try await pause(500); try await capture("05b-response-listening-settled")
            }
            state.speech.text = "Tell me more."; try await pause(220)
            state.phase = .transcribing; try await pause(180)
            state.message = response; state.phase = .message; state.speech.endContext(); try await pause(350)
        }
        verify("reply_voice",baseline)
        backdrop.makeKey(); state.activeAppearance = false; try await pause(500)
        try await capture("06-response-unfocused")
        checks["response_window_resigned_key"] = !window.isKeyWindow
        // Sample the empty lower material band, excluding text and animated icons.
        // This catches brightness/tint jumps even when geometry remains perfectly still.
        for name in ["04b-response-focused-early", "04c-response-focused", "05-response-listening",
                     "05b-response-listening-settled", "06-response-unfocused"] {
            for (surface, size) in baseline {
                let delta = try materialDifference(directory: directory, compared: name, surface: surface, size: size)
                checks["material_\(surface)_\(name)"] = delta < 1.0 / 255
            }
        }
        // Compact-mode users get the same activity footprint in voice and work.
        state.compact = true; state.message = nil; state.phase = .running; try await pause(800)
        log.begin("compact_voice"); baseline = log.last
        state.speech.reset(); state.phase = .listening; try await pause(250)
        state.phase = .running; try await pause(350); verify("compact_voice",baseline)
        // Negative control: prove the observer can detect actual geometry changes.
        log.begin("probe_control")
        state.compact = false; state.message = response; state.phase = .message
        try await pause(700)
        checks["probe_detects_real_size_changes"] = log.samples["probe_control"]?.values.allSatisfy { frames in
            guard let first = frames.first else { return false }
            return frames.contains { abs($0.width-first.width)>1 || abs($0.height-first.height)>1 }
        } == true
        log.active = nil
        checks["window_frame_unchanged"] = window.frame == windowFrame
        try await stream.stopCapture()
        for _ in 0..<100 { if delegate.done || delegate.failed { break }; try await pause(30) }
        checks["recording_completed"] = delegate.done && !delegate.failed
        let frames = log.samples.mapValues { $0.mapValues { $0.map { [Double($0.width),Double($0.height)] } } }
        try JSONSerialization.data(withJSONObject: ["checks":checks,"geometry":frames,"microphone_used":false,"provider_calls":0], options:[.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("voice-continuity.json"))
        return checks
    }
    private static func materialDifference(directory: URL, compared: String, surface: String, size: CGSize) throws -> Double {
        guard let first = try NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent("04-response.png"))),
              let second = try NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(compared + ".png")))
        else { throw Failure.capture }
        let scale = Double(first.pixelsWide) / 1800
        let center = surface == "notch" ? 300.0 : surface == "island" ? 900.0 : 1500.0
        let top = surface == "notch" ? 0.0 : surface == "island" ? 9.0
            : NotchMetrics(hardwareNotch: CGSize(width: 200, height: 44), hardwareIsland: true).topInset
        var total = 0.0, count = 0.0
        for column in 0..<20 {
            for row in 3...7 {
                let x = Int((center - size.width * 0.3 + size.width * 0.6 * Double(column) / 19) * scale)
                let y = Int((top + size.height - Double(row)) * scale)
                guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw Failure.capture }
                total += abs(a.redComponent-b.redComponent) + abs(a.greenComponent-b.greenComponent) + abs(a.blueComponent-b.blueComponent)
                count += 3
            }
        }
        return total / count
    }
    enum Failure: Error {case capture}
}
#endif
