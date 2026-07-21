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
        XCTAssertEqual(fixtures.inspector.snapshotCount, 0)
        XCTAssertEqual(fixtures.capturer.captureCount, 1)
    }

    func testCaptureFailureKeepsPreviouslyVisibleElementSnapshot() async {
        let fixtures = DispatcherFixtures()
        let firstState = await fixtures.dispatcher.handle(.init(
            id: "first-state",
            operation: .getAppState,
            arguments: ["app": .string("Notes")]
        ))
        XCTAssertEqual(firstState.id, "first-state")
        let previousReference = fixtures.inspector.latestReference

        fixtures.capturer.error = FixtureError.failed
        let failedState = await fixtures.dispatcher.handle(.init(
            id: "failed-state",
            operation: .getAppState,
            arguments: ["app": .string("Notes")]
        ))
        _ = await fixtures.dispatcher.handle(.init(
            id: "click-old",
            operation: .click,
            arguments: ["app": .string("Notes"), "element_index": .int(0)]
        ))

        XCTAssertEqual(failedState, .failure(
            id: "failed-state",
            ServiceError(code: .captureFailed, message: "Unable to capture the display")
        ))
        XCTAssertEqual(fixtures.inspector.latestReference, previousReference)
        XCTAssertEqual(fixtures.input.clickedElements, [previousReference])
    }

    func testGetAppStateDeniesScreenRecordingBeforeTouchingCaptureCatalogOrAX() async {
        let fixtures = DispatcherFixtures(screenRecordingGranted: false)

        let response = await fixtures.dispatcher.handle(.init(id: "screen-denied", operation: .getAppState, arguments: ["app": .string("Notes")]))

        XCTAssertEqual(response, .failure(id: "screen-denied", ServiceError(code: .permissionDeniedScreenRecording, message: "Screen Recording permission is required")))
        XCTAssertEqual(fixtures.catalog.resolveCount, 0)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 0)
        XCTAssertEqual(fixtures.capturer.captureCount, 0)
    }

    func testGetAppStateFocusesRequestedBackgroundAppBeforeCaptureAndSnapshot() async {
        let fixtures = DispatcherFixtures()
        var events: [String] = []
        fixtures.catalog.onResolve = { events.append("resolve") }
        fixtures.activator.onActivate = { events.append("activate") }
        fixtures.capturer.onCapture = { events.append("capture") }
        fixtures.inspector.onSnapshot = { events.append("snapshot") }

        let response = await fixtures.dispatcher.handle(.init(
            id: "focused-state",
            operation: .getAppState,
            arguments: ["app": .string("Background Notes")]
        ))

        XCTAssertEqual(response.id, "focused-state")
        XCTAssertEqual(fixtures.catalog.resolvedQueries, ["Background Notes"])
        XCTAssertEqual(fixtures.activator.activatedProcessIdentifiers, [1])
        XCTAssertEqual(events, ["resolve", "activate", "capture", "snapshot"])
    }

    func testGetAppStateFocusFailureDoesNotSnapshotOrCapture() async {
        let fixtures = DispatcherFixtures(activationSucceeds: false)

        let response = await fixtures.dispatcher.handle(.init(
            id: "unfocused-state",
            operation: .getAppState,
            arguments: ["app": .string("Notes")]
        ))

        XCTAssertEqual(response, .failure(
            id: "unfocused-state",
            ServiceError(code: .applicationNotFound, message: "Application could not be focused")
        ))
        XCTAssertEqual(fixtures.activator.activatedProcessIdentifiers, [1])
        XCTAssertEqual(fixtures.capturer.captureCount, 0)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 0)
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
        XCTAssertEqual(fixtures.catalog.resolveCount, 5)
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
            .init(id: "pages", operation: .scroll, arguments: ["app": .string("Notes"), "direction": .string("down"), "pages": .int(11)])
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

    func testUnsupportedKeyPreservesUnsupportedActionCodeBeforePermissions() async {
        let fixtures = DispatcherFixtures(accessibilityGranted: false)

        let response = await fixtures.dispatcher.handle(.init(
            id: "key",
            operation: .pressKey,
            arguments: ["app": .string("Notes"), "key": .string("super+not-a-key")]
        ))

        XCTAssertEqual(response, .failure(
            id: "key",
            ServiceError(code: .unsupportedAction, message: "Unsupported key: super+not-a-key")
        ))
        XCTAssertEqual(fixtures.permissions.accessibilityChecks, 0)
    }

    func testOffscreenCoordinatesAreRejectedBeforeAccessibilityPermission() async {
        let fixtures = DispatcherFixtures(accessibilityGranted: false)
        let request = ServiceRequest(
            id: "offscreen",
            operation: .click,
            arguments: ["app": .string("Notes"), "x": .int(500), "y": .int(500)]
        )

        let response = await fixtures.dispatcher.handle(request)

        XCTAssertEqual(response, .failure(id: "offscreen", ServiceError(code: .invalidRequest, message: "Coordinate must be finite and on screen")))
        XCTAssertEqual(fixtures.permissions.accessibilityChecks, 0)
        XCTAssertEqual(fixtures.input.coordinateValidationCount, 1)
        XCTAssertEqual(fixtures.input.clickCount, 0)
    }

    func testEveryMutatingActionResolvesAndActivatesItsRequestedApplication() async {
        let fixtures = DispatcherFixtures()
        let requests: [ServiceRequest] = [
            .init(id: "click", operation: .click, arguments: ["app": .string("Notes"), "x": .int(10), "y": .int(10)]),
            .init(id: "text", operation: .typeText, arguments: ["app": .string("Notes"), "text": .string("hello")]),
            .init(id: "key", operation: .pressKey, arguments: ["app": .string("Notes"), "key": .string("Return")]),
            .init(id: "scroll", operation: .scroll, arguments: ["app": .string("Notes"), "direction": .string("down")])
        ]

        for request in requests {
            let response = await fixtures.dispatcher.handle(request)
            XCTAssertEqual(response.id, request.id)
        }

        XCTAssertEqual(fixtures.catalog.resolvedQueries, ["Notes", "Notes", "Notes", "Notes"])
        XCTAssertEqual(fixtures.activator.activatedProcessIdentifiers, [1, 1, 1, 1])
    }

    func testMissingRequestedApplicationPreventsGlobalInput() async {
        let fixtures = DispatcherFixtures(missingApplicationQueries: ["Missing"])

        let response = await fixtures.dispatcher.handle(.init(
            id: "missing",
            operation: .typeText,
            arguments: ["app": .string("Missing"), "text": .string("must not escape")]
        ))

        XCTAssertEqual(response, .failure(
            id: "missing",
            ServiceError(code: .applicationNotFound, message: "Application not found")
        ))
        XCTAssertEqual(fixtures.activator.activatedProcessIdentifiers, [])
        XCTAssertEqual(fixtures.input.typeTextCount, 0)
    }

    func testFocusVerificationFailurePreventsGlobalInput() async {
        let fixtures = DispatcherFixtures(activationSucceeds: false)

        let response = await fixtures.dispatcher.handle(.init(
            id: "focus",
            operation: .pressKey,
            arguments: ["app": .string("Notes"), "key": .string("Return")]
        ))

        XCTAssertEqual(response, .failure(
            id: "focus",
            ServiceError(code: .applicationNotFound, message: "Application could not be focused")
        ))
        XCTAssertEqual(fixtures.activator.activatedProcessIdentifiers, [1])
        XCTAssertEqual(fixtures.input.pressKeyCount, 0)
    }

    func testDispatcherCleanupForwardsOnceAndDeletesCurrentCapture() async throws {
        let capturer = CleanupCapturer()
        let fixtures = DispatcherFixtures(screenCapturer: capturer)
        let response = await fixtures.dispatcher.handle(.init(id: "capture", operation: .getAppState, arguments: ["app": .string("Notes")]))
        XCTAssertEqual(response.id, "capture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: capturer.path.path))

        fixtures.dispatcher.cleanup()
        fixtures.dispatcher.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: capturer.path.path))
        XCTAssertEqual(capturer.cleanupCount, 1)
    }
}

private final class DispatcherFixtures {
    let catalog = FakeCatalog()
    let inspector = FakeInspector()
    let input = FakeInputController()
    let activator: FakeApplicationActivator
    let permissions: FakePermissionChecker
    let capturer: FakeCapturer
    let dispatcher: ServiceDispatcher

    init(
        accessibilityGranted: Bool = true,
        screenRecordingGranted: Bool = true,
        captureError: Error? = nil,
        screenCapturer: (any ScreenCapturing)? = nil,
        missingApplicationQueries: Set<String> = [],
        activationSucceeds: Bool = true
    ) {
        catalog.missingQueries = missingApplicationQueries
        activator = FakeApplicationActivator(succeeds: activationSucceeds)
        permissions = FakePermissionChecker(accessibilityGranted: accessibilityGranted, screenRecordingGranted: screenRecordingGranted)
        capturer = FakeCapturer(error: captureError)
        dispatcher = ServiceDispatcher(
            catalog: catalog,
            inspector: inspector,
            elementResolver: inspector,
            input: input,
            applicationActivator: activator,
            permissions: permissions,
            screenCapturer: screenCapturer ?? capturer
        )
    }
}

private final class FakeCatalog: ApplicationCataloging {
    private(set) var applicationsCount = 0
    private(set) var resolveCount = 0
    private(set) var resolvedQueries: [String] = []
    var missingQueries: Set<String> = []
    var onResolve: (() -> Void)?

    func applications() -> [ApplicationDescriptor] {
        applicationsCount += 1
        return [.fixture]
    }

    func resolve(_ query: String) throws -> ApplicationDescriptor {
        onResolve?()
        resolveCount += 1
        resolvedQueries.append(query)
        if missingQueries.contains(query) {
            throw ServiceError(code: .applicationNotFound, message: "Application not found")
        }
        return .fixture
    }
}

private final class FakeApplicationActivator: ApplicationActivating {
    private let succeeds: Bool
    private(set) var activatedProcessIdentifiers: [Int32] = []
    var onActivate: (() -> Void)?

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func activateAndVerifyFrontmost(_ app: ApplicationDescriptor) -> Bool {
        onActivate?()
        activatedProcessIdentifiers.append(app.processIdentifier)
        return succeeds
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
    private(set) var latestReference: SnapshotElementReference = .fixture
    var onSnapshot: (() -> Void)?

    func snapshot(app: ApplicationDescriptor, maxDepth: Int, maxElements: Int) throws -> AccessibilitySnapshot {
        onSnapshot?()
        snapshotCount += 1
        latestReference = SnapshotElementReference(
            axReference: AXElementReference(identifier: "snapshot-\(snapshotCount)")
        )
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
        resolveReferenceCount += 1
        resolvedReferences.append(latestReference)
        return latestReference
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
    private(set) var coordinateValidationCount = 0

    func validate(coordinate: CGPoint) throws {
        coordinateValidationCount += 1
        guard coordinate.x >= 0, coordinate.y >= 0, coordinate.x < 100, coordinate.y < 100 else {
            throw ServiceError(code: .invalidRequest, message: "Coordinate must be finite and on screen")
        }
    }
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
    var error: Error?
    private(set) var captureCount = 0
    var onCapture: (() -> Void)?

    init(error: Error? = nil) { self.error = error }

    func captureMainDisplay() async throws -> CaptureResult {
        onCapture?()
        captureCount += 1
        if let error { throw error }
        return CaptureResult(path: "/tmp/capture.png", displayID: 1, width: 100, height: 50)
    }
}

private final class CleanupCapturer: ScreenCapturing {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("SentientComputerUseCleanup-\(UUID().uuidString).png")
    private(set) var cleanupCount = 0

    func captureMainDisplay() async throws -> CaptureResult {
        try Data().write(to: path)
        return CaptureResult(path: path.path, displayID: 1, width: 1, height: 1)
    }

    func cleanup() {
        cleanupCount += 1
        try? FileManager.default.removeItem(at: path)
    }

    deinit {
        try? FileManager.default.removeItem(at: path)
    }
}

private enum FixtureError: Error { case failed }

private extension ApplicationDescriptor {
    static let fixture = ApplicationDescriptor(name: "Notes", bundleIdentifier: "com.apple.Notes", path: "/Applications/Notes.app", processIdentifier: 1)
}

private extension SnapshotElementReference {
    static let fixture = SnapshotElementReference(axReference: AXElementReference(identifier: "fixture"))
}
