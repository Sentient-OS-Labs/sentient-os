// Verifies native app state through the same authenticated, model-free session as normal tasks.
// Capture targets only Sentient's synthetic test window; no model turn or arbitrary app selection.
// Doc: Documentation - Native Computer Use.md

import Foundation
import ImageIO

nonisolated enum OpenAIComputerUseProbe {
    static let testWindowText = "Sentient is checking this test window."
    static func validateResult(_ result: [String: Any], requiresCapture: Bool) throws {
        if NativeComputerUseFailure.isError(result) { throw NativeComputerUseFailure.classify(result) }
        guard let content = result["content"] as? [[String: Any]] else {
            throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
        }
        guard requiresCapture else { return }
        let images = content.filter { $0["type"] as? String == "image" }
        guard !images.isEmpty else { throw NativeComputerUseFailure(kind: .capture, code: nil, detail: .missingImage, stage: .imageDecode) }
        guard images.contains(where: { image in
            guard let encoded = image["data"] as? String, encoded.utf8.count <= 24 * 1_048_576,
                  let data = Data(base64Encoded: encoded), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16384, height <= 16384,
                  width * height <= 100_000_000 else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
        }) else { throw NativeComputerUseFailure(kind: .capture, code: nil, detail: .invalidImage, stage: .imageDecode) }
    }
    static func check(_ configuration: OpenAIComputerUse.Configuration, captureApp: String? = nil) async throws {
        // This API is a health check, never a generic user-app capture entry point.
        guard captureApp == nil || captureApp == Bundle.main.bundleURL.path else {
            throw NativeComputerUseFailure(kind: .permission, code: nil, detail: .blockedByPolicy, stage: .probe)
        }
        let diagnostics = CaptureDiagnostics(source: .healthProbe)
        let started = Date()
        let evidence = await CaptureDiagnostics.environment()
        var session: OpenAIComputerUseSession?
        do {
            session = try await OpenAIComputerUseSession.open(configuration)
            let data = try await session!.call(captureApp == nil ? "list_apps" : "get_app_state",
                arguments: JSONSerialization.data(withJSONObject: captureApp.map { ["app": $0] } ?? [:]))
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .probe)
            }
            try validateResult(result, requiresCapture: captureApp != nil)
            if captureApp != nil {
                let content = result["content"] as? [[String: Any]] ?? []
                guard content.contains(where: { $0["type"] as? String == "text" && ($0["text"] as? String)?.contains(testWindowText) == true }) else {
                    throw NativeComputerUseFailure(kind: .capture, code: nil, detail: .testWindowNotObserved, stage: .probe)
                }
            }
            try Task.checkCancellation()
            // Closing the last client may normally terminate the helper. Proof is the decoded
            // response above; do not reinterpret idle teardown as a failed capture afterward.
            await session?.close()
            diagnostics.record(.passed, fields: evidence.merging(["probe_requires_capture": String(captureApp != nil),
                "duration_ms": String(Int(Date().timeIntervalSince(started) * 1000))]) { _, new in new })
        } catch {
            await session?.close()
            diagnostics.record(error is CancellationError ? .cancelled : .failed,
                failure: error as? NativeComputerUseFailure,
                fields: evidence.merging(["probe_requires_capture": String(captureApp != nil), "duration_ms": String(Int(Date().timeIntervalSince(started) * 1000))]) { _, new in new })
            throw error
        }
    }
}
