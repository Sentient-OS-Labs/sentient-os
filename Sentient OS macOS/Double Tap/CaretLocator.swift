//
//  CaretLocator.swift
//  Sentient OS macOS
//
//  Where the user's text cursor is, in screen points, through Sentient's own Accessibility grant:
//  the frontmost app's focused element → its selected text range (a caret is a zero-length
//  selection) → the screen bounds of that range. Editors that don't answer (a custom-drawn canvas,
//  an Electron build whose accessibility tree hasn't woken) fall down a ladder: the focused field's
//  own frame, then the mouse. So Double Tap's light (CaretSwirl) always has somewhere honest to
//  land. Read once per press, before the screenshot, so it is the caret at the moment of the tap.
//
//  Key methods: locate(). Doc: Documentation - Double Tap.md (this folder).
//

import AppKit
@preconcurrency import ApplicationServices

enum CaretLocator {
    struct Target {
        enum Source: String { case caret, field, mouse }
        /// The centre of the caret, in AppKit screen coordinates (origin at the main display's bottom-left).
        var point: CGPoint
        /// The caret's height (one line), or a default when the rung had no line to measure.
        var height: CGFloat
        var source: Source
    }

    /// AX calls are synchronous IPC into the target app; a hung one must not hold the main thread.
    private static let messagingTimeout: Float = 0.2
    private static let defaultHeight: CGFloat = 18

    @MainActor static func locate() -> Target {
        let mouse = Target(point: NSEvent.mouseLocation, height: defaultHeight, source: .mouse)
        guard Permissions.hasAccessibility(), let app = NSWorkspace.shared.frontmostApplication else { return mouse }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        guard let focused = application.element(kAXFocusedUIElementAttribute) else { return mouse }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        if let caret = caretRect(in: focused), let flipped = onScreen(flip(caret)) {
            return Target(point: CGPoint(x: flipped.midX, y: flipped.midY), height: caret.height, source: .caret)
        }
        // The field itself: its centre is a fair stand-in for a small box, but a whole web area or
        // document view is not (the centre could be nowhere near the text), so tall ones defer to the mouse.
        if let origin = focused.point(kAXPositionAttribute), let size = focused.size(kAXSizeAttribute),
           size.height > 0, size.height <= 500, let flipped = onScreen(flip(CGRect(origin: origin, size: size))) {
            return Target(point: CGPoint(x: flipped.midX, y: flipped.midY), height: defaultHeight, source: .field)
        }
        return mouse
    }

    /// The caret's bounds in AX (top-left origin) coordinates, or nil when the element can't say.
    /// A zero-length range at a line's end sometimes comes back empty, so the neighbouring
    /// character's box stands in: the one before (its trailing edge is the caret) or the one after.
    private static func caretRect(in element: AXUIElement) -> CGRect? {
        guard let selection = element.range(kAXSelectedTextRangeAttribute) else { return nil }
        if let rect = element.bounds(for: CFRange(location: selection.location, length: 0)), rect.height > 0 {
            return rect
        }
        if selection.location > 0,
           let rect = element.bounds(for: CFRange(location: selection.location - 1, length: 1)), rect.height > 0 {
            return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        if let rect = element.bounds(for: CFRange(location: selection.location, length: 1)), rect.height > 0 {
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        return nil
    }

    /// AX frames hang from the main display's top-left; AppKit's origin is its bottom-left.
    private static func flip(_ rect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rect whose centre no display contains is stale or nonsense; the next rung takes over.
    private static func onScreen(_ rect: CGRect) -> CGRect? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.contains { $0.frame.contains(centre) } ? rect : nil
    }
}

// MARK: - The few AX reads this needs, typed

private extension AXUIElement {
    func element(_ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func axValue(_ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = axValue(attribute), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    func size(_ attribute: String) -> CGSize? {
        guard let value = axValue(attribute), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    func range(_ attribute: String) -> CFRange? {
        guard let value = axValue(attribute), AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    /// `kAXBoundsForRangeParameterizedAttribute`: the screen rect of a text range.
    func bounds(for range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let boxed = value as! AXValue
        guard AXValueGetType(boxed) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(boxed, .cgRect, &rect) ? rect : nil
    }
}
