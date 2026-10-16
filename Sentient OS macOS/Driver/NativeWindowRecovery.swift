// Restores only the uniquely resolved app whose native state read failed, without sending input.
// LaunchServices reopens its window; existing Accessibility consent can restore a minimized window.
// Doc: Documentation - Native Computer Use.md

import AppKit
import ApplicationServices
import Synchronization

@MainActor enum NativeWindowRecovery {
    static func resolve(_ selector: String) -> NSRunningApplication? {
        let matches = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.bundleIdentifier == selector || $0.bundleURL?.path == selector
                || $0.localizedName?.caseInsensitiveCompare(selector) == .orderedSame)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func restore(_ app: NSRunningApplication) async throws -> [String: String] {
        try Task.checkCancellation()
        guard !app.isTerminated, let url = app.bundleURL else {
            throw NativeComputerUseFailure(kind: .noWindows, code: nil, detail: .targetUnavailable, stage: .recovery)
        }
        let originalPID = app.processIdentifier
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        options.hides = false
        options.addsToRecentItems = false
        options.promptsUserIfNeeded = false
        options.allowsRunningApplicationSubstitution = false
        // The callback can stall in LaunchServices. Bound the waiter, and never repeat the open.
        let returned: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            let waiter = Mutex<CheckedContinuation<NSRunningApplication, Error>?>(continuation)
            NSWorkspace.shared.openApplication(at: url, configuration: options) { value, error in
                let once = waiter.withLock { value in let result = value; value = nil; return result }
                if let value { once?.resume(returning: value) }
                else {
                    var failure = NativeComputerUseFailure(kind: .noWindows, code: nil, detail: .launchFailed, stage: .recovery)
                    if let error { failure.recordSystemError(error) }
                    once?.resume(throwing: failure)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                let once = waiter.withLock { value in let result = value; value = nil; return result }
                once?.resume(throwing: NativeComputerUseFailure(kind: .timeout, code: nil, detail: .recoveryTimedOut, stage: .recovery))
            }
        }
        try Task.checkCancellation()
        guard returned.processIdentifier == originalPID, !app.isTerminated else {
            throw NativeComputerUseFailure(kind: .noWindows, code: nil, detail: .targetUnavailable, stage: .recovery)
        }
        app.unhide()
        var fields = ["recovery_open_dispatched": "true", "recovery_ax_available": String(AXIsProcessTrusted())]
        // Native helper grants do not grant Sentient AX access. Never prompt or change TCC here.
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(originalPID)
            AXUIElementSetMessagingTimeout(element, 0.3)
            var main: CFTypeRef?
            let lookup = AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &main)
            fields["recovery_ax_lookup_code"] = String(lookup.rawValue)
            if lookup == .success, let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(main, to: AXUIElement.self)
                let restored = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                fields["recovery_ax_restore_code"] = String(restored.rawValue)
            }
        }
        fields["recovery_activated"] = String(app.activate())
        try await Task.sleep(for: .milliseconds(200))
        return fields
    }
}
