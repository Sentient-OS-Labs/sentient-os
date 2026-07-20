@preconcurrency import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

public struct CaptureResult: Codable, Sendable, Equatable {
    public let path: String
    public let displayID: UInt32
    public let width: Int
    public let height: Int

    public init(path: String, displayID: UInt32, width: Int, height: Int) {
        self.path = path
        self.displayID = displayID
        self.width = width
        self.height = height
    }
}

public protocol ScreenCapturing {
    func captureMainDisplay() async throws -> CaptureResult
}

struct CapturedScreenImage {
    let displayID: UInt32
    let image: CGImage
}

protocol ScreenCaptureBacking {
    func captureMainDisplay() async throws -> CapturedScreenImage
}

public final class ScreenCapturer: ScreenCapturing {
    private let backend: any ScreenCaptureBacking
    private let temporaryDirectory: URL

    public convenience init() {
        self.init(backend: SystemScreenCaptureBackend())
    }

    init(
        backend: any ScreenCaptureBacking,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.backend = backend
        self.temporaryDirectory = temporaryDirectory
    }

    public func captureMainDisplay() async throws -> CaptureResult {
        let captured = try await backend.captureMainDisplay()
        let directory = temporaryDirectory.appendingPathComponent("SentientComputerUse", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(UUID().uuidString).png")
        try Self.writePNG(captured.image, to: path)
        return CaptureResult(
            path: path.path,
            displayID: captured.displayID,
            width: captured.image.width,
            height: captured.image.height
        )
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ServiceError(code: .captureFailed, message: "Unable to encode display capture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ServiceError(code: .captureFailed, message: "Unable to encode display capture")
        }
    }
}

private struct SystemScreenCaptureBackend: ScreenCaptureBacking {
    func captureMainDisplay() async throws -> CapturedScreenImage {
        guard #available(macOS 14.0, *) else {
            throw ServiceError(code: .captureFailed, message: "Screen capture is unavailable on this macOS version")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw ServiceError(code: .captureFailed, message: "Main display is unavailable")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedScreenImage(displayID: display.displayID, image: image)
    }
}
