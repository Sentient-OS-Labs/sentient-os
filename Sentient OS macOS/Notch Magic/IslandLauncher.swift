// A static, frosted menu-bar handle for screens without a hardware notch.
// Wallpaper sampling needs no screen-recording permission. Only this tiny crop is blurred,
// once per display configuration; no live material or animation clock runs while idle.
import AppKit
import SwiftUI
import CoreImage

/// A real behind-window blur whose activity never follows keyboard focus.
/// Expanded surfaces add a fixed tint and spectrum above this layer. The system glass
/// lens retints on key-window changes, so it is reserved for compact activity surfaces.
struct IslandBackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("sentient.island.backdrop")
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.state = .active
    }

    static func dismantleNSView(_ view: NSVisualEffectView, coordinator: ()) {
        view.isHidden = true
        view.layer?.removeAllAnimations()
    }
}

struct IslandRestingSurface: View {
    var backdrop: NSImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Capsule()
            .fill(.black.opacity(reduceTransparency ? 0.85 : 0.28))
            .overlay {
                if let backdrop, !reduceTransparency {
                    Image(nsImage: backdrop).resizable().opacity(0.5)
                }
            }
            .overlay {
                LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.035)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.23), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
    }
}

@MainActor
final class NotchEntryHandle {
    let panel: NSPanel
    let backdrop: NSImage?
    let displayID: CGDirectDisplayID
    let isIsland: Bool

    init(screen: NSScreen, onHover: @escaping () -> Void, onPress: @escaping () -> Void,
         onActivate: @escaping () -> Void) {
        displayID = screen.displayID
        isIsland = screen.notchSize == nil
        backdrop = isIsland ? Self.snapshotWallpaper(on: screen) : nil
        let frame: NSRect
        if let hardware = screen.notchSize {
            // An invisible native target over the physical cutout lets the user switch
            // back while another display owns the expanded panel. It has no SwiftUI tree.
            let height = screen.hasHardwareIsland ? screen.sidekickMenuBarHeight : hardware.height
            frame = NSRect(x: floor(screen.cameraCenterX - hardware.width / 2),
                           y: screen.frame.maxY - height,
                           width: hardware.width, height: height + 2)
        } else {
            // Room for the hover swell; the visible resting pill remains 72 × 6
            // at the same menu-bar position. Only the central hit rect accepts input.
            frame = NSRect(x: floor(screen.frame.midX - 48), y: screen.frame.maxY - 24,
                           width: 96, height: 24)
        }
        panel = HandlePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("sentient.entry.\(displayID)")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 2
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = HandleView(backdrop: backdrop, isIsland: isIsland, onHover: onHover, onPress: onPress, onActivate: onActivate)
        view.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = view
    }

    func show() {
        if let view = panel.contentView as? HandleView {
            view.setHovered(isIsland && view.hitRect.contains(panel.convertPoint(fromScreen: NSEvent.mouseLocation)), animated: false)
        }
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        NotchSpace.shared?.pin(panel)
    }

    func close() { panel.orderOut(nil); panel.contentView = nil; panel.close() }

    private final class HandlePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private final class HandleView: NSView {
        let onHover: () -> Void
        let onPress: () -> Void
        let onActivate: () -> Void
        private let isIsland: Bool
        private var pillLayer: CALayer?
        private var hovered = false
        var hitRect: NSRect { isIsland ? NSRect(x: 6, y: 3, width: 84, height: 18) : bounds }
        init(backdrop: NSImage?, isIsland: Bool, onHover: @escaping () -> Void, onPress: @escaping () -> Void,
             onActivate: @escaping () -> Void) {
            self.onHover = onHover; self.onPress = onPress; self.onActivate = onActivate
            self.isIsland = isIsland
            super.init(frame: .zero)
            wantsLayer = true
            if isIsland {
                let target = CALayer()
                target.frame = NSRect(x: 6, y: 3, width: 84, height: 18)
                target.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
                layer?.addSublayer(target)
                let host = NSHostingView(rootView: IslandRestingSurface(backdrop: backdrop))
                host.sizingOptions = []
                host.safeAreaRegions = []
                host.frame = NSRect(x: 12, y: 9, width: 72, height: 6)
                host.wantsLayer = true
                addSubview(host)
                pillLayer = host.layer
            } else {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
            }
            toolTip = "Click to open Sidekick · Hold to speak"
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Open Sidekick")
            setAccessibilityHelp("Click to type, or hold to speak.")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: hitRect, options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self, userInfo: nil))
        }
        override func hitTest(_ point: NSPoint) -> NSView? { hitRect.contains(point) ? self : nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) {
            if isIsland { setHovered(true) }
            else { onHover() }
        }
        override func mouseExited(with event: NSEvent) { if isIsland { setHovered(false) } }

        func setHovered(_ value: Bool, animated: Bool = true) {
            guard hovered != value, let pillLayer else { return }
            hovered = value
            let previous = pillLayer.presentation()?.transform ?? pillLayer.transform
            let sx: CGFloat = value ? 84.0 / 72 : 1
            let sy: CGFloat = value ? 1.5 : 1
            // AppKit owns the layer's anchor point. Compensate explicitly so the
            // top-center stays fixed instead of the pill growing sideways/upward.
            var next = CATransform3DMakeScale(sx, sy, 1)
            next.m41 = (1 - sx) * (0.5 - pillLayer.anchorPoint.x) * pillLayer.bounds.width
            next.m42 = (1 - sy) * (1 - pillLayer.anchorPoint.y) * pillLayer.bounds.height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pillLayer.transform = next
            CATransaction.commit()
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = NSValue(caTransform3D: previous)
                animation.toValue = NSValue(caTransform3D: next)
                animation.duration = value ? 0.14 : 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pillLayer.add(animation, forKey: "pill.hover")
            } else { pillLayer.removeAnimation(forKey: "pill.hover") }
        }
        override func mouseDown(with event: NSEvent) { onPress() }
        override func accessibilityPerformPress() -> Bool { onActivate(); return true }
    }

    private static func snapshotWallpaper(on screen: NSScreen) -> NSImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else { return nil }
        // Use an aspect-fill mapping to the display; only the menu-bar center is rasterized.
        let scale = max(screen.frame.width / source.size.width, screen.frame.height / source.size.height)
        let crop = NSRect(x: source.size.width / 2 - 64 / scale,
                          y: source.size.height / 2 + screen.frame.height / (2 * scale) - 32 / scale,
                          width: 128 / scale, height: 32 / scale)
        let sample = NSImage(size: NSSize(width: 128, height: 32))
        sample.lockFocus()
        source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 32), from: crop,
                    operation: .copy, fraction: 1)
        sample.unlockFocus()
        guard let data = sample.tiffRepresentation, let input = CIImage(data: data),
              let output = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(),
                                                                        kCIInputRadiusKey: 8])?.outputImage,
              let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: image, size: sample.size)
    }
}
