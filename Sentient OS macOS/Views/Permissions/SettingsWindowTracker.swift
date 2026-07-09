//
//  SettingsWindowTracker.swift
//  Sentient OS macOS
//
//  Follows the System Settings window so the floating permission panel (PermissionDragPanel) can
//  fly to it and stay attached while the user drags an app into a privacy list. Two geometry
//  sources: a 30Hz CGWindowList poll (needs ZERO permissions — the bootstrap and the fallback) and
//  AX move/resize observers when Sentient happens to be AX-trusted (it usually isn't; the poll
//  alone is fine). Repeated process misses (12 polls) mean System Settings closed → the panel
//  auto-dismisses via onTrackingEnded.
//
//  Adapted from PermissionFlow by 小弟调调 (github.com/jaywcjlove/PermissionFlow, MIT license) —
//  the window-server frame heuristics and CG→AppKit coordinate flip are hard-won; see upstream
//  comments before "simplifying" anything here.
//

import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

@MainActor
final class SettingsWindowTracker {
    /// Polling stays on even when AX is available: System Settings can appear before AX observers attach.
    private let pollInterval: TimeInterval = 1.0 / 30.0

    /// Lookup misses are common while System Settings opens or swaps panes; requiring several
    /// avoids false "window closed" detection.
    private let missingAppThreshold = 12

    var onFrameChange: ((CGRect) -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var currentFrame: CGRect?

    private let bundleIdentifier = "com.apple.systempreferences"
    private var appObserver: AXObserver?
    private var windowObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var pollTimer: Timer?
    private var hasActiveTrackingTarget = false
    private var missingAppPollCount = 0

    /// Start locating the System Settings window and emitting frame updates.
    func startTracking() {
        stopTracking()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.attachIfNeeded() }
        }
        pollTimer?.tolerance = pollInterval * 0.25
        attachIfNeeded()
    }

    /// Tear down polling and AX observers so the next session starts clean.
    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let observer = windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        appObserver = nil
        windowObserver = nil
        observedWindow = nil
        currentFrame = nil
        hasActiveTrackingTarget = false
        missingAppPollCount = 0
    }

    /// Central loop: resolve the running System Settings app, emit a best-effort window-server
    /// frame immediately, and attach AX observers when available.
    private func attachIfNeeded() {
        guard let app = runningSettingsApplication() else {
            finishTrackingIfNeededBecauseAppExited()
            return
        }

        hasActiveTrackingTarget = true
        missingAppPollCount = 0

        updateFrameFromWindowServer(for: app.processIdentifier)
        guard AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if appObserver == nil {
            appObserver = makeObserver(for: app.processIdentifier)
            if let appObserver {
                addNotification(kAXMainWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                addNotification(kAXFocusedWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
            }
        }

        guard let window = mainWindow(for: appElement) else { return }
        guard isSameElement(window, observedWindow) == false else {
            updateCurrentFrame()
            return
        }

        observedWindow = window
        updateWindowObserver(for: app.processIdentifier, window: window)
        updateCurrentFrame()
    }

    /// Window-server geometry — needs no permission; the initial and fallback source.
    private func updateFrameFromWindowServer(for pid: pid_t) {
        guard let frame = windowServerFrame(for: pid) else { return }
        guard currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    /// Rebind the AX observer to the currently tracked window for move/resize notifications.
    private func updateWindowObserver(for pid: pid_t, window: AXUIElement) {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
        windowObserver = makeObserver(for: pid)
        if let windowObserver {
            addNotification(kAXMovedNotification as CFString, element: window, observer: windowObserver)
            addNotification(kAXResizedNotification as CFString, element: window, observer: windowObserver)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
    }

    /// Publish the AX window's frame, converted to AppKit screen coordinates.
    private func updateCurrentFrame() {
        guard let window = observedWindow else { return }
        guard
            let position = pointValue(for: kAXPositionAttribute, element: window),
            let size = sizeValue(for: kAXSizeAttribute, element: window)
        else { return }

        let frame = appKitFrame(fromGlobalTopLeftFrame: CGRect(origin: position, size: size))
        guard currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    /// Main window preferred, then focused, then the first listed window.
    private func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
        if let window = elementValue(for: kAXMainWindowAttribute, element: appElement) { return window }
        if let window = elementValue(for: kAXFocusedWindowAttribute, element: appElement) { return window }
        return arrayValue(for: kAXWindowsAttribute, element: appElement)?.first
    }

    /// All AX notifications funnel back into attachIfNeeded() on the main actor.
    private func makeObserver(for pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<SettingsWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in tracker.attachIfNeeded() }
        }, &observer)
        guard result == .success else { return nil }
        return observer
    }

    private func addNotification(_ name: CFString, element: AXUIElement, observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, element, name, refcon)
    }

    private func elementValue(for key: String, element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement)
    }

    private func arrayValue(for key: String, element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func pointValue(for key: String, element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success, let axValue = value else { return nil }
        let pointValue = axValue as! AXValue
        guard AXValueGetType(pointValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(pointValue, .cgPoint, &point)
        return point
    }

    private func sizeValue(for key: String, element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success, let axValue = value else { return nil }
        let sizeValue = axValue as! AXValue
        guard AXValueGetType(sizeValue) == .cgSize else { return nil }
        var size = CGSize.zero
        AXValueGetValue(sizeValue, .cgSize, &size)
        return size
    }

    private func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    /// Prefer a UI-capable System Settings process over prohibited activation-policy helpers.
    private func runningSettingsApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) })
    }

    /// Largest visible layer-0 window-server window for the System Settings process. Upstream note:
    /// kCGWindowBounds can read visually taller than the useful content edge (outer framing), which
    /// is why panel attachment is tuned in PermissionDragPanel.targetFrame, not here.
    private func windowServerFrame(for pid: pid_t) -> CGRect? {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        return windows
            .filter { window in
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t else { return false }
                guard ownerPID == pid else { return false }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                return layer == 0 && alpha > 0
            }
            .compactMap { window -> CGRect? in
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
                guard let cgBounds = CGRect(dictionaryRepresentation: bounds) else { return nil }
                let frame = appKitFrame(fromGlobalTopLeftFrame: cgBounds)
                guard frame.width > 320, frame.height > 240 else { return nil }
                return frame
            }
            .max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// Convert a global top-left-origin rect from CG/AX space into AppKit screen coordinates by
    /// matching the rect to its containing screen.
    private func appKitFrame(fromGlobalTopLeftFrame frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, cgBounds: CGRect)? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return (frame: screen.frame, cgBounds: CGDisplayBounds(displayID))
        }

        let matchedScreen = screens
            .filter { $0.cgBounds.intersects(frame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(frame).width * lhs.cgBounds.intersection(frame).height
                    < rhs.cgBounds.intersection(frame).width * rhs.cgBounds.intersection(frame).height
            }

        guard let matchedScreen else { return frame }

        let localX = frame.minX - matchedScreen.cgBounds.minX
        let localY = frame.minY - matchedScreen.cgBounds.minY

        return CGRect(
            x: matchedScreen.frame.minX + localX,
            y: matchedScreen.frame.maxY - localY - frame.height - 3,
            width: frame.width,
            height: frame.height
        )
    }

    /// Only stop after repeated misses, so a short-lived lookup failure never closes the panel.
    private func finishTrackingIfNeededBecauseAppExited() {
        guard hasActiveTrackingTarget || currentFrame != nil else { return }
        missingAppPollCount += 1
        guard missingAppPollCount >= missingAppThreshold else { return }
        stopTracking()
        onTrackingEnded?()
    }
}
