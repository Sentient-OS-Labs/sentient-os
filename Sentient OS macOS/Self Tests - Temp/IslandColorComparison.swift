#if DEBUG
import AppKit
import SwiftUI

@MainActor enum IslandColorComparison {
    @Observable final class Frame { var time = 0.0 }

    static func capture(root: URL) async throws {
        let directory = root.appendingPathComponent("color-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = Frame()
        let selected = FileManager.default.fileExists(atPath: root.appendingPathComponent("selected-underlight").path)
        let done = FileManager.default.fileExists(atPath: root.appendingPathComponent("done-preview").path)
        let layout = FileManager.default.fileExists(atPath: root.appendingPathComponent("layout-refinement").path)
        let reference = NSImage(contentsOf: root.appendingPathComponent("website-logo.png"))
        let hybrid = FileManager.default.fileExists(atPath: root.appendingPathComponent("hardware-island").path)
        let rootView = done ? AnyView(DoneComparison()) : layout ? AnyView(LayoutRefinement(hardwareIsland: hybrid)) : reference.map { AnyView(LogoMatch(reference: $0)) }
            ?? (selected ? AnyView(SelectedUnderlight(frame: frame)) : AnyView(Comparison(frame: frame)))
        let host = NSHostingView(rootView: rootView)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 170, width: done ? 1040 : layout || selected || reference != nil ? 1280 : 1656, height: done ? 500 : layout ? 840 : 732),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Keep this owned comparison full-size even when Stage Manager is enabled.
        window.collectionBehavior = [.canJoinAllApplications, .stationary]
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(2800))
        _ = try await SidekickPolishLab.capture(host, name: "comparison", directory: directory)
        if done { return }
        if layout { try await verifyWorkingClicks(root: root); return }
        if reference != nil { return }
        // Sample one complete, deterministic 12-second color cycle. Capture real native
        // views, with all other animation paused, so the comparison isolates the material.
        for index in 0..<36 {
            frame.time = Double(index) / 3
            try await Task.sleep(for: .milliseconds(50))
            _ = try await SidekickPolishLab.capture(host, name: String(format: "frame-%03d", index), directory: directory)
        }
    }

    private struct DoneComparison: View {
        private func cell(_ title: String, notch: Bool, withApp: Bool) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.58))
                ZStack(alignment: .top) {
                    Color(red: 0.13, green: 0.16, blue: 0.21)
                    NotchContent(phase: .finishing(.success), readBack: nil, statusLine: "✓ done",
                        workAppIdentifier: withApp ? "com.apple.Notes" : nil,
                        metrics: notch ? .preview : NotchMetrics(hardwareNotch: nil))
                    if notch {
                        Color.black.frame(height: 4)
                    }
                }
                .frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text("WITH APP CONTEXT"); Spacer(); Text("WITHOUT APP CONTEXT"); Spacer() }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 28) {
                    cell("MacBook notch", notch: true, withApp: true)
                    cell("MacBook notch", notch: true, withApp: false)
                }
                HStack(spacing: 28) {
                    cell("External island", notch: false, withApp: true)
                    cell("External island", notch: false, withApp: false)
                }
            }
            .padding(30).background(Color(red: 0.025, green: 0.028, blue: 0.036))
        }
    }

    private static var notesActivity: SidekickActivityPresentation.Step {
        SidekickActivityPresentation.steps([.init(sequence: 1, event: .init(taskID: UUID(),
            kind: .activity, text: "Reading Notes", activity: .init(toolID: "notes", name: "sentient_native.get_app_state",
                arguments: "{\"app\":\"com.apple.Notes\"}", status: .started)))])[0]
    }

    private static func verifyWorkingClicks(root: URL) async throws {
        var results: [String: Bool] = [:]
        for (name, metrics) in [("island", NotchMetrics(hardwareNotch: nil)), ("notch", NotchMetrics.preview)] {
            var focused = 0, stopped = 0, opened = 0
            let host = NSHostingView(rootView: NotchContent(phase: .running, readBack: nil,
                statusLine: "→ sentient_native.get_app_state", activity: notesActivity, metrics: metrics,
                onStop: { stopped += 1 }, canShowWorkWindow: true, onShowWorkWindow: { focused += 1 },
                onOpenConversation: { opened += 1 }).frame(width: 800, height: 240))
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 240)
            let panel = NotchPanel(contentRect: NSRect(x: 150, y: 200, width: 800, height: 240),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = host
            panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(800))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            _ = try await SidekickPolishLab.capture(host, name: name + "-hit-target", directory: root)
            // The local SwiftUI AX projection can expose unnamed wrapper nodes.
            // Hit the real native view using this fixture's known layout geometry.
            let size = metrics.size(for: .running)
            let local = NSRect(x: (800 - size.width) / 2 + metrics.horizontalOffset(for: .running),
                y: 240 - metrics.topInset - size.height, width: size.width, height: size.height)
            let bodyFrame = panel.convertToScreen(local)
            let inset = metrics.hasPhysicalNotch ? metrics.hPad : (metrics.islandActivityHeight - metrics.controlSlot) / 2
            let controlY = metrics.hasPhysicalNotch ? bodyFrame.maxY - metrics.topPad - metrics.topRowHeight / 2 : bodyFrame.midY
            let stopPoint = CGPoint(x: bodyFrame.maxX - inset - metrics.controlSlot / 2, y: controlY)
            let openPoint = CGPoint(x: stopPoint.x - metrics.controlSlot - (metrics.hasPhysicalNotch ? 12 : 10), y: controlY)
            let points = [CGPoint(x: bodyFrame.midX, y: bodyFrame.midY),
                          CGPoint(x: bodyFrame.midX, y: bodyFrame.minY + 5),
                          CGPoint(x: bodyFrame.minX + 35, y: bodyFrame.midY)]
            for point in points {
                try SidekickPolishLab.postClick(window: panel, screenPoint: point)
                try await Task.sleep(for: .milliseconds(120))
            }
            results[name + "_body_padding_and_icon"] = focused == points.count && stopped == 0 && opened == 0
            try SidekickPolishLab.postClick(window: panel, screenPoint: stopPoint)
            try await Task.sleep(for: .milliseconds(120))
            results[name + "_stop_exclusive"] = stopped == 1 && focused == points.count
            try SidekickPolishLab.postClick(window: panel, screenPoint: openPoint)
            try await Task.sleep(for: .milliseconds(120))
            results[name + "_open_exclusive"] = opened == 1 && focused == points.count
            host.rootView = NotchContent(phase: .running, readBack: nil,
                statusLine: "→\u{00a0}sentient_native.press_key", workAppIdentifier: "com.apple.Notes", metrics: metrics,
                onStop: { stopped += 1 }, canShowWorkWindow: true, onShowWorkWindow: { focused += 1 },
                onOpenConversation: { opened += 1 }).frame(width: 800, height: 240)
            try await Task.sleep(for: .milliseconds(500))
            _ = try await SidekickPolishLab.capture(host, name: name + "-metadata-gap", directory: root)
            panel.orderOut(nil); panel.contentView = nil; panel.close()
        }
        try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("work-click-checks.json"))
        guard results.values.allSatisfy({ $0 }) else { throw NSError(domain: "WorkWindowClickFixture", code: 2) }
    }

    private struct LayoutRefinement: View {
        var hardwareIsland = false
        private var metrics: NotchMetrics {
            .init(hardwareNotch: hardwareIsland ? CGSize(width: 200, height: 44) : nil, hardwareIsland: hardwareIsland)
        }
        private var compactMetrics: NotchMetrics { var value = metrics; value.compactMode = true; return value }
        private let recovery: SidekickRecovery = {
            let value = SidekickRecovery()
            value.present(.clarification(try! SidekickQuestion(error: nil,
                question: "Which version should I use?", answers: ["Short and sweet", "More detail"]))) { _ in }
            return value
        }()
        private let speech: DictationPresentation = {
            let value = DictationPresentation(); value.capturing = true; value.connected = true
            for i in 0..<24 { value.push(Float(i % 6) / 6) }
            return value
        }()
        private let response = SidekickConversationStore.Record(sequence: 1,
            event: .init(taskID: UUID(), kind: .assistantMessage,
                         text: "You have a **quiet afternoon** after your design review.\n\nI can help you prepare the update and find time for a walk."))
        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                Text(hardwareIsland ? "Hardware island · protected center" : "External island · balanced spacing").font(.system(size: 25, weight: .medium))
                HStack(spacing: 24) {
                    cell("WORKING", height: 126) {
                        NotchContent(phase: .running, readBack: nil, statusLine: "→ sentient_native.get_app_state",
                                     activity: IslandColorComparison.notesActivity, metrics: metrics)
                    }
                    cell("LISTENING", height: 126) {
                        NotchContent(phase: .listening, readBack: nil, statusLine: "", dictation: speech,
                                     metrics: metrics)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    cell("PROMPT", height: 224) {
                        NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: metrics)
                    }
                    cell("RESPONSE", height: 224) {
                        NotchContent(phase: .message, readBack: nil, statusLine: "", metrics: metrics, message: response)
                    }
                }
                HStack(spacing: 24) {
                    cell("COMPACT", height: 250) {
                        NotchContent(phase: .running, readBack: nil, statusLine: "Thinking…", metrics: compactMetrics)
                    }
                    cell("QUESTION", height: 250) {
                        NotchContent(phase: .recovery, readBack: nil, statusLine: "", metrics: metrics, recovery: recovery)
                    }
                }
                Text(hardwareIsland ? "Actual app rendering · Illustrative camera cutout · Device geometry comes from macOS" : "Actual app rendering · Equal icon insets · Shared centerline · Concentric input surfaces")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(28).frame(width: 1280, height: 840)
            .background(Color(red: 0.035, green: 0.039, blue: 0.052))
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .environment(\.sidekickReduceMotionOverride, true)
            .environment(\.islandColorTime, 2)
        }
        private func cell<Content: View>(_ title: String, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
            ZStack(alignment: .topLeading) {
                Color(red: 0.12, green: 0.14, blue: 0.19)
                if hardwareIsland {
                    Color.white.opacity(0.045).frame(height: metrics.hardwareMenuHeight).offset(y: 38)
                }
                Text(title).font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.6)
                    .foregroundStyle(.white.opacity(0.45)).padding(14)
                content().frame(width: 600, height: height - 40).padding(.top, 38)
                if hardwareIsland {
                    Capsule().fill(.black).frame(width: 180, height: 24)
                        .frame(width: 600).offset(y: 38 + metrics.hardwareMenuHeight / 2 - 12).allowsHitTesting(false)
                }
            }
            .frame(width: 600, height: height).clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private struct Comparison: View {
        let frame: Frame
        private let speech: DictationPresentation = {
            let value = DictationPresentation()
            value.capturing = true; value.connected = true
            value.text = "Find a time for coffee with Alex tomorrow."
            for i in 0..<24 { value.push(Float(i % 6) / 6) }
            return value
        }()
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Three ways to light the glass").font(.system(size: 27, weight: .semibold))
                    Spacer()
                    Text("B + TWO NEW DIRECTIONS").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(.white.opacity(0.4))
                }
                HStack(spacing: 20) {
                    heading("B · Soft halo", "Your favorite. Quiet glass, soft colored light.")
                    heading("C · Pearl", "Smoked glass with a moving silvery reflection.")
                    heading("D · Underlight", "Deep glass with color glowing from below.")
                }
                row("WORKING", phase: .running, height: 140)
                row("TYPE", phase: .typing, height: 198)
                row("VOICE", phase: .listening, height: 140)
                Text("Actual Sidekick views · Same controls and dimensions · Preview only")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(28).frame(width: 1656, height: 732)
            .background(Color(red: 0.035, green: 0.039, blue: 0.052))
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .environment(\.sidekickReduceMotionOverride, true)
            .environment(\.islandColorTime, frame.time)
        }
        private func heading(_ title: String, _ detail: String) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 18, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }.frame(width: 520, alignment: .leading)
        }
        private func row(_ label: String, phase: NotchPhase, height: CGFloat) -> some View {
            HStack(spacing: 20) {
                cell(label, phase: phase, height: height, treatment: .softHalo)
                cell(label, phase: phase, height: height, treatment: .pearl)
                cell(label, phase: phase, height: height, treatment: .underlight)
            }
        }
        private func cell(_ label: String, phase: NotchPhase, height: CGFloat, treatment: IslandColorTreatment) -> some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.14, green: 0.18, blue: 0.24), Color(red: 0.21, green: 0.18, blue: 0.22), Color(red: 0.12, green: 0.14, blue: 0.20)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.8)
                    .foregroundStyle(.white.opacity(0.4)).padding(14)
                NotchContent(phase: phase, readBack: nil, statusLine: "Looking at Spotify", dictation: speech,
                             metrics: NotchMetrics(hardwareNotch: nil))
                    .environment(\.islandColorTreatment, treatment)
                    .frame(width: 520, height: height - 40)
                    .padding(.top, 35)
            }.frame(width: 520, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
    private struct SelectedUnderlight: View {
        let frame: Frame
        private let speech: DictationPresentation = {
            let value = DictationPresentation()
            value.capturing = true; value.connected = true
            value.text = "Find a time for coffee with Alex tomorrow."
            for i in 0..<24 { value.push(Float(i % 6) / 6) }
            return value
        }()
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Underlight · on every display").font(.system(size: 27, weight: .semibold))
                    Spacer()
                    Text("SENTIENT").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1.5).foregroundStyle(.white.opacity(0.4))
                }
                HStack(spacing: 24) {
                    heading("MacBook notch", "Black at the top. Soft glass below. A fine line of light.")
                    heading("External display", "Floating dark glass. Soft color from underneath.")
                }
                row("TYPE", phase: .typing, height: 198)
                row("WORKING", phase: .running, height: 140)
                row("VOICE", phase: .listening, height: 140)
                Text("Selected design · Actual app rendering · Colors shown across one 12-second cycle")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(28).frame(width: 1280, height: 732)
            .background(Color(red: 0.035, green: 0.039, blue: 0.052))
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .environment(\.sidekickReduceMotionOverride, true)
            .environment(\.islandColorTime, frame.time)
        }
        private func heading(_ title: String, _ detail: String) -> some View {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 19, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }.frame(width: 600, alignment: .leading)
        }
        private func row(_ label: String, phase: NotchPhase, height: CGFloat) -> some View {
            HStack(spacing: 24) {
                cell(label, phase: phase, height: height, hardware: CGSize(width: 200, height: 32))
                cell(label, phase: phase, height: height, hardware: nil)
            }
        }
        private func cell(_ label: String, phase: NotchPhase, height: CGFloat, hardware: CGSize?) -> some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.14, green: 0.18, blue: 0.24), Color(red: 0.21, green: 0.18, blue: 0.22), Color(red: 0.12, green: 0.14, blue: 0.20)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.black.frame(height: 10)
                NotchContent(phase: phase, readBack: nil, statusLine: "Looking at Spotify", dictation: speech,
                             metrics: NotchMetrics(hardwareNotch: hardware))
                    .frame(width: 600, height: height - 10)
                    .padding(.top, 10)
                VStack {
                    Spacer()
                    Text(label).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.8)
                        .foregroundStyle(.white.opacity(0.4)).padding(14)
                }
            }.frame(width: 600, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private struct LogoMatch: View {
        let reference: NSImage
        private let paddingRatio = 82.3392 / 42.0098
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text("The website orb, rendered natively").font(.system(size: 27, weight: .semibold))
                HStack(spacing: 24) {
                    column("Website SVG", native: false)
                    column("Native app", native: true)
                }
                Text("In the notch").font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
                NotchContent(phase: .typing, readBack: nil, statusLine: "", metrics: .preview)
                    .frame(width: 1224, height: 140)
                    .background(Color(white: 0.10))
                Text("Original gradient stops, blur proportions, outer outline and center dot. No sharp colored ring.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(28).frame(width: 1280, height: 732)
            .foregroundStyle(.white).background(.black).preferredColorScheme(.dark)
            .environment(\.sidekickReduceMotionOverride, true)
        }
        private func column(_ title: String, native: Bool) -> some View {
            VStack(spacing: 18) {
                Text(title).font(.system(size: 19, weight: .medium))
                mark(size: 120, native: native).frame(height: 236)
                HStack(spacing: 24) {
                    ForEach([17.0, 24.0, 40.0], id: \.self) { size in
                        VStack(spacing: 4) {
                            mark(size: size, native: native).frame(width: 96, height: 80)
                            Text("\(Int(size)) pt").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }.frame(width: 600)
        }
        @ViewBuilder private func mark(size: CGFloat, native: Bool) -> some View {
            if native {
                WebsiteLogoMark(size: size).frame(width: size * paddingRatio, height: size * paddingRatio)
            } else {
                Image(nsImage: reference).resizable().frame(width: size * paddingRatio, height: size * paddingRatio)
            }
        }
    }

}
#endif
