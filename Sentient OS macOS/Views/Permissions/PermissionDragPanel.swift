//
//  PermissionDragPanel.swift
//  Sentient OS macOS
//
//  PermissionGuide's floating panel: a borderless, NON-ACTIVATING NSPanel (System Settings keeps
//  visual focus) that flies from the pressed button to just below the Settings window's content
//  area and follows it. In drag mode it carries the .app card (AppDragSourceView) whose drag
//  payload is shaped to look Finder-originated — the exact pasteboard mix System Settings accepts
//  into its privacy lists; while dragging, the panel goes mouse-transparent so the drop lands in
//  Settings. The SwiftUI content (PermissionPanelView) speaks the app's design language.
//
//  ⚠️ hostingView.sizingOptions = [] is load-bearing: with the default .intrinsicContentSize the
//  hosting view re-advertises its own size to the window every layout pass and every setFrame is
//  reverted, stranding the panel off-screen (documented upstream).
//  Mechanics adapted from PermissionFlow (github.com/jaywcjlove/PermissionFlow, MIT).
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - The panel window

@MainActor
final class PermissionDragPanel: NSPanel {
    private weak var guide: PermissionGuide?
    private let hostingView: NSHostingView<PermissionPanelView>
    private let sizingView: NSHostingView<PermissionPanelView>
    private let initialPanelWidth: CGFloat = 420

    /// System Settings' leading sidebar width — the panel aligns to the trailing content area.
    private let sidebarWidth: CGFloat = 230
    private let screenInset: CGFloat = 12
    private let minimumPanelHeight: CGFloat = 96
    private let sizingHeightLimit: CGFloat = 4096

    // Launch animation, tuned upstream to settle without overshoot while the target window is moving.
    private let animationDuration: TimeInterval = 0.72
    private let animationResponse: Double = 0.72
    private let initialAlpha: CGFloat = 0.9
    private let minimumLaunchScale: CGFloat = 0.58
    private var launchTimer: Timer?
    private var launchStartTime: CFTimeInterval = 0
    private var launchFromFrame = NSRect.zero
    private var launchToFrame = NSRect.zero
    private var isAnimatingLaunch = false

    init(guide: PermissionGuide) {
        self.guide = guide
        hostingView = NSHostingView(rootView: PermissionPanelView(guide: guide))
        sizingView = NSHostingView(rootView: PermissionPanelView(guide: guide))
        super.init(
            contentRect: CGRect(origin: .zero, size: CGSize(width: initialPanelWidth, height: minimumPanelHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.sizingOptions = []   // see the top-of-file warning
        contentView = hostingView
        setContentSize(CGSize(width: initialPanelWidth, height: measuredPanelHeight(for: initialPanelWidth)))
    }

    /// Non-activating on purpose — System Settings must stay the visible focus owner.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            guide?.keepSettingsVisible()
        }
        super.sendEvent(event)
    }

    /// Show at the launch source before the Settings frame is known.
    func show(at sourceFrameInScreen: CGRect) {
        stopLaunchAnimation()
        isAnimatingLaunch = false
        alphaValue = 1
        setContentSize(CGSize(width: frame.width, height: measuredPanelHeight(for: frame.width)))
        setFrame(launchSourceFrame(for: sourceFrameInScreen), display: false)
        orderFrontRegardless()
    }

    /// Fly from the triggering UI element to the Settings window.
    func present(from sourceFrameInScreen: CGRect, to settingsFrame: CGRect) {
        stopLaunchAnimation()
        let targetFrame = targetFrame(for: settingsFrame)

        guard sourceFrameInScreen.isEmpty == false else {
            isAnimatingLaunch = false
            alphaValue = 1
            setFrame(targetFrame, display: false)
            orderFrontRegardless()
            return
        }

        isAnimatingLaunch = true
        launchFromFrame = launchSourceFrame(for: sourceFrameInScreen)
        launchToFrame = targetFrame
        launchStartTime = CACurrentMediaTime()
        alphaValue = initialAlpha
        setFrame(launchFromFrame, display: false)
        orderFrontRegardless()
        stepLaunchAnimation()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stepLaunchAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        launchTimer = timer
    }

    /// While the app card is being dragged, mouse events pass through so Settings gets the drop.
    func setDraggingPassthrough(_ isDragging: Bool) {
        ignoresMouseEvents = isDragging
        alphaValue = isDragging ? 0.72 : 1.0
        if isDragging { orderBack(nil) } else { orderFrontRegardless() }
    }

    /// Follow the tracked Settings frame. Mid-launch, only the destination updates (continuous motion).
    func snap(to settingsFrame: CGRect) {
        let target = targetFrame(for: settingsFrame)
        if isAnimatingLaunch {
            launchToFrame = target
            return
        }
        stopLaunchAnimation()
        setFrame(target, display: false)
        orderFrontRegardless()
    }

    /// Final frame: under the Settings window, aligned to its trailing content area (past the
    /// sidebar), clamped to the visible screen. Visual-attachment tuning belongs HERE (upstream note).
    private func targetFrame(for settingsFrame: CGRect) -> CGRect {
        let screenFrame = NSScreen.screens
            .first(where: { $0.frame.intersects(settingsFrame) })?
            .visibleFrame ?? settingsFrame

        let contentMinX = settingsFrame.minX + sidebarWidth
        let availableContentWidth = max(240, settingsFrame.width - sidebarWidth)
        let width = min(availableContentWidth, screenFrame.width - (screenInset * 2))
        let height = measuredPanelHeight(for: width)

        var origin = CGPoint(x: contentMinX, y: settingsFrame.minY - height)
        origin.x = max(screenFrame.minX + screenInset, min(origin.x, screenFrame.maxX - width - screenInset))
        origin.y = max(screenFrame.minY + screenInset, min(origin.y, screenFrame.maxY - height - screenInset))

        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func launchSourceFrame(for sourceFrameInScreen: CGRect) -> CGRect {
        let launchSize = CGSize(
            width: max(sourceFrameInScreen.width, frame.width * minimumLaunchScale),
            height: max(sourceFrameInScreen.height, frame.height * minimumLaunchScale)
        )
        let center = CGPoint(x: sourceFrameInScreen.midX, y: sourceFrameInScreen.midY)
        return CGRect(
            x: center.x - (launchSize.width * 0.5),
            y: center.y - (launchSize.height * 0.5),
            width: launchSize.width,
            height: launchSize.height
        )
    }

    /// Measure the SwiftUI content at a width so the panel height fits before positioning.
    private func measuredPanelHeight(for width: CGFloat) -> CGFloat {
        sizingView.setFrameSize(NSSize(width: width, height: sizingHeightLimit))
        sizingView.layoutSubtreeIfNeeded()
        return max(minimumPanelHeight, sizingView.fittingSize.height)
    }

    private func stepLaunchAnimation() {
        let elapsed = max(0, CACurrentMediaTime() - launchStartTime)
        if elapsed >= animationDuration {
            isAnimatingLaunch = false
            stopLaunchAnimation()
            alphaValue = 1
            setFrame(launchToFrame, display: true)
            return
        }
        let progress = springProgress(at: elapsed)
        alphaValue = initialAlpha + ((1 - initialAlpha) * progress)
        setFrame(curvedFrame(from: launchFromFrame, to: launchToFrame, progress: progress), display: true)
    }

    private func stopLaunchAnimation() {
        launchTimer?.invalidate()
        launchTimer = nil
    }

    private func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / animationResponse
        let progress = 1 - exp(-omega * elapsed) * (1 + (omega * elapsed))
        return min(max(progress, 0), 1)
    }

    /// Quadratic-bezier interpolation — the soft "fly to target" arc.
    private func curvedFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        let size = CGSize(
            width: from.width + ((to.width - from.width) * progress),
            height: from.height + ((to.height - from.height) * progress)
        )
        let startCenter = CGPoint(x: from.midX, y: from.midY)
        let endCenter = CGPoint(x: to.midX, y: to.midY)
        let midpoint = CGPoint(x: (startCenter.x + endCenter.x) * 0.5, y: max(startCenter.y, endCenter.y))
        let distance = hypot(endCenter.x - startCenter.x, endCenter.y - startCenter.y)
        let lift = min(140, max(44, distance * 0.18))
        let controlPoint = CGPoint(x: midpoint.x, y: midpoint.y + lift)
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * startCenter.x) + (2 * inverse * progress * controlPoint.x) + (progress * progress * endCenter.x),
            y: (inverse * inverse * startCenter.y) + (2 * inverse * progress * controlPoint.y) + (progress * progress * endCenter.y)
        )
        return CGRect(
            x: center.x - (size.width * 0.5),
            y: center.y - (size.height * 0.5),
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - The panel content (Sentient-voiced)

/// The floating card's face: a mono-caps whisper, the one-line instruction, and (drag mode) the
/// app card to drag. OLED black with a hairline ring — it should read as a piece of Sentient
/// hovering beside System Settings.
struct PermissionPanelView: View {
    let guide: PermissionGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let appURL = guide.job?.appURL {
                AppDragItemView(url: appURL) { dragging in
                    guide.setDragging(dragging)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1))
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                GuideDirectionIcon(isDragging: guide.isDraggingApp, isDragMode: guide.job?.appURL != nil)
                VStack(alignment: .leading, spacing: 3) {
                    MonoCaps(verbatim: guide.job?.pane.title ?? "", size: 8.5, tracking: 2.0,
                             color: Theme.Ink.label)
                    Text(guide.instruction)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .top, spacing: 4) {
                if guide.isSettingsFrontmost == false {
                    Button { guide.reopenSettings() } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Ink.label)
                    }
                    .buttonStyle(.plain)
                }
                Button { guide.close() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.Ink.label, Color.white.opacity(0.12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The little animated pointer — drifts gently up and down at rest, pulses while the card is
/// being dragged.
private struct GuideDirectionIcon: View {
    let isDragging: Bool
    let isDragMode: Bool

    @State private var driftPhase = false
    @State private var scalePhase = false

    var body: some View {
        Image(systemName: isDragMode ? "arrowshape.up.fill" : "switch.2")
            .font(.system(size: 14, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.Ink.green)
            .offset(y: isDragging || !isDragMode ? 0 : (driftPhase ? -2 : 2))
            .scaleEffect(isDragging ? (scalePhase ? 1.18 : 0.88) : 1)
            .animation(
                isDragging
                    ? .easeInOut(duration: 0.68).repeatForever(autoreverses: true)
                    : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: isDragging ? scalePhase : driftPhase
            )
            .onAppear { if isDragMode { driftPhase = true } }
            .onChange(of: isDragging) { _, dragging in
                if dragging {
                    scalePhase = true
                    driftPhase = false
                } else {
                    scalePhase = false
                    driftPhase = isDragMode
                }
            }
    }
}

// MARK: - The drag source (the actual magic)

private struct AppDragItemView: NSViewRepresentable {
    let url: URL
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> AppDragSourceView {
        let view = AppDragSourceView(url: url)
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: AppDragSourceView, context: Context) {
        nsView.update(url: url)
        nsView.onDragStateChange = onDragStateChange
    }
}

/// An NSView drag source whose payload mimics a Finder file drag — the pasteboard-type mix
/// System Settings' privacy lists actually accept (fileURL + NSFilenamesPboardType +
/// promised-file-url + string, with the app icon as the drag image).
final class AppDragSourceView: NSView, NSDraggingSource {
    private var url: URL
    private let hostingView: NSHostingView<AnyView>
    private var mouseDownPoint: NSPoint?
    private var hasBegunDragging = false

    /// Tells the panel to become mouse-transparent for the drag's duration.
    var onDragStateChange: ((Bool) -> Void)?

    init(url: URL) {
        self.url = url
        self.hostingView = NSHostingView(rootView: AnyView(AppDragCardContent(url: url).allowsHitTesting(false)))
        super.init(frame: .zero)

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(url: URL) {
        self.url = url
        hostingView.rootView = AnyView(AppDragCardContent(url: url).allowsHitTesting(false))
        invalidateIntrinsicContentSize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(64, hostingView.fittingSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasBegunDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard hasBegunDragging == false, let mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 4 else { return }
        hasBegunDragging = true
        beginAppDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStateChange?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragStateChange?(false)
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    private func beginAppDrag(with event: NSEvent) {
        let writer = AppBundlePasteboardWriter(url: url)
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 56, height: 56)
        let dragPoint = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(x: dragPoint.x - 28, y: dragPoint.y - 28, width: 56, height: 56),
            contents: icon
        )
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
}

private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL

    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            .string
        ]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"):
            return url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"):
            return [url.path]
        case .string:
            return url.path
        default:
            return nil
        }
    }
}

/// The draggable app card — icon, name, and a quiet "drag" affordance on a dashed ring.
private struct AppDragCardContent: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            Text(FileManager.default.displayName(atPath: url.path))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            VStack(spacing: 1) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 13))
                MonoCaps("DRAG", size: 7, tracking: 1.6, color: Theme.Ink.label)
            }
            .foregroundStyle(Theme.Ink.label)
            .padding(.trailing, 4)
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}
