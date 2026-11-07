// Captures an exact AX selection before the notch takes focus. Replacement uses ordinary paste,
// checks the field/range/document and input activity again, then verifies the resulting value.
// AX IPC is bounded and off-main; clipboard data is local, temporary and restored only if owned.
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
        let canReplace: Bool
        init(pid: pid_t, element: AXUIElement, window: AXUIElement?, range: CFRange?, text: String, originalValue: String?, canReplace: Bool) {
            self.pid = pid; self.element = element; self.window = window; self.range = range
            self.text = text; self.originalValue = originalValue; self.canReplace = canReplace
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
            case .clipboard: "The correction is ready to copy. Sentient couldn’t safely preserve your clipboard."
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
        let selectedValue = boundedFull.flatMap { text in range.flatMap { substring(text, range: $0) } }
        let exact = selectedValue.map { sameText($0, selected) } ?? false
        var settable = DarwinBoolean(false)
        let editable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        let uniform = range.map { uniformFormatting(element, range: $0, plainField: role == kAXTextFieldRole) } ?? false
        return Snapshot(pid: pid, element: element, window: self.element(element, kAXWindowAttribute), range: range,
                        text: selected, originalValue: boundedFull, canReplace: exact && editable && uniform)
    }

    static func validate(_ snapshot: Snapshot) -> Bool {
        let app = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        guard let focused = element(app, kAXFocusedUIElementAttribute), CFEqual(focused, snapshot.element),
              let original = snapshot.originalValue, let actual = value(snapshot.element, kAXValueAttribute) as? String,
              sameText(actual, original),
              let current = range(snapshot.element), let saved = snapshot.range,
              current.location == saved.location, current.length == saved.length else { return false }
        let role = value(snapshot.element, kAXRoleAttribute) as? String ?? ""
        guard value(snapshot.element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              uniformFormatting(snapshot.element, range: saved, plainField: role == kAXTextFieldRole) else { return false }
        if let window = snapshot.window {
            guard let current = element(snapshot.element, kAXWindowAttribute), CFEqual(current, window) else { return false }
        }
        return true
    }

    @MainActor static func apply(_ corrected: String, to snapshot: Snapshot, activity: ShortcutActivity) async -> Outcome {
        guard snapshot.canReplace, let original = snapshot.originalValue, let range = snapshot.range else { return .unsupported }
        guard !Task.isCancelled, activity == ShortcutActivity.current,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return .changed }
        let valid = await Task.detached { validate(snapshot) }.value
        guard valid, !Task.isCancelled, activity == ShortcutActivity.current,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return .changed }
        guard let clipboard = ProofreadClipboard.capture() else { return .clipboardUnavailable }
        let pasteboard = NSPasteboard.general
        let before = clipboard.version
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              before == pasteboard.changeCount, activity == ShortcutActivity.current, !Task.isCancelled else { return .changed }
        pasteboard.clearContents()
        guard pasteboard.setString(corrected, forType: .string) else { clipboard.restore(ifOwned: pasteboard.changeCount); return .clipboardUnavailable }
        let owned = pasteboard.changeCount
        defer { clipboard.restore(ifOwned: owned) }
        let expected = (original as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: corrected)
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(snapshot.pid); up.postToPid(snapshot.pid)
        // Posting is not proof of insertion. A timeout is uncertain, never a reason to paste twice.
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            let actual = await Task.detached { value(snapshot.element, kAXValueAttribute) as? String }.value
            if let actual, sameText(actual, expected) { return .applied }
        }
        return .uncertain
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
    private static func uniformFormatting(_ element: AXUIElement, range: CFRange, plainField: Bool) -> Bool {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return false }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success, let attributed = result as? NSAttributedString else { return plainField }
        let styleKeys: Set<String> = ["AXFont", "AXForegroundColor", "AXBackgroundColor", "AXUnderline", "AXStrikethrough", "NSFont", "NSColor", "NSBackgroundColor", "NSUnderline", "NSStrikethrough"]
        var first: NSDictionary?, uniform = true
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, _, _ in
            if attributes.keys.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("link") || $0.rawValue.localizedCaseInsensitiveContains("attachment") }) { uniform = false }
            let style = attributes.filter { styleKeys.contains($0.key.rawValue) } as NSDictionary
            if let first, !first.isEqual(style) { uniform = false }
            else if first == nil { first = style }
        }
        return uniform
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
