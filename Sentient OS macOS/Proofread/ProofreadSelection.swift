// Normal Copy/Paste transport. AX only bookmarks the source editor and optional selection range.
// Clipboard formats are restored after each operation; a newer clipboard write wins.
// Doc: Documentation - Proofread.md
import AppKit
@preconcurrency import ApplicationServices

nonisolated enum ProofreadSelection {
    final class Snapshot: @unchecked Sendable {
        let pid: pid_t
        let element: AXUIElement
        let window: AXUIElement?
        let range: CFRange?
        let text: String
        let originalValue: String?
        let verificationText: String?
        let verificationRange: CFRange?
        let canReplace: Bool
        let requiresCopy: Bool
        var captureActivity: ShortcutActivity?
        init(pid: pid_t, element: AXUIElement, window: AXUIElement?, range: CFRange?, text: String, originalValue: String?, canReplace: Bool,
             verificationText: String? = nil, verificationRange: CFRange? = nil, requiresCopy: Bool = false) {
            self.pid = pid; self.element = element; self.window = window; self.range = range
            self.requiresCopy = requiresCopy
            self.text = text; self.originalValue = originalValue; self.canReplace = canReplace
            self.verificationText = originalValue ?? verificationText
            self.verificationRange = originalValue.map { CFRange(location: 0, length: $0.utf16.count) } ?? verificationRange
        }
    }
    enum Failure: LocalizedError {
        case permission, noSelection, unsupported, tooLarge, clipboard
        var errorDescription: String? {
            switch self {
            case .permission: "Allow Accessibility in System Settings to proofread selected text."
            case .noSelection: "Select some text to proofread."
            case .unsupported: "Sentient couldn’t read this selection. Try selecting it in an editable text field."
            case .tooLarge: "Select a shorter passage to proofread."
            case .clipboard: "Couldn’t preserve the clipboard. Try again."
            }
        }
    }
    enum Outcome: Equatable { case applied, changed, unsupported, clipboardUnavailable, uncertain }

    static func capture(pid: pid_t) throws -> Snapshot {
        do { return try captureOnce(pid: pid) }
        catch Failure.noSelection {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.04)
            // Browser engines can publish their focused DOM field only after an assistive
            // client asks for the native hierarchy. A real empty range needs no retry.
            if let focused = element(app, kAXFocusedUIElementAttribute) {
                AXUIElementSetMessagingTimeout(focused, 0.04)
                if let selected = range(focused), selected.length == 0 { throw Failure.noSelection }
            }
            warmHierarchy(app)
            Thread.sleep(forTimeInterval: 0.05) // This entire method runs off the main actor.
            return try captureOnce(pid: pid)
        }
    }

    private static func warmHierarchy(_ app: AXUIElement) {
        let began = ContinuousClock.now
        var pending = (value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(2).map { $0 }
        var index = 0
        while index < pending.count, index < 32, began.duration(to: .now) < .milliseconds(200) {
            let node = pending[index]; index += 1
            AXUIElementSetMessagingTimeout(node, 0.02)
            _ = value(node, kAXRoleAttribute)
            for attribute in [kAXChildrenAttribute, kAXContentsAttribute] {
                if let children = value(node, attribute) as? [AXUIElement] {
                    for child in children.prefix(32) where pending.count < 32 {
                        if !pending.contains(where: { CFEqual($0, child) }) { pending.append(child) }
                    }
                }
            }
        }
    }

    private static func captureOnce(pid: pid_t) throws -> Snapshot {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let element = element(app, kAXFocusedUIElementAttribute) else { throw Failure.noSelection }
        AXUIElementSetMessagingTimeout(element, 0.08)
        let role = value(element, kAXRoleAttribute) as? String ?? ""
        let subrole = value(element, kAXSubroleAttribute) as? String ?? ""
        guard subrole != kAXSecureTextFieldSubrole, value(element, "AXProtectedContent") as? Bool != true else { throw Failure.unsupported }
        let range = range(element)
        let count = value(element, kAXNumberOfCharactersAttribute) as? Int
        // Reading a bounded field locally lets us prove text outside the selection was preserved.
        let full: String? = if (count.map { $0 <= 64_000 } ?? (role == kAXTextFieldRole)) { value(element, kAXValueAttribute) as? String } else { nil }
        let boundedFull = full.flatMap { $0.utf16.count <= 64_000 ? $0 : nil }
        let selected = (value(element, kAXSelectedTextAttribute) as? String)
            ?? boundedFull.flatMap { text in range.flatMap { substring(text, range: $0) } }
        guard let selected else { throw (range?.length ?? 0) > 0 ? Failure.unsupported : Failure.noSelection }
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noSelection }
        guard selected.utf8.count <= 12_000 else { throw Failure.tooLarge }
        var verificationText = boundedFull
        var verificationRange = boundedFull.map { CFRange(location: 0, length: $0.utf16.count) }
        if verificationText == nil, let range, range.location >= 0, range.location < Int.max - 64_000,
           range.length > 0, range.length == selected.utf16.count {
            // Some editors omit their full value or expose very large documents. Read
            // only the selected range and a small boundary on either side in that case.
            let start = max(0, range.location - 64)
            let end = min(count ?? (range.location + range.length), range.location + range.length + 64)
            let context = CFRange(location: start, length: max(0, end - start))
            if let text = string(element, in: context) {
                verificationText = text; verificationRange = context
            } else if let text = string(element, in: range) {
                verificationText = text; verificationRange = range
            }
        }
        let selectedValue = verificationText.flatMap { text in
            range.flatMap { selected in verificationRange.flatMap { context in
                substring(text, range: CFRange(location: selected.location - context.location, length: selected.length))
            } }
        }
        let exact = selectedValue.map { sameText($0, selected) } ?? false
        let editable = supportsEditing(element)
        return Snapshot(pid: pid, element: element, window: self.element(element, kAXWindowAttribute), range: range,
                        text: selected, originalValue: boundedFull, canReplace: exact && editable,
                        verificationText: verificationText, verificationRange: verificationRange)
    }

    static func validate(_ snapshot: Snapshot) -> Bool {
        let app = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let focused = element(app, kAXFocusedUIElementAttribute), CFEqual(focused, snapshot.element),
              let original = snapshot.verificationText, let actual = verificationValue(snapshot),
              sameText(actual, original),
              let current = range(snapshot.element), let saved = snapshot.range,
              current.location == saved.location, current.length == saved.length else { return false }
        guard value(snapshot.element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              value(snapshot.element, "AXProtectedContent") as? Bool != true else { return false }
        guard supportsEditing(snapshot.element) else { return false }
        if let window = snapshot.window {
            guard let current = element(snapshot.element, kAXWindowAttribute), CFEqual(current, window) else { return false }
        }
        return true
    }

    /// Passive preparation never posts keys or touches the clipboard. Keep an editor
    /// bookmark so explicit Proofread can restore focus and use normal Copy afterwards.
    static func bookmark(pid: pid_t) throws -> Snapshot {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let field = element(app, kAXFocusedUIElementAttribute) else { throw Failure.noSelection }
        AXUIElementSetMessagingTimeout(field, 0.08)
        guard value(field, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              value(field, "AXProtectedContent") as? Bool != true else { throw Failure.unsupported }
        return Snapshot(pid: pid, element: field, window: element(field, kAXWindowAttribute),
            range: range(field), text: "", originalValue: nil, canReplace: true, requiresCopy: true)
    }

    /// Copy remains the source of truth, but only after an explicit Proofread action.
    @MainActor static func captureByCopy(pid: pid_t) async throws -> Snapshot {
        let anchor = try await Task.detached { try bookmark(pid: pid) }.value
        let text = try await copySelection(pid: pid)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noSelection }
        guard text.utf8.count <= 12_000 else { throw Failure.tooLarge }
        let result = Snapshot(pid: pid, element: anchor.element, window: anchor.window,
            range: anchor.range, text: text, originalValue: nil, canReplace: true)
        result.captureActivity = .current
        return result
    }

    /// Restore only the original editor. Do not require AXValue/AXSelectedTextRange support:
    /// Electron and browser chrome often omit them even though normal Copy/Paste works.
    @MainActor static func restoreFocus(_ snapshot: Snapshot, activity: ShortcutActivity) async -> Bool {
        guard !Task.isCancelled, activity == ShortcutActivity.current,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return false }
        await Task.detached {
            _ = AXUIElementSetAttributeValue(snapshot.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if var saved = snapshot.range, let boxed = AXValueCreate(.cfRange, &saved) {
                _ = AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, boxed)
            }
        }.value
        try? await Task.sleep(for: .milliseconds(60))
        return !Task.isCancelled && activity == ShortcutActivity.current
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid
    }

    @MainActor static func copySelection(pid: pid_t) async throws -> String {
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure.noSelection }
        guard let saved = ProofreadClipboard.capture() else { throw Failure.clipboard }
        let board = NSPasteboard.general
        // Empty the temporary board so a no-op Copy can never read stale user clipboard text.
        board.clearContents()
        var owned = board.changeCount
        defer { saved.restore(ifOwned: owned) }
        guard postCommand(8) else { throw Failure.unsupported } // Command-C
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if board.changeCount != owned {
                owned = board.changeCount
                guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let text = board.string(forType: .string) else { throw Failure.noSelection }
                return text
            }
            if Task.isCancelled { break }
        }
        throw Failure.noSelection
    }

    @MainActor static func apply(_ corrected: String, to snapshot: Snapshot, activity: ShortcutActivity) async -> Outcome {
        guard snapshot.canReplace else { return .unsupported }
        guard !Task.isCancelled, activity == ShortcutActivity.current,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return .changed }
        // Re-copy immediately before Paste. Matching the actual selection is sufficient;
        // unrelated AX values, text markers, and editor implementation details are not gates.
        let selected: String
        do { selected = try await copySelection(pid: snapshot.pid) }
        catch Failure.clipboard { return .clipboardUnavailable }
        catch { return .changed }
        guard sameText(selected, snapshot.text), !Task.isCancelled else { return .changed }
        guard let saved = ProofreadClipboard.capture() else { return .clipboardUnavailable }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(corrected, forType: .string) else {
            saved.restore(ifOwned: board.changeCount); return .clipboardUnavailable
        }
        let owned = board.changeCount
        guard postCommand(9) else { saved.restore(ifOwned: owned); return .unsupported } // Command-V
        // Do not let task cancellation restore the clipboard before the editor reads it.
        await Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            saved.restore(ifOwned: owned)
        }.value
        return .applied
    }

    @MainActor private static func postCommand(_ key: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }

    /// AX ranges use UTF-16 positions. Canonically equivalent Unicode can still have different
    /// offsets, so Swift's normal String equality is too permissive for validating this target.
    static func sameText(_ first: String, _ second: String) -> Bool { first.utf16.elementsEqual(second.utf16) }

    static func substring(_ text: String, range: CFRange) -> String? {
        let value = text as NSString
        guard range.location >= 0, range.length > 0, range.location <= value.length,
              range.length <= value.length - range.location else { return nil }
        return value.substring(with: NSRange(location: range.location, length: range.length))
    }
    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private static func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(owner, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private static func range(_ element: AXUIElement) -> CFRange? {
        guard let result = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        let boxed = result as! AXValue
        var range = CFRange()
        guard AXValueGetType(boxed) == .cfRange, AXValueGetValue(boxed, .cfRange, &range) else { return nil }
        return range
    }
    private static func supportsEditing(_ element: AXUIElement) -> Bool {
        guard value(element, kAXEnabledAttribute) as? Bool != false else { return false }
        return [kAXValueAttribute, kAXSelectedTextAttribute].contains { name in
            var writable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success && writable.boolValue
        }
    }
    private static func string(_ element: AXUIElement, in requested: CFRange) -> String? {
        var range = requested
        guard range.location >= 0, range.length > 0, range.length <= 64_000,
              let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success, let text = result as? String, text.utf16.count == range.length else { return nil }
        return text
    }
    private static func verificationValue(_ snapshot: Snapshot, replacementLength: Int? = nil) -> String? {
        if snapshot.originalValue != nil { return value(snapshot.element, kAXValueAttribute) as? String }
        guard var range = snapshot.verificationRange else { return nil }
        if let replacementLength, let selection = snapshot.range { range.length += replacementLength - selection.length }
        return string(snapshot.element, in: range)
    }
}

/// Snapshot all materialized clipboard types. Never replace a clipboard the user changed meanwhile.
@MainActor struct ProofreadClipboard {
    let board: NSPasteboard
    let version: Int
    let items: [[NSPasteboard.PasteboardType: Data]]
    static func capture(from board: NSPasteboard = .general) -> Self? {
        let version = board.changeCount
        let existing = board.pasteboardItems ?? []
        guard existing.count <= 16 else { return nil }
        var items: [[NSPasteboard.PasteboardType: Data]] = [], size = 0
        for item in existing {
            guard item.types.count <= 32 else { return nil }
            var formats: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                size += data.count; guard size <= 4_000_000 else { return nil }
                formats[type] = data
            }
            items.append(formats)
        }
        return board.changeCount == version ? Self(board: board, version: version, items: items) : nil
    }
    func restore(ifOwned count: Int) {
        guard board.changeCount == count else { return }
        let objects = items.map { formats in
            let item = NSPasteboardItem(); for (type, data) in formats { item.setData(data, forType: type) }; return item
        }
        board.clearContents()
        if !objects.isEmpty { board.writeObjects(objects) }
    }
}
