// Validates native tool replies and checks service readiness through a model-free session.
// Real tasks share the image validator. The list_apps check proves service connectivity only;
// helper permission admission separately requires NativePermissionReadiness's AX/capture proof.
// Doc: Documentation - Native Computer Use.md

import Foundation
import ImageIO

nonisolated enum OpenAIComputerUseProbe {
    static func validateResult(_ result: [String: Any], requiresCapture: Bool) throws {
        if NativeComputerUseFailure.isError(result) { throw NativeComputerUseFailure.classify(result) }
        guard let content = result["content"] as? [[String: Any]] else {
            throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .transport)
        }
        guard requiresCapture else { return }
        let images = content.filter { $0["type"] as? String == "image" }
        guard !images.isEmpty else { throw NativeComputerUseFailure(kind: .capture, code: nil, detail: .missingImage, stage: .imageDecode) }
        guard images.contains(where: validImage) else {
            throw NativeComputerUseFailure(kind: .capture, code: nil, detail: .invalidImage, stage: .imageDecode)
        }
    }

    /// Runtime reads can be useful through accessibility text without a screenshot.
    /// Decide only whether there is usable content; the agent decides whether it suffices
    /// for its next step. Invalid image bytes must not break an otherwise useful model turn.
    static func appStateResult(_ result: [String: Any]) throws -> [String: Any] {
        try validateResult(result, requiresCapture: false)
        let content = result["content"] as! [[String: Any]] // validated above
        let hasText = content.contains {
            $0["type"] as? String == "text"
                && (($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
        let usable = content.filter { $0["type"] as? String != "image" || validImage($0) }
        guard hasText || usable.contains(where: { $0["type"] as? String == "image" }) else {
            throw NativeComputerUseFailure(kind: .capture, code: nil,
                detail: content.contains { $0["type"] as? String == "image" } ? .invalidImage : .missingImage,
                stage: .imageDecode)
        }
        var prepared = result
        prepared["content"] = usable
        if usable.count != content.count {
            prepared["content"] = usable + [["type": "text", "text":
                "A screenshot could not be decoded. Use the available accessibility/text state when sufficient; obtain fresh visual evidence if the next step requires it. Do not guess screen coordinates."]]
        }
        return prepared
    }

    private static func validImage(_ image: [String: Any]) -> Bool {
        guard let encoded = image["data"] as? String, encoded.utf8.count <= 24 * 1_048_576,
              let data = Data(base64Encoded: encoded), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 100_000_000 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil
    }
    static func check(_ configuration: OpenAIComputerUse.Configuration) async throws {
        let diagnostics = CaptureDiagnostics(source: .healthProbe)
        let started = Date()
        let evidence = await CaptureDiagnostics.environment()
        var session: OpenAIComputerUseSession?
        do {
            session = try await OpenAIComputerUseSession.open(configuration)
            let data = try await session!.call("list_apps", arguments: JSONSerialization.data(withJSONObject: [:]))
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeComputerUseFailure(kind: .connection, code: nil, detail: .malformedResponse, stage: .probe)
            }
            try validateResult(result, requiresCapture: false)
            try Task.checkCancellation()
            // Closing the last client may normally terminate the helper. Proof is the decoded
            // response above; do not reinterpret idle teardown as a failed service check afterward.
            await session?.close()
            diagnostics.record(.passed, fields: evidence.merging(["probe_requires_capture": "false",
                "duration_ms": String(Int(Date().timeIntervalSince(started) * 1000))]) { _, new in new })
        } catch {
            await session?.close()
            diagnostics.record(error is CancellationError ? .cancelled : .failed,
                failure: error as? NativeComputerUseFailure,
                fields: evidence.merging(["probe_requires_capture": "false", "duration_ms": String(Int(Date().timeIntervalSince(started) * 1000))]) { _, new in new })
            throw error
        }
    }
}
