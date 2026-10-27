// The short, click-through explanation after a Double Tap that needs personal setup.
import AppKit
import SwiftUI

@MainActor
final class DoubleTapSetupNotice {
    static let message = "Finish Sentient setup and analysis to use Double Tap."
    static let duration: Duration = .seconds(3)
    private var panel: NSPanel?

    /// Polling the pointer only while visible works without requesting input-monitoring access.
    /// This panel never becomes key, activates Sentient, or intercepts the user's clicks.
    func show() async {
        guard !Task.isCancelled else { return }
        let panel = self.panel ?? makePanel()
        position(panel)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
            userInfo: [.announcement: Self.message, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        defer { dismiss() }
        let until = ContinuousClock.now + Self.duration
        while ContinuousClock.now < until && !Task.isCancelled {
            position(panel)
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
        }
    }

    func dismiss() { panel?.orderOut(nil) }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        panel.setFrameOrigin(Self.origin(near: mouse, size: panel.frame.size, within: screen.visibleFrame))
    }

    /// Flip at the right/bottom edges, then clamp, including displays left of the main screen.
    static func origin(near mouse: CGPoint, size: CGSize, within screen: CGRect) -> CGPoint {
        let margin: CGFloat = 8
        var x = mouse.x + 18
        var y = mouse.y - size.height - 20
        if x + size.width > screen.maxX - margin { x = mouse.x - size.width - 18 }
        if y < screen.minY + margin { y = mouse.y + 24 }
        return CGPoint(x: max(screen.minX + margin, min(x, screen.maxX - size.width - margin)),
                       y: max(screen.minY + margin, min(y, screen.maxY - size.height - margin)))
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: DoubleTapSetupNoticeView())
        let panel = DoubleTapNoticePanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = .screenSaver
        self.panel = panel
        return panel
    }
}

private final class DoubleTapNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DoubleTapSetupNoticeView: View {
    var body: some View {
        Text(DoubleTapSetupNotice.message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 274, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .accessibilityIdentifier("doubleTap.setupNotice")
    }
}

#Preview { DoubleTapSetupNoticeView().padding(24) }
