import CoreGraphics
import Foundation
import SentientComputerUseService
import XCTest
@testable import SentientComputerUseCore

final class ServiceLoopTests: XCTestCase {
    func testContinuesAfterMalformedLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.ndjson")
        let outputURL = directory.appendingPathComponent("output.ndjson")
        let input = Data("""
        {\"id\":\"first\",\"operation\":\"list_apps\",\"arguments\":{}}
        not-json
        {\"id\":\"second\",\"operation\":\"list_apps\",\"arguments\":{}}
        """.utf8)
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        await ServiceLoop.run(input: inputHandle, output: outputHandle, dispatcher: ServiceDispatcher())
        try inputHandle.close()
        try outputHandle.close()

        let responses = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(ServiceResponse.self, from: Data($0.utf8)) }

        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses[0].id, "first")
        XCTAssertEqual(responses[1], .failure(id: "", ServiceError(code: .invalidRequest, message: "Invalid request")))
        XCTAssertEqual(responses[2].id, "second")
    }

    func testDiscardsPartialLineWhenInputClosesWithAnError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("output.ndjson")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("not-json".utf8))

        let task = Task {
            await ServiceLoop.run(
                input: pipe.fileHandleForReading,
                output: output,
                dispatcher: ServiceDispatcher()
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        try pipe.fileHandleForReading.close()
        await task.value
        try output.close()

        XCTAssertEqual(try Data(contentsOf: outputURL), Data())
    }

    func testCancellationClosesIdleInputAndCleansUpOnce() async throws {
        let pipe = Pipe()
        let output = FileHandle.standardOutput
        let fixtures = LoopFixtures()
        let finished = expectation(description: "service loop exits after cancellation")
        defer { try? pipe.fileHandleForReading.close() }

        let task = Task {
            await ServiceLoop.run(
                input: pipe.fileHandleForReading,
                output: output,
                dispatcher: fixtures.dispatcher
            )
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }

    func testWriteFailureStopsBeforeLaterRequestDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.ndjson")
        let outputURL = directory.appendingPathComponent("output.ndjson")
        try Data("""
        {"id":"first","operation":"list_apps","arguments":{}}
        {"id":"second","operation":"list_apps","arguments":{}}
        """.utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let input = try FileHandle(forReadingFrom: inputURL)
        let closedOutput = try FileHandle(forWritingTo: outputURL)
        try closedOutput.close()
        let fixtures = LoopFixtures()

        await ServiceLoop.run(input: input, output: closedOutput, dispatcher: fixtures.dispatcher)
        try input.close()

        XCTAssertEqual(fixtures.catalog.applicationsCount, 1)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }
}

private final class LoopFixtures: @unchecked Sendable {
    let catalog = LoopCatalog()
    let capturer = CleanupCountingCapturer()
    let dispatcher: ServiceDispatcher

    init() {
        let inspector = LoopInspector()
        dispatcher = ServiceDispatcher(
            catalog: catalog,
            inspector: inspector,
            elementResolver: inspector,
            input: LoopInput(),
            permissions: LoopPermissions(),
            screenCapturer: capturer
        )
    }
}

private final class LoopCatalog: ApplicationCataloging, @unchecked Sendable {
    private(set) var applicationsCount = 0

    func applications() -> [ApplicationDescriptor] {
        applicationsCount += 1
        return []
    }

    func resolve(_ query: String) throws -> ApplicationDescriptor {
        throw ServiceError(code: .applicationNotFound, message: "Application not found")
    }
}

private struct LoopInspector: AccessibilityInspecting, SnapshotElementReferenceResolving {
    func snapshot(app: ApplicationDescriptor, maxDepth: Int, maxElements: Int) throws -> AccessibilitySnapshot {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func resolveElementReference(snapshotToken: UUID, index: Int) throws -> SnapshotElementReference {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func resolveLatestElementReference(app: ApplicationDescriptor, index: Int) throws -> SnapshotElementReference {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func latestElement(app: ApplicationDescriptor, index: Int) throws -> SnapshotElement {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }
}

private struct LoopInput: InputControlling {
    func validate(coordinate: CGPoint) throws {}
    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws {}
    func typeText(_ text: String) throws {}
    func pressKey(_ key: String) throws {}
    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws {}
}

private struct LoopPermissions: PermissionChecking {
    func hasAccessibilityPermission() -> Bool { true }
    func hasScreenRecordingPermission() -> Bool { true }
}

private final class CleanupCountingCapturer: ScreenCapturing, @unchecked Sendable {
    private(set) var cleanupCount = 0

    func captureMainDisplay() async throws -> CaptureResult {
        throw ServiceError(code: .captureFailed, message: "Unable to capture the display")
    }

    func cleanup() {
        cleanupCount += 1
    }
}
