#if DEBUG
// Screenshot-only comparison of real production views over an identical wallpaper crop.
// Runs in the isolated dictation lab; callbacks are inert and no audio is captured.
import AppKit
import SwiftUI

struct IslandGlassComparison: View {
    let dictation: DictationPresentation
    private let wallpaper: NSImage? = {
        guard let screen = NotchWindowController.menuBarScreen(),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }()
    private let rows: [(String, NotchPhase, Bool)] = [
        ("TYPE", .typing, false),
        ("VOICE", .listening, false),
        ("WORKING", .running, false),
        ("DONE", .finishing(.success), false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sidekick · External displays").font(.system(size: 26, weight: .semibold))
                Spacer()
                Text("Actual app rendering").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 24) {
                heading("Black", detail: "Original surface")
                heading("Liquid Glass", detail: "Native glass · luminous spectrum edge")
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 24) {
                    cell(row, glass: false)
                    cell(row, glass: true)
                }
            }
            Text("The tiny resting pill stays unchanged. Glass follows the same shape, controls and spring motion.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(28)
        .frame(width: 1280)
        .background(Color(white: 0.065))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .environment(\.sidekickReduceMotionOverride, true)
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 20, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }.frame(width: 600, alignment: .leading)
    }

    private func cell(_ row: (String, NotchPhase, Bool), glass: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(red: 0.18, green: 0.42, blue: 0.6),
                                            Color(red: 0.55, green: 0.32, blue: 0.36),
                                            Color(red: 0.28, green: 0.18, blue: 0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }.frame(width: 600, height: row.1 == .typing ? 172 : 122).clipped()
            Text(row.0).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.6).foregroundStyle(.white.opacity(0.8)).padding(12)
            NotchContent(phase: row.1, readBack: nil, statusLine: row.1 == .finishing(.success) ? "Notes organized" : "Organizing your notes",
                         dictation: dictation, metrics: NotchMetrics(hardwareNotch: nil, compactMode: row.2),
                         islandGlassEnabled: glass)
                .frame(width: 600, height: row.1 == .typing ? 142 : 92)
                .padding(.top, 24)
        }
        .frame(width: 600, height: row.1 == .typing ? 172 : 122)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
@MainActor enum IslandFocusBlurLab {
    static func capture(directory: URL) async throws -> (checks: [String: Bool], captures: [[String: Any]]) {
        let background = NSHostingView(rootView: DetailPattern().frame(width: 760, height: 340))
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 250, width: 760, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.title = "Island focus blur · synthetic backdrop"
        parent.isReleasedWhenClosed = false
        parent.contentView = background
        let panel = NotchPanel(contentRect: NSRect(x: 250, y: 275, width: 660, height: 270),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        let host = NSHostingView(rootView: NotchContent(phase: .typing, readBack: nil, statusLine: "",
            metrics: NotchMetrics(hardwareNotch: nil))
            .frame(width: 660, height: 270).preferredColorScheme(.dark)
            .environment(\.sidekickReduceMotionOverride, true))
        panel.contentView = host
        parent.addChildWindow(panel, ordered: .above)
        parent.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        defer { parent.removeChildWindow(panel); panel.close(); parent.close() }
        func backdrop(in view: NSView) -> NSVisualEffectView? {
            if view.identifier?.rawValue == "sentient.island.backdrop" { return view as? NSVisualEffectView }
            return view.subviews.lazy.compactMap { backdrop(in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(500))
        var checks = ["island-blur-focused-panel-is-key": panel.isKeyWindow,
                      "island-blur-stays-active-with-focus": backdrop(in: host)?.state == .active]
        var captures = [try await SidekickPolishLab.capture(background, name: "15-island-focused-blur", directory: directory, includingChild: panel)]
        parent.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        checks["island-blur-unfocused-panel-not-key"] = !panel.isKeyWindow && parent.isKeyWindow
        checks["island-blur-stays-active-without-focus"] = backdrop(in: host)?.state == .active
        captures.append(try await SidekickPolishLab.capture(background, name: "16-island-unfocused-blur", directory: directory, includingChild: panel))
        return (checks, captures)
    }

    private struct DetailPattern: View {
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(red: 0.23, green: 0.36, blue: 0.53), Color(red: 0.62, green: 0.36, blue: 0.25)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    ForEach(0..<12) { row in
                        HStack(spacing: 12) {
                            ForEach(0..<14) { column in
                                Text(String((row + column) % 10))
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(width: 38, height: 20)
                                    .background(.black.opacity(0.55))
                            }
                        }
                    }
                }
            }.clipped()
        }
    }
}
#endif
