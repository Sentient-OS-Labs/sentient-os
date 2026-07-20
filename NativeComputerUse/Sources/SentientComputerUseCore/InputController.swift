import ApplicationServices
import CoreGraphics
import Foundation

protocol InputControlling {
    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws
    func typeText(_ text: String) throws
    func pressKey(_ key: String) throws
    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws
}

protocol EventPosting {
    func post(_ event: CGEvent)
}

protocol AccessibilityActionPerforming {
    func supports(_ action: String, on element: SnapshotElementReference) throws -> Bool
    func perform(_ action: String, on element: SnapshotElementReference) throws
}

protocol DisplayBoundsProviding {
    var displayBounds: [CGRect] { get }
}

enum MouseButton: Sendable {
    case left
    case right
    case middle
}

enum ScrollDirection: Sendable {
    case up
    case down
    case left
    case right
}

enum InputRequestValidator {
    static func clickCount(_ count: Int) throws {
        guard (1...3).contains(count) else {
            throw ServiceError(code: .invalidRequest, message: "Click count must be between 1 and 3")
        }
    }

    static func scrollPages(_ pages: Int) throws {
        guard (1...10).contains(pages) else {
            throw ServiceError(code: .invalidRequest, message: "Scroll pages must be between 1 and 10")
        }
    }

    static func key(_ rawKey: String) throws -> (modifiers: [Modifier], keyCode: CGKeyCode) {
        let parts = rawKey.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty }) else { throw unsupportedKey(rawKey) }
        let modifierParts = parts.dropLast()
        guard let keyCode = keyCode(for: parts.last!) else { throw unsupportedKey(rawKey) }

        var modifiers: [Modifier] = []
        for part in modifierParts {
            guard let modifier = Modifier(name: part), !modifiers.contains(modifier) else { throw unsupportedKey(rawKey) }
            modifiers.append(modifier)
        }
        return (modifiers, keyCode)
    }

    static func mouseButton(_ value: String?) throws -> MouseButton {
        switch value {
        case nil, "left": return .left
        case "right": return .right
        case "middle": return .middle
        default: throw ServiceError(code: .invalidRequest, message: "Invalid mouse button")
        }
    }

    static func scrollDirection(_ value: String?) throws -> ScrollDirection {
        switch value {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        default: throw ServiceError(code: .invalidRequest, message: "Invalid scroll direction")
        }
    }

    static func isFinite(_ coordinate: CGPoint) -> Bool {
        coordinate.x.isFinite && coordinate.y.isFinite
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        let namedKeys: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
            "arrowup": 126, "up": 126, "arrowdown": 125, "down": 125,
            "arrowleft": 123, "left": 123, "arrowright": 124, "right": 124,
            "space": 49, "delete": 51, "backspace": 51
        ]
        if let keyCode = namedKeys[normalized] { return keyCode }

        let printable: [String: CGKeyCode] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
            "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
            "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25
        ]
        return printable[normalized]
    }

    private static func unsupportedKey(_ key: String) -> ServiceError {
        ServiceError(code: .unsupportedAction, message: "Unsupported key: \(key)")
    }
}

final class InputController: InputControlling {
    static let scrollLinesPerPage: Int32 = 10

    private let events: any EventPosting
    private let actions: any AccessibilityActionPerforming
    private let screens: any DisplayBoundsProviding

    init(
        events: any EventPosting,
        actions: any AccessibilityActionPerforming,
        screens: any DisplayBoundsProviding = CoreGraphicsDisplayBoundsProvider()
    ) {
        self.events = events
        self.actions = actions
        self.screens = screens
    }

    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws {
        try InputRequestValidator.clickCount(count)
        guard element != nil || coordinate != nil else {
            throw ServiceError(code: .invalidRequest, message: "Click requires an element or coordinate")
        }

        if let element, try actions.supports(kAXPressAction, on: element) {
            try actions.perform(kAXPressAction, on: element)
            return
        }

        guard let coordinate else {
            throw ServiceError(code: .unsupportedAction, message: "Element does not support AXPress")
        }
        try validateOnScreen(coordinate)

        let mouse = mouseDetails(for: button)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: mouse.down,
            mouseCursorPosition: coordinate,
            mouseButton: mouse.button
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: mouse.up,
            mouseCursorPosition: coordinate,
            mouseButton: mouse.button
        ) else {
            throw ServiceError(code: .internalError, message: "Unable to create click event")
        }
        down.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        events.post(down)
        events.post(up)
    }

    func typeText(_ text: String) throws {
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return }

        try postUnicodeText(characters, keyDown: true)
        try postUnicodeText(characters, keyDown: false)
    }

    func pressKey(_ key: String) throws {
        let parsed = try InputRequestValidator.key(key)

        var heldFlags: CGEventFlags = []
        for modifier in parsed.modifiers {
            heldFlags.insert(modifier.flag)
            try postKey(code: modifier.keyCode, keyDown: true, flags: heldFlags)
        }
        try postKey(code: parsed.keyCode, keyDown: true, flags: heldFlags)
        try postKey(code: parsed.keyCode, keyDown: false, flags: heldFlags)
        for modifier in parsed.modifiers.reversed() {
            heldFlags.remove(modifier.flag)
            try postKey(code: modifier.keyCode, keyDown: false, flags: heldFlags)
        }
    }

    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws {
        try InputRequestValidator.scrollPages(pages)
        if let anchor {
            try validateOnScreen(anchor)
        }

        let amount = Int32(pages) * Self.scrollLinesPerPage
        let axes: (vertical: Int32, horizontal: Int32)
        switch direction {
        case .up: axes = (amount, 0)
        case .down: axes = (-amount, 0)
        case .left: axes = (0, -amount)
        case .right: axes = (0, amount)
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: axes.vertical,
            wheel2: axes.horizontal,
            wheel3: 0
        ) else {
            throw ServiceError(code: .internalError, message: "Unable to create scroll event")
        }
        if let anchor {
            event.location = anchor
        }
        events.post(event)
    }

    private func validateOnScreen(_ coordinate: CGPoint) throws {
        guard InputRequestValidator.isFinite(coordinate),
              screens.displayBounds.contains(where: { $0.contains(coordinate) }) else {
            throw ServiceError(code: .invalidRequest, message: "Coordinate must be finite and on screen")
        }
    }

    private func postUnicodeText(_ characters: [UniChar], keyDown: Bool) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
            throw ServiceError(code: .internalError, message: "Unable to create keyboard event")
        }
        characters.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
        }
        events.post(event)
    }

    private func postKey(code: CGKeyCode, keyDown: Bool, flags: CGEventFlags) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: keyDown) else {
            throw ServiceError(code: .internalError, message: "Unable to create keyboard event")
        }
        event.flags = flags
        events.post(event)
    }

    private func mouseDetails(for button: MouseButton) -> (down: CGEventType, up: CGEventType, button: CGMouseButton) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
    }

}

struct Modifier: Equatable {
    let keyCode: CGKeyCode
    let flag: CGEventFlags

    private init(keyCode: CGKeyCode, flag: CGEventFlags) {
        self.keyCode = keyCode
        self.flag = flag
    }

    init?(name: String) {
        switch name.lowercased() {
        case "super", "command", "cmd": self = Self(keyCode: 55, flag: .maskCommand)
        case "shift": self = Self(keyCode: 56, flag: .maskShift)
        case "option", "alt": self = Self(keyCode: 58, flag: .maskAlternate)
        case "control", "ctrl": self = Self(keyCode: 59, flag: .maskControl)
        default: return nil
        }
    }
}

private extension Array where Element == Modifier {
    var flags: CGEventFlags {
        reduce([]) { $0.union($1.flag) }
    }
}

private struct CoreGraphicsDisplayBoundsProvider: DisplayBoundsProviding {
    var displayBounds: [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        var activeCount = count
        let result = displayIDs.withUnsafeMutableBufferPointer {
            CGGetActiveDisplayList(count, $0.baseAddress, &activeCount)
        }
        guard result == .success else { return [] }
        return displayIDs.prefix(Int(activeCount)).map(CGDisplayBounds)
    }
}

struct SystemEventPoster: EventPosting {
    func post(_ event: CGEvent) {
        event.post(tap: .cgAnnotatedSessionEventTap)
    }
}

final class SystemAccessibilityActionPerformer: AccessibilityActionPerforming {
    private let resolve: (SnapshotElementReference) throws -> AXUIElement

    init(resolve: @escaping (SnapshotElementReference) throws -> AXUIElement) {
        self.resolve = resolve
    }

    func supports(_ action: String, on element: SnapshotElementReference) throws -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(try resolve(element), &actions) == .success else { return false }
        return (actions as? [String])?.contains(action) == true
    }

    func perform(_ action: String, on element: SnapshotElementReference) throws {
        let result = AXUIElementPerformAction(try resolve(element), action as CFString)
        guard result == .success else {
            throw ServiceError(code: .unsupportedAction, message: "Unable to perform \(action)")
        }
    }
}
