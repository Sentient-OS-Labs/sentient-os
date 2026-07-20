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

    func testEveryOperationRoutesToOnlyItsRequestedDependencyAction() async {
        let fixtures = DispatcherFixtures()
        let snapshotToken = fixtures.inspector.snapshot.token.uuidString
        let requests: [ServiceRequest] = [
            .init(id: "list", operation: .listApps, arguments: [:]),
            .init(id: "state", operation: .getAppState, arguments: ["app": .string("Notes")]),
            .init(id: "click", operation: .click, arguments: ["app": .string("Notes"), "snapshot_token": .string(snapshotToken), "element_index": .int(0)]),
            .init(id: "text", operation: .typeText, arguments: ["app": .string("Notes"), "text": .string("private text")]),
            .init(id: "key", operation: .pressKey, arguments: ["app": .string("Notes"), "key": .string("super+c")]),
            .init(id: "scroll", operation: .scroll, arguments: ["app": .string("Notes"), "direction": .string("down")])
        ]

        for request in requests {
            let response = await fixtures.dispatcher.handle(request)
            XCTAssertEqual(response.id, request.id)
        }

        XCTAssertEqual(fixtures.catalog.applicationsCount, 1)
        XCTAssertEqual(fixtures.catalog.resolveCount, 1)
        XCTAssertEqual(fixtures.inspector.snapshotCount, 1)
        XCTAssertEqual(fixtures.inspector.resolveReferenceCount, 1)
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
            XCTAssertEqual(response, .failure(id: request.id, ServiceError(code: .invalidRequest, message: "Invalid request")))
        }
        XCTAssertEqual(fixtures.permissions.accessibilityChecks, 0)
        XCTAssertEqual(fixtures.input.typeTextCount, 0)
    }

    func testSemanticClickResolvesOnlyAnInternalSnapshotReference() async {
        let fixtures = DispatcherFixtures()
        let request = ServiceRequest(
            id: "semantic",
            operation: .click,
            arguments: [
                "app": .string("Notes"),
                "snapshot_token": .string(fixtures.inspector.snapshot.token.uuidString),
                "element_index": .int(0)
            ]
        )

        _ = await fixtures.dispatcher.handle(request)

        XCTAssertEqual(fixtures.inspector.resolvedReferences, [.fixture])
        XCTAssertEqual(fixtures.input.clickedElements, [.fixture])
    }
}

private final class DispatcherFixtures {
    let catalog = FakeCatalog()
    let inspector = FakeInspector()
    let input = FakeInputController()
    let permissions: FakePermissionChecker
    let capturer: FakeCapturer
    let dispatcher: ServiceDispatcher

    init(accessibilityGranted: Bool = true, captureError: Error? = nil) {
        permissions = FakePermissionChecker(accessibilityGranted: accessibilityGranted)
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
    let snapshot = AccessibilitySnapshot(token: UUID(), app: .fixture, text: "Notes", elements: [])
    private(set) var snapshotCount = 0
    private(set) var resolveReferenceCount = 0
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
}

private final class FakeInputController: InputControlling {
    private(set) var clickCount = 0
    private(set) var typeTextCount = 0
    private(set) var pressKeyCount = 0
    private(set) var scrollCount = 0
    private(set) var clickedElements: [SnapshotElementReference?] = []

    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws {
        clickCount += 1
        clickedElements.append(element)
    }

    func typeText(_ text: String) throws { typeTextCount += 1 }
    func pressKey(_ key: String) throws { pressKeyCount += 1 }
    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws { scrollCount += 1 }
}

private final class FakePermissionChecker: PermissionChecking {
    let accessibilityGranted: Bool
    private(set) var accessibilityChecks = 0
    private(set) var screenRecordingChecks = 0

    init(accessibilityGranted: Bool = true) { self.accessibilityGranted = accessibilityGranted }

    func hasAccessibilityPermission() -> Bool {
        accessibilityChecks += 1
        return accessibilityGranted
    }

    func hasScreenRecordingPermission() -> Bool {
        screenRecordingChecks += 1
        return true
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
