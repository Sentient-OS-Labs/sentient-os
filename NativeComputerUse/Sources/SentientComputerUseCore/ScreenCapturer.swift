@preconcurrency import CoreGraphics
import Darwin
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
    func cleanup()
}

public extension ScreenCapturing {
    func cleanup() {}
}

struct CapturedScreenImage {
    let displayID: UInt32
    let image: CGImage
}

protocol ScreenCaptureBacking {
    func captureMainDisplay() async throws -> CapturedScreenImage
}

enum ScreenCaptureDisplaySelection {
    static func mainDisplayIndex(in displayIDs: [UInt32], mainDisplayID: UInt32) throws -> Int {
        guard let index = displayIDs.firstIndex(of: mainDisplayID) else {
            throw ServiceError(code: .captureFailed, message: "Main display is unavailable")
        }
        return index
    }
}

public final class ScreenCapturer: ScreenCapturing {
    private let backend: any ScreenCaptureBacking
    private let temporaryDirectory: URL
    private let processIdentifier: Int32
    private var captureURLs: Set<URL> = []

    public convenience init() {
        self.init(backend: SystemScreenCaptureBackend())
    }

    init(
        backend: any ScreenCaptureBacking,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        processIdentifier: Int32 = getpid()
    ) {
        self.backend = backend
        self.temporaryDirectory = temporaryDirectory
        self.processIdentifier = processIdentifier
        sweepStaleCaptures()
    }

    public func captureMainDisplay() async throws -> CaptureResult {
        cleanup()
        let captured = try await backend.captureMainDisplay()
        let directory = temporaryDirectory.appendingPathComponent("SentientComputerUse", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(processIdentifier)-\(UUID().uuidString).png")
        try Self.writePNG(captured.image, to: path)
        captureURLs.insert(path)
        return CaptureResult(
            path: path.path,
            displayID: captured.displayID,
            width: captured.image.width,
            height: captured.image.height
        )
    }

    public func cleanup() {
        captureURLs = Set(captureURLs.filter { url in
            do {
                try FileManager.default.removeItem(at: url)
                return false
            } catch {
                return true
            }
        })
    }

    deinit {
        cleanup()
    }

    private func sweepStaleCaptures() {
        let directory = temporaryDirectory.appendingPathComponent("SentientComputerUse", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension.lowercased() == "png" {
            let owner = file.deletingPathExtension().lastPathComponent
                .split(separator: "-", maxSplits: 1)
                .first
                .flatMap { Int32($0) }
            if let owner, owner != processIdentifier, Self.isProcessAlive(owner) {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if Darwin.kill(processIdentifier, 0) == 0 { return true }
        return errno == EPERM
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        let mainDisplayIndex = try ScreenCaptureDisplaySelection.mainDisplayIndex(
            in: content.displays.map(\.displayID),
            mainDisplayID: mainDisplayID
        )
        let display = content.displays[mainDisplayIndex]

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedScreenImage(displayID: display.displayID, image: image)
    }
}
