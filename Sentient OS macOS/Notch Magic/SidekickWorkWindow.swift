// Ephemeral identity of the exact native window inspected by the current Sidekick run.
// Never guesses by app name at click time or moves windows between Spaces.
import AppKit
import Darwin
@preconcurrency import ApplicationServices

nonisolated struct SidekickWorkWindow: @unchecked Sendable {
    struct Application: Sendable {
        let pid: pid_t
        let bundleID: String?
        let launched: Date?
    }
    let application: Application
    let element: AXUIElement
    let windowNumber: CGWindowID?

    enum Failure: LocalizedError {
        case unavailable, permission, activation
        var errorDescription: String? {
            switch self {
            case .unavailable: "That work window is no longer available."
            case .permission: "Allow Accessibility to show Sidekick’s work window."
            case .activation: "macOS couldn’t bring that window forward."
            }
        }
    }

    /// Read only the helper's window header, never a matching line inside the app's content.
    static func windowTitle(in result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else { return nil }
        // The first response may prepend a long app-specific instruction block.
        // Locate the actual state wrapper, then read only its header (never app text).
        let headerSearchStart = text.range(of: "</app_specific_instructions>")?.upperBound ?? text.startIndex
        guard let state = text.range(of: "<app_state>", range: headerSearchStart..<text.endIndex) else { return nil }
        let lines = text[state.upperBound...].prefix(4096).split(separator: "\n").prefix(4)
        guard let appLine = lines.firstIndex(where: { $0.hasPrefix("App=") }),
              appLine + 1 < lines.endIndex else { return nil }
        let line = lines[appLine + 1]
        guard line.hasPrefix("Window: \""), let end = line.range(of: "\", App: ", options: .backwards) else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 9)..<end.lowerBound])
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func window(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Called off the main actor. A retained AX reference survives title changes, but not closure.
    static func capture(application: Application, title: String) -> Self? {
        guard application.pid != getpid(), AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func matches(_ candidate: AXUIElement) -> Bool {
            AXUIElementSetMessagingTimeout(candidate, 0.1)
            return attribute(candidate, kAXRoleAttribute) as? String == kAXWindowRole
                && (attribute(candidate, kAXTitleAttribute) as? String ?? "") == title
        }
        // The native helper reads the app's key window, even while that app is in the background.
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let candidate = window(attribute(app, key)), matches(candidate) {
                return Self(application: application, element: candidate, windowNumber: Self.number(of: candidate))
            }
        }
        let candidates = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(64).filter(matches)
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return Self(application: application, element: candidate, windowNumber: Self.number(of: candidate))
    }

    // AX can replace its object when a window is restored. Use WindowServer identity
    // for that repair, never a title guess. If the optional bridge is unavailable,
    // the original AX reference still works, but a replaced reference fails closed.
    private typealias WindowNumberFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowNumberFunction: WindowNumberFunction? = {
        guard let image = dlopen(nil, RTLD_LAZY), let symbol = dlsym(image, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowNumberFunction.self)
    }()
    static func number(of element: AXUIElement) -> CGWindowID? {
        guard let function = windowNumberFunction else { return nil }
        var number: CGWindowID = 0
        return function(element, &number) == .success && number != 0 ? number : nil
    }

    func resolvedElement() throws -> AXUIElement {
        if Self.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole,
           windowNumber == nil || Self.number(of: element) == windowNumber { return element }
        guard let windowNumber else { throw Failure.unavailable }
        let app = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        for candidate in (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(64) {
            AXUIElementSetMessagingTimeout(candidate, 0.1)
            if Self.number(of: candidate) == windowNumber { return candidate }
        }
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowNumber) as? [[String: Any]] ?? []
        if windows.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowNumber
            && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.pid }) {
            throw RaiseFailure.transitioning
        }
        throw Failure.unavailable
    }

    private enum RaiseFailure: Error { case transitioning }

    private func raise() throws {
        guard AXIsProcessTrusted() else { throw Failure.permission }
        let element = try resolvedElement()
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == application.pid,
              Self.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole else { throw Failure.unavailable }
        if Self.attribute(element, kAXMinimizedAttribute) as? Bool == true {
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let status = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if status == .cannotComplete { throw RaiseFailure.transitioning }
        guard status == .success else { throw Failure.unavailable }
    }

    private func raiseWhenReady() async throws {
        for attempt in 0..<10 {
            try Task.checkCancellation()
            do {
                try await Task.detached(priority: .userInitiated) { try self.raise() }.value
                return
            } catch RaiseFailure.transitioning {
                guard attempt < 9 else { throw Failure.activation }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @MainActor func reveal() async throws {
        guard let app = NSRunningApplication(processIdentifier: application.pid), !app.isTerminated,
              app.bundleIdentifier == application.bundleID, app.launchDate == application.launched else { throw Failure.unavailable }
        // Establish the intended main window before activation so macOS can choose its Space.
        try await raiseWhenReady()
        if app.isHidden { app.unhide() }
        NSApp.yieldActivation(to: app)
        guard app.activate(options: []) else { throw Failure.activation }
        // Activation can reorder sibling windows. Reassert the exact retained window once.
        try await Task.sleep(for: .milliseconds(120))
        try Task.checkCancellation()
        guard !app.isTerminated, app.launchDate == application.launched else { throw Failure.unavailable }
        // Do not compete with a user who switched elsewhere after our activation.
        // Global input counters also include Sidekick's clicks, so cannot distinguish
        // user cancellation from the task we are deliberately bringing into view.
        guard app.isActive else { throw CancellationError() }
        try await raiseWhenReady()
    }
}
