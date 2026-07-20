import CoreGraphics
import Foundation
import XCTest
@testable import SentientComputerUseCore

final class ScreenCapturerTests: XCTestCase {
    func testPackageDeclaresMacOS15Floor() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")

        XCTAssertTrue(try String(contentsOf: package, encoding: .utf8).contains("platforms: [.macOS(.v15)]"))
    }

    func testCaptureWritesOnePNGToTheServiceTemporaryDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentientComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let backend = FakeScreenCaptureBackend(image: try makeImage())
        let capturer = ScreenCapturer(
            backend: backend,
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await capturer.captureMainDisplay()

        XCTAssertEqual(result.displayID, 42)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
        XCTAssertTrue(result.path.hasPrefix(directory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.path)).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertEqual(backend.captureCount, 1)
    }

    func testCleanupDeletesAllCreatedCapturesAndIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentientComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let capturer = ScreenCapturer(
            backend: FakeScreenCaptureBackend(image: try makeImage()),
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await capturer.captureMainDisplay()
        let second = try await capturer.captureMainDisplay()
        capturer.cleanup()
        capturer.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testNewCaptureDeletesPriorTrackedCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SentientComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let capturer = ScreenCapturer(
            backend: FakeScreenCaptureBackend(image: try makeImage()),
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await capturer.captureMainDisplay()
        let second = try await capturer.captureMainDisplay()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testMainDisplaySelectionRejectsUnavailableMainDisplay() {
        XCTAssertThrowsError(try ScreenCaptureDisplaySelection.mainDisplayIndex(in: [2, 3], mainDisplayID: 1)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .captureFailed, message: "Main display is unavailable"))
        }
    }
}

private final class FakeScreenCaptureBackend: ScreenCaptureBacking {
    private let image: CGImage
    private(set) var captureCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func captureMainDisplay() async throws -> CapturedScreenImage {
        captureCount += 1
        return CapturedScreenImage(displayID: 42, image: image)
    }
}

private func makeImage() throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw XCTSkip("Unable to make a fixture image")
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let image = context.makeImage() else { throw XCTSkip("Unable to make a fixture image") }
    return image
}
