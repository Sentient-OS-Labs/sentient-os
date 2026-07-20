import ApplicationServices
import CoreGraphics
import XCTest
@testable import SentientComputerUseCore

final class InputControllerTests: XCTestCase {
    func testSemanticPressWinsOverCoordinateFallback() throws {
        let events = RecordingEventPoster()
        let actions = RecordingAXActionPerformer(supported: [kAXPressAction])
        let controller = InputController(events: events, actions: actions, screens: FixtureScreenProvider())

        try controller.click(element: .fixture, coordinate: CGPoint(x: 20, y: 30), button: .left, count: 1)

        XCTAssertEqual(actions.performed, [kAXPressAction])
        XCTAssertTrue(events.events.isEmpty)
    }

    func testClickRequiresAnElementOrCoordinate() {
        let controller = InputController(events: RecordingEventPoster(), actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        XCTAssertThrowsError(try controller.click(element: nil, coordinate: nil, button: .left, count: 1)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .invalidRequest, message: "Click requires an element or coordinate"))
        }
    }

    func testClickRejectsOutOfRangeCount() {
        let controller = InputController(events: RecordingEventPoster(), actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        XCTAssertThrowsError(try controller.click(element: nil, coordinate: CGPoint(x: 20, y: 30), button: .left, count: 4)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .invalidRequest, message: "Click count must be between 1 and 3"))
        }
    }

    func testClickRejectsCoordinateThatIsNotFiniteAndOnScreen() {
        let controller = InputController(events: RecordingEventPoster(), actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        XCTAssertThrowsError(try controller.click(element: nil, coordinate: CGPoint(x: CGFloat.infinity, y: 30), button: .left, count: 1)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .invalidRequest, message: "Coordinate must be finite and on screen"))
        }
    }

    func testCoordinateClicksMapButtonsAndClickCounts() throws {
        let events = RecordingEventPoster()
        let controller = InputController(events: events, actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        try controller.click(element: nil, coordinate: CGPoint(x: 20, y: 30), button: .left, count: 1)
        try controller.click(element: nil, coordinate: CGPoint(x: 20, y: 30), button: .right, count: 2)
        try controller.click(element: nil, coordinate: CGPoint(x: 20, y: 30), button: .middle, count: 3)

        XCTAssertEqual(events.events.map(\.type), [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp])
        XCTAssertEqual(events.events.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2, 3, 3])
        XCTAssertEqual(events.events[4].getIntegerValueField(.mouseEventButtonNumber), 2)
    }

    func testTypeTextPostsUnicodeKeyDownAndUp() throws {
        let events = RecordingEventPoster()
        let controller = InputController(events: events, actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        try controller.typeText("Allô 👋")

        XCTAssertEqual(events.events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.events.map(unicodeText), ["Allô 👋", "Allô 👋"])
    }

    func testPressKeyParsesSuperChordInModifierKeyDownUpOrder() throws {
        let events = RecordingEventPoster()
        let controller = InputController(events: events, actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        try controller.pressKey("super+c")

        XCTAssertEqual(events.events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(events.events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [55, 8, 8, 55])
    }

    func testPressKeySupportsNamedKeys() throws {
        let expected: [(String, Int64)] = [("Return", 36), ("Tab", 48), ("Escape", 53), ("ArrowUp", 126), ("ArrowDown", 125), ("ArrowLeft", 123), ("ArrowRight", 124)]

        for (key, keyCode) in expected {
            let events = RecordingEventPoster()
            let controller = InputController(events: events, actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

            try controller.pressKey(key)

            XCTAssertEqual(events.events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [keyCode, keyCode], key)
        }
    }

    func testPressKeyRejectsUnknownSyntax() {
        let controller = InputController(events: RecordingEventPoster(), actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        XCTAssertThrowsError(try controller.pressKey("super+not-a-key")) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .unsupportedAction, message: "Unsupported key: super+not-a-key"))
        }
    }

    func testScrollScalesPagesByDirectionAtAnchor() throws {
        let events = RecordingEventPoster()
        let controller = InputController(events: events, actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        try controller.scroll(direction: .up, pages: 2, anchor: CGPoint(x: 20, y: 30))
        try controller.scroll(direction: .left, pages: 3, anchor: CGPoint(x: 20, y: 30))

        XCTAssertEqual(events.events.map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis1) }, [20, 0])
        XCTAssertEqual(events.events.map { $0.getIntegerValueField(.scrollWheelEventDeltaAxis2) }, [0, -30])
        XCTAssertEqual(events.events.map(\.location), [CGPoint(x: 20, y: 30), CGPoint(x: 20, y: 30)])
    }

    func testScrollRejectsPageCountOutsideAllowedRange() {
        let controller = InputController(events: RecordingEventPoster(), actions: RecordingAXActionPerformer(), screens: FixtureScreenProvider())

        XCTAssertThrowsError(try controller.scroll(direction: .down, pages: 0, anchor: nil)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .invalidRequest, message: "Scroll pages must be between 1 and 10"))
        }
    }
}

private final class RecordingEventPoster: EventPosting {
    private(set) var events: [CGEvent] = []

    func post(_ event: CGEvent) {
        events.append(event)
    }
}

private final class RecordingAXActionPerformer: AccessibilityActionPerforming {
    private let supported: Set<String>
    private(set) var performed: [String] = []

    init(supported: Set<String> = []) {
        self.supported = supported
    }

    func supports(_ action: String, on element: SnapshotElementReference) throws -> Bool {
        supported.contains(action)
    }

    func perform(_ action: String, on element: SnapshotElementReference) throws {
        performed.append(action)
    }
}

private struct FixtureScreenProvider: ScreenProviding {
    let frames = [CGRect(x: 0, y: 0, width: 100, height: 100)]
}

private func unicodeText(from event: CGEvent) -> String {
    var length = 0
    var characters = Array(repeating: UniChar(0), count: 256)
    characters.withUnsafeMutableBufferPointer {
        event.keyboardGetUnicodeString(maxStringLength: $0.count, actualStringLength: &length, unicodeString: $0.baseAddress)
    }
    return String(utf16CodeUnits: characters, count: length)
}

private extension SnapshotElementReference {
    static let fixture = SnapshotElementReference(axReference: AXElementReference(identifier: "fixture"))
}
