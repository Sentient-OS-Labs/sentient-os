// A nonactivating companion to the owned native helper's actual setup window.
// It watches geometry only, never reads its controls or fabricates permission status.
import AppKit
import SwiftUI

@MainActor final class NativeHelperPermissionNote {
    private let tracker: SettingsWindowTracker
    private var panel: NSPanel?

    private init(helper: NSRunningApplication) {
        // The helper's main setup window floats at level 3. Its separate drag guide
        // sits at level 0 over System Settings and must never receive this note.
        tracker = SettingsWindowTracker(application: helper, pollInterval: 0.1, usesAccessibility: false,
            windowLevels: [NSWindow.Level.floating.rawValue], onlyWhenApplicationActive: true)
        tracker.onFrameChange = { [weak self] frame in self?.show(beside: frame) }
        tracker.onWindowMissing = { [weak self] in self?.panel?.orderOut(nil) }
        tracker.onTrackingEnded = { [weak self] in self?.close() }
        tracker.startTracking()
    }

    private static func start(appURL: URL) -> NativeHelperPermissionNote? {
        guard !Task.isCancelled,
              let helper = NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
                .first(where: { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }) else { return nil }
        return NativeHelperPermissionNote(helper: helper)
    }

    nonisolated static func withGuide(appURL: URL,
        operation: @Sendable () async throws -> NativePermissionReadiness.Snapshot) async throws -> NativePermissionReadiness.Snapshot {
        try Task.checkCancellation()
        let note = await start(appURL: appURL)
        do {
            let result = try await operation()
            await note?.close()
            try Task.checkCancellation()
            return result
        } catch {
            await note?.close()
            throw error
        }
    }

    private func show(beside target: CGRect) {
        guard let screen = NSScreen.screens.filter({ $0.visibleFrame.intersects(target) }).max(by: {
            $0.visibleFrame.intersection(target).width * $0.visibleFrame.intersection(target).height
                < $1.visibleFrame.intersection(target).width * $1.visibleFrame.intersection(target).height
        }) else { return }
        let available = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let rightSpace = available.maxX - target.maxX - 12
        let leftSpace = target.minX - available.minX - 12
        let width = min(280, max(200, max(rightSpace, leftSpace)))
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.level = .floating
            panel.title = "Computer-use permission help"
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
            self.panel = panel
        }
        guard let panel else { return }
        if panel.contentView == nil || abs(panel.frame.width - width) > 1 {
            panel.contentView = NSHostingView(rootView: NativeHelperPermissionNoteView().frame(width: width))
        }
        let height = panel.contentView?.fittingSize.height ?? 130
        var origin = CGPoint(x: target.maxX + 12, y: target.maxY - height)
        if rightSpace < width {
            if leftSpace >= width { origin.x = target.minX - width - 12 }
            else { origin = CGPoint(x: target.midX - width / 2, y: target.minY - height - 12) }
        }
        origin.x = min(max(origin.x, available.minX), available.maxX - width)
        origin.y = min(max(origin.y, available.minY), available.maxY - height)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    private func close() {
        tracker.stopTracking()
        panel?.close(); panel = nil
    }
}

struct NativeHelperPermissionNoteView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Just two permissions", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Text("Enable Accessibility and Screenshots (Screen Recording).")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            Text("You don’t need to enable the browser extension. Sentient doesn’t use it.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .background { PermissionWindowAtmosphere() }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LinearGradient(
                    colors: [Theme.dawnCyan.opacity(0.95), Theme.accent.opacity(0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
        }
        .preferredColorScheme(.dark)
    }
}
