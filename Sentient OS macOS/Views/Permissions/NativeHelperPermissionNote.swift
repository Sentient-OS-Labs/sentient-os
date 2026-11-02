// A nonactivating companion to the owned native helper's actual setup window.
// Optional AX geometry improves placement; it never determines permission readiness.
import AppKit
import SwiftUI
@preconcurrency import ApplicationServices

@MainActor final class NativeHelperPermissionNote {
    @Observable final class Visibility {
        private var visibleNotes: Set<UUID> = []
        var isVisible: Bool { !visibleNotes.isEmpty }

        func setVisible(_ visible: Bool, for id: UUID) {
            guard visibleNotes.contains(id) != visible else { return }
            if visible { visibleNotes.insert(id) }
            else { visibleNotes.remove(id) }
        }
    }
    static let visibility = Visibility()
    private let visibilityID = UUID()
    private var tracker: SettingsWindowTracker?
    private var helperPID: pid_t?
    private let helperLookup: () -> NSRunningApplication?
    private var helperTimer: Timer?
    private var closed = false
    private var panel: NSPanel?
    private var anchorTask: Task<Void, Never>?
    private var measuredHeight: CGFloat = 130

    private init(appURL: URL, lookup: (() -> NSRunningApplication?)? = nil) {
        helperLookup = lookup ?? {
            NSRunningApplication.runningApplications(withBundleIdentifier: OpenAIComputerUse.bundleID)
                .first { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }
        }
        helperTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHelper() }
        }
        helperTimer?.tolerance = 0.05
        refreshHelper()
    }

    private func refreshHelper() {
        guard !closed else { return }
        guard let helper = helperLookup(), !helper.isTerminated else {
            detachHelper()
            return
        }
        let pid = helper.processIdentifier
        guard helperPID != pid else { return }
        detachHelper()
        helperPID = pid
        // The helper's main setup window floats at level 3. Its separate drag guide
        // sits at level 0 over System Settings and must never receive this note.
        let tracker = SettingsWindowTracker(application: helper, pollInterval: 0.1, usesAccessibility: false,
            windowLevels: [NSWindow.Level.floating.rawValue], onlyWhenApplicationActive: true)
        self.tracker = tracker
        tracker.onFrameChange = { [weak self] frame in
            guard self?.helperPID == pid else { return }
            self?.show(beside: frame)
        }
        tracker.onWindowMissing = { [weak self] in
            guard self?.helperPID == pid else { return }
            self?.hide()
        }
        tracker.onTrackingEnded = { [weak self] in
            guard self?.helperPID == pid else { return }
            self?.detachHelper()
        }
        tracker.startTracking()
    }

    private func detachHelper() {
        anchorTask?.cancel(); anchorTask = nil
        tracker?.stopTracking(); tracker = nil
        helperPID = nil
        hide()
    }

    private func hide() {
        panel?.orderOut(nil)
        Self.visibility.setVisible(false, for: visibilityID)
    }

    private static func start(appURL: URL) -> NativeHelperPermissionNote? {
        guard !Task.isCancelled else { return nil }
        return NativeHelperPermissionNote(appURL: appURL)
    }

    nonisolated static func withGuide<Result: Sendable>(appURL: URL,
        operation: @Sendable () async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        // Decorative UI must never hold up native tool execution or cancellation.
        let guide = Task { @MainActor in start(appURL: appURL) }
        defer {
            guide.cancel()
            Task { @MainActor in
                let note = await guide.value
                note?.close()
            }
        }
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private func show(beside target: CGRect) {
        guard !closed, let pid = helperPID else { return }
        guard let screen = NSScreen.screens.filter({ $0.visibleFrame.intersects(target) }).max(by: {
            $0.visibleFrame.intersection(target).width * $0.visibleFrame.intersection(target).height
                < $1.visibleFrame.intersection(target).width * $1.visibleFrame.intersection(target).height
        }) else { return }
        let available = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let rightSpace = available.maxX - target.maxX
        let leftSpace = target.minX - available.minX
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
            let content = NSHostingController(rootView: NativeHelperPermissionNoteView().frame(width: width))
            content.sizingOptions = []
            measuredHeight = content.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
            panel.contentViewController = content
        }
        panel.setFrame(Self.noteFrame(target: target, available: available,
                                      size: CGSize(width: width, height: measuredHeight)), display: true)
        panel.orderFrontRegardless()
        Self.visibility.setVisible(true, for: visibilityID)
        anchorTask?.cancel()
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        anchorTask = Task.detached { [weak self] in
            guard let anchor = Self.browserRowCenter(pid: pid, desktopTop: desktopTop), !Task.isCancelled else { return }
            await self?.alignBrowserRow(anchor, target: target, available: available)
        }
    }

    nonisolated static func noteFrame(target: CGRect, available: CGRect, size: CGSize) -> CGRect {
        // Permissionless placement for the pinned helper's browser row, in its bottom section.
        var origin = CGPoint(x: target.maxX, y: target.minY + target.height * 0.15 - size.height / 2)
        if available.maxX - target.maxX < size.width {
            if target.minX - available.minX >= size.width { origin.x = target.minX - size.width }
            else { origin = CGPoint(x: target.midX - size.width / 2, y: target.minY - size.height - 12) }
        }
        origin.x = min(max(origin.x, available.minX), available.maxX - size.width)
        origin.y = min(max(origin.y, available.minY), available.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    private func alignBrowserRow(_ anchor: CGFloat, target: CGRect, available: CGRect) {
        guard tracker?.currentFrame == target, let panel, panel.isVisible,
              target.minY...target.maxY ~= anchor,
              panel.frame.maxX <= target.minX || panel.frame.minX >= target.maxX else { return }
        var frame = panel.frame
        frame.origin.y = min(max(anchor - frame.height / 2, available.minY), available.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    nonisolated private static func browserRowCenter(pid: pid_t, desktopTop: CGFloat) -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.height > 0 else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        var pending = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var label: CGRect?
        var buttons: [CGRect] = []
        var examined = 0
        while let element = pending.popLast(), examined < 120, !Task.isCancelled {
            examined += 1
            let text = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .compactMap { attribute(element, $0) as? String }.joined(separator: " ").lowercased()
            if text.contains("extension") && (text.contains("chrome") || text.contains("browser")) {
                label = frame(element)
                if let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID(),
                   let row = frame(parent as! AXUIElement), row.height >= 50, row.height < 180 {
                    return desktopTop - row.midY
                }
            }
            if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole, let button = frame(element) {
                buttons.append(button)
            }
            pending += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard let label, let control = buttons.filter({
            $0.minX >= label.maxX && abs($0.midY - label.midY) < 45
        }).min(by: { abs($0.midY - label.midY) < abs($1.midY - label.midY) }) else { return nil }
        return desktopTop - control.midY
    }

    private func close() {
        closed = true
        helperTimer?.invalidate(); helperTimer = nil
        detachHelper()
        panel?.close(); panel = nil
    }
}

struct NativeHelperPermissionNoteView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Skip browser extension installation", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
            Text("You don’t need to enable the browser extension. Sentient doesn’t use it.")
                .font(.system(size: 12)).foregroundStyle(.black.opacity(0.75))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1)
        }
        .preferredColorScheme(.light)
    }
}
