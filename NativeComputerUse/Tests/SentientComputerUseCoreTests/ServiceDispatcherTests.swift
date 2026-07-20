import CoreGraphics
import Foundation
import XCTest
@testable import SentientComputerUseCore

final class ServiceDispatcherTests: XCTestCase {
    func testGetAppStateDeniesAccessibilityBeforeTouchingDependencies() async {
        let fixtures = DispatcherFixtures(accessibilityGranted: false)

        let response = await fixtures.dispatcher.handle(.init(id: "denied", operation: .getAppState, arguments: ["app": .string("Notes")]))

        XCTAssertEqual(response, .failure(id: "denied", ServiceError(code: .permissionDeniedAccessibility, message: "Accessibility permission is required")))
        XCTAssertEqual(fixtures.catalog.resolveCount, 0)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 0)
        XCTAssertEqual(fixtures.capturer.captureCount, 0)
    }

    func testCaptureFailureMapsToStableCaptureError() async {
        let fixtures = DispatcherFixtures(captureError: FixtureError.failed)

        let response = await fixtures.dispatcher.handle(.init(id: "capture", operation: .getAppState, arguments: ["app": .string("Notes")]))

        XCTAssertEqual(response, .failure(id: "capture", ServiceError(code: .captureFailed, message: "Unable to capture the display")))
        XCTAssertEqual(fixtures.catalog.resolveCount, 1)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 1)
        XCTAssertEqual(fixtures.capturer.captureCount, 1)
    }

    func testGetAppStateDeniesScreenRecordingBeforeTouchingCaptureCatalogOrAX() async {
        let fixtures = DispatcherFixtures(screenRecordingGranted: false)

        let response = await fixtures.dispatcher.handle(.init(id: "screen-denied", operation: .getAppState, arguments: ["app": .string("Notes")]))

        XCTAssertEqual(response, .failure(id: "screen-denied", ServiceError(code: .permissionDeniedScreenRecording, message: "Screen Recording permission is required")))
        XCTAssertEqual(fixtures.catalog.resolveCount, 0)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 0)
        XCTAssertEqual(fixtures.capturer.captureCount, 0)
    }

    func testEveryOperationRoutesToOnlyItsRequestedDependencyAction() async {
        let fixtures = DispatcherFixtures()
        let requests: [ServiceRequest] = [
            .init(id: "list", operation: .listApps, arguments: [:]),
            .init(id: "state", operation: .getAppState, arguments: ["app": .string("Notes"), "disableDiff": .bool(true)]),
            .init(id: "click", operation: .click, arguments: ["app": .string("Notes"), "element_index": .int(0)]),
            .init(id: "text", operation: .typeText, arguments: ["app": .string("Notes"), "text": .string("private text")]),
            .init(id: "key", operation: .pressKey, arguments: ["app": .string("Notes"), "key": .string("super+c")]),
            .init(id: "scroll", operation: .scroll, arguments: ["app": .string("Notes"), "direction": .string("down"), "element_index": .int(0)])
        ]

        for request in requests {
            let response = await fixtures.dispatcher.handle(request)
            XCTAssertEqual(response.id, request.id)
        }

        XCTAssertEqual(fixtures.catalog.applicationsCount, 1)
        XCTAssertEqual(fixtures.catalog.resolveCount, 3)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 1)
        XCTAssertEqual(fixtures.inspector.resolveReferenceCount, 1)
        XCTAssertEqual(fixtures.inspector.latestElementCount, 1)
        XCTAssertEqual(fixtures.capturer.captureCount, 1)
        XCTAssertEqual(fixtures.input.clickCount, 1)
        XCTAssertEqual(fixtures.input.typeTextCount, 1)
        XCTAssertEqual(fixtures.input.pressKeyCount, 1)
        XCTAssertEqual(fixtures.input.scrollCount, 1)
    }

    func testUnknownAndMalformedArgumentsReturnInvalidRequestBeforePermissions() async {
        let fixtures = DispatcherFixtures(accessibilityGranted: false)
        let requests: [ServiceRequest] = [
            .init(id: "unknown", operation: .listApps, arguments: ["extra": .bool(true)]),
            .init(id: "malformed", operation: .typeText, arguments: ["app": .string("Notes"), "text": .int(2)])
        ]

        for request in requests {
            let response = await fixtures.dispatcher.handle(request)
            guard case let .failure(id, error) = response else {
                return XCTFail("Expected an invalid request response")
            }
            XCTAssertEqual(id, request.id)
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(fixtures.permissions.accessibilityChecks, 0)
        XCTAssertEqual(fixtures.input.typeTextCount, 0)
    }

    func testSkyWireShapesResolveLatestInternalSnapshotReferencesWithoutExposingToken() async {
        let fixtures = DispatcherFixtures()
        let request = ServiceRequest(
            id: "semantic",
            operation: .click,
            arguments: [
                "app": .string("Notes"),
                "element_index": .int(0)
            ]
        )

        _ = await fixtures.dispatcher.handle(request)

        XCTAssertEqual(fixtures.inspector.resolvedReferences, [.fixture])
        XCTAssertEqual(fixtures.input.clickedElements, [.fixture])
    }

    func testScrollAtElementUsesLatestSnapshotFrameCenter() async {
        let fixtures = DispatcherFixtures()

        _ = await fixtures.dispatcher.handle(.init(
            id: "scroll-anchor",
            operation: .scroll,
            arguments: ["app": .string("Notes"), "element_index": .int(0), "direction": .string("down")]
        ))

        XCTAssertEqual(fixtures.input.scrollAnchors, [CGPoint(x: 25, y: 40)])
    }

    func testInputArgumentsAreValidatedBeforePermissions() async {
        let fixtures = DispatcherFixtures(accessibilityGranted: false)
        let requests: [ServiceRequest] = [
            .init(id: "count", operation: .click, arguments: ["app": .string("Notes"), "x": .int(1), "y": .int(1), "click_count": .int(4)]),
            .init(id: "pages", operation: .scroll, arguments: ["app": .string("Notes"), "direction": .string("down"), "pages": .int(11)]),
            .init(id: "key", operation: .pressKey, arguments: ["app": .string("Notes"), "key": .string("super+not-a-key")])
        ]

        for request in requests {
            let response = await fixtures.dispatcher.handle(request)
            guard case let .failure(id, error) = response else {
                return XCTFail("Expected an invalid request response")
            }
            XCTAssertEqual(id, request.id)
            XCTAssertEqual(error.code, .invalidRequest)
        }
        XCTAssertEqual(fixtures.permissions.accessibilityChecks, 0)
    }
}

private final class DispatcherFixtures {
    let catalog = FakeCatalog()
    let inspector = FakeInspector()
    let input = FakeInputController()
    let permissions: FakePermissionChecker
    let capturer: FakeCapturer
    let dispatcher: ServiceDispatcher

    init(accessibilityGranted: Bool = true, screenRecordingGranted: Bool = true, captureError: Error? = nil) {
        permissions = FakePermissionChecker(accessibilityGranted: accessibilityGranted, screenRecordingGranted: screenRecordingGranted)
        capturer = FakeCapturer(error: captureError)
        dispatcher = ServiceDispatcher(
            catalog: catalog,
            inspector: inspector,
            elementResolver: inspector,
            input: input,
            permissions: permissions,
            screenCapturer: capturer
        )
    }
}

private final class FakeCatalog: ApplicationCataloging {
    private(set) var applicationsCount = 0
    private(set) var resolveCount = 0

    func applications() -> [ApplicationDescriptor] {
        applicationsCount += 1
        return [.fixture]
    }

    func resolve(_ query: String) throws -> ApplicationDescriptor {
        resolveCount += 1
        return .fixture
    }
}

private final class FakeInspector: AccessibilityInspecting, SnapshotElementReferenceResolving {
    let snapshot = AccessibilitySnapshot(token: UUID(), app: .fixture, text: "Notes", elements: [
        SnapshotElement(index: 0, role: "AXButton", title: "Save", value: nil, frame: SnapshotFrame(x: 10, y: 20, width: 30, height: 40), actions: ["AXPress"])
    ])
    private(set) var snapshotCount = 0
    private(set) var resolveReferenceCount = 0
    private(set) var latestElementCount = 0
    private(set) var resolvedReferences: [SnapshotElementReference] = []

    func snapshot(app: ApplicationDescriptor, maxDepth: Int, maxElements: Int) throws -> AccessibilitySnapshot {
        snapshotCount += 1
        return snapshot
    }

    func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func resolveElementReference(snapshotToken: UUID, index: Int) throws -> SnapshotElementReference {
        resolveReferenceCount += 1
        resolvedReferences.append(.fixture)
        return .fixture
    }

    func resolveLatestElementReference(app: ApplicationDescriptor, index: Int) throws -> SnapshotElementReference {
        try resolveElementReference(snapshotToken: snapshot.token, index: index)
    }

    func latestElement(app: ApplicationDescriptor, index: Int) throws -> SnapshotElement {
        latestElementCount += 1
        return snapshot.elements[index]
    }
}

private final class FakeInputController: InputControlling {
    private(set) var clickCount = 0
    private(set) var typeTextCount = 0
    private(set) var pressKeyCount = 0
    private(set) var scrollCount = 0
    private(set) var scrollAnchors: [CGPoint?] = []
    private(set) var clickedElements: [SnapshotElementReference?] = []

    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws {
        clickCount += 1
        clickedElements.append(element)
    }

    func typeText(_ text: String) throws { typeTextCount += 1 }
    func pressKey(_ key: String) throws { pressKeyCount += 1 }
    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws {
        scrollCount += 1
        scrollAnchors.append(anchor)
    }
}

private final class FakePermissionChecker: PermissionChecking {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    private(set) var accessibilityChecks = 0
    private(set) var screenRecordingChecks = 0

    init(accessibilityGranted: Bool = true, screenRecordingGranted: Bool = true) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
    }

    func hasAccessibilityPermission() -> Bool {
        accessibilityChecks += 1
        return accessibilityGranted
    }

    func hasScreenRecordingPermission() -> Bool {
        screenRecordingChecks += 1
        return screenRecordingGranted
    }
}

private final class FakeCapturer: ScreenCapturing {
    let error: Error?
    private(set) var captureCount = 0

    init(error: Error? = nil) { self.error = error }

    func captureMainDisplay() async throws -> CaptureResult {
        captureCount += 1
        if let error { throw error }
        return CaptureResult(path: "/tmp/capture.png", displayID: 1, width: 100, height: 50)
    }
}

private enum FixtureError: Error { case failed }

private extension ApplicationDescriptor {
    static let fixture = ApplicationDescriptor(name: "Notes", bundleIdentifier: "com.apple.Notes", path: "/Applications/Notes.app", processIdentifier: 1)
}

private extension SnapshotElementReference {
    static let fixture = SnapshotElementReference(axReference: AXElementReference(identifier: "fixture"))
}
