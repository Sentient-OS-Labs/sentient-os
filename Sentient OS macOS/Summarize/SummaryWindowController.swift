// Native floating reading window for Summarize. Keeps its geometry stable while streaming,
// preserves the source app's keyboard focus, and clears content on close or screen lock.
// Doc: Documentation - Summarize.md
import AppKit
import SwiftUI

@MainActor final class SummaryWindowController: NSObject, NSWindowDelegate {
    private weak var summary: Summarize?
    private(set) var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var shownDisplayID: CGDirectDisplayID?

    init(summary: Summarize) {
        self.summary = summary
        super.init()
        for notification in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: notification,
                object: nil, queue: .main) { [weak summary] _ in MainActor.assumeIsolated { summary?.dismiss() } })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return }
                guard let screen = NSScreen.screens.first(where: { $0.displayID == self.shownDisplayID }), let panel = self.panel else {
                    self.summary?.dismiss(); return
                }
                let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
                var frame = panel.frame
                frame.size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                panel.contentMaxSize = visible.size
                panel.contentMinSize = NSSize(width: min(360, visible.width), height: min(260, visible.height))
                panel.setFrame(frame, display: true)
            } })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func show(on displayID: CGDirectDisplayID?) {
        guard let summary else { return }
        let panel: ReadingPanel
        if let existing = self.panel as? ReadingPanel { panel = existing }
        else {
            panel = ReadingPanel(title: "Summary", identifier: "sentient.summary", size: NSSize(width: 560, height: 440))
            panel.onDismiss = { [weak summary] in summary?.dismiss() }
            panel.delegate = self
            panel.install(SummaryView(summary: summary))
            self.panel = panel
        }
        if !panel.isVisible || shownDisplayID != displayID {
            if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.main {
                let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
                let width = min(560, visible.width), height = min(440, visible.height)
                panel.contentMinSize = NSSize(width: min(360, width), height: min(260, height))
                panel.contentMaxSize = visible.size
                var frame = NSRect(x: visible.midX - width / 2,
                    y: visible.midY - height / 2 + min(40, max(0, (visible.height - height) / 2)),
                    width: width, height: height)
                // Use the full window list, including auxiliary panels, and prefer the newest.
                if let previous = NSApp.windows.filter({
                    $0 !== panel && $0.isVisible && $0.identifier?.rawValue == "sentient.summary"
                        && $0.screen?.displayID == screen.displayID
                }).max(by: { $0.windowNumber < $1.windowNumber }) {
                    let cascaded = NSRect(x: previous.frame.minX + 28, y: previous.frame.maxY - height - 28,
                                          width: width, height: height)
                    if visible.contains(cascaded) { frame = cascaded }
                    else { frame.origin = NSPoint(x: visible.minX, y: visible.maxY - height) }
                }
                panel.setFrame(frame, display: false)
            }
        }
        shownDisplayID = displayID
        // Keep tab-switching shortcuts in the browser. The reader becomes key when clicked.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil // Release native text storage and SwiftUI's selection snapshot.
        panel?.delegate = nil
        panel = nil; shownDisplayID = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { summary?.dismiss(); return false }
}
