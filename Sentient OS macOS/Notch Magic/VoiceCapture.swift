// Microphone permission and lifecycle for ElevenLabs Scribe dictation. A release invalidates
// pending authorization before it can start a microphone; finalization uses captured audio only.
// Doc: Documentation - Sidekick - General.md
import Foundation
import AppKit
import AVFoundation

@MainActor
final class VoiceCapture {
    static let isAvailable = true
    static let maxCaptureDuration: TimeInterval = 180
    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var engine: ScribeRealtimeEngine?
    private var generation = UUID()
    private var stopRequested = false
    private var authorize: () async -> Bool = { await VoiceCapture.requestPermissions() }
    private var explain: () -> Bool = { VoiceCapture.explainCloudVoice() }
    init() {}
    #if DEBUG
    /// Synthetic permission completions, without a TCC prompt, for lifecycle regression tests.
    init(authorize: @escaping () async -> Bool, explain: @escaping () -> Bool) {
        self.authorize = authorize; self.explain = explain
    }
    #endif
    var onTranscript: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var transcript: String { engine?.transcript ?? "" }

    func start() async throws {
        let id = UUID(); generation = id; stopRequested = false
        guard explain() else { throw CancellationError() }
        // Clicking Use dictation can finish first-use permission setup after the mouse is
        // released. Only a still-current hold may actually open the microphone below.
        guard await authorize() else { throw VoiceError.notAuthorized }
        try Task.checkCancellation()
        guard generation == id, !stopRequested else { throw CancellationError() }
        let engine = ScribeRealtimeEngine()
        engine.onTranscript = onTranscript; engine.onLevel = onLevel
        engine.onReady = onReady; engine.onFailure = onFailure
        self.engine = engine
        do { try engine.start() }
        catch { engine.cancel(); if generation == id { self.engine = nil }; throw error }
    }

    func stopCapturing() {
        stopRequested = true
        engine?.stopCapturing()
    }
    func stopAndTranscribe() async throws -> String {
        stopCapturing()
        guard let engine else { return "" }
        let id = generation
        defer { if generation == id { self.engine = nil } }
        return try await engine.finish()
    }
    func cancel() {
        generation = UUID(); stopRequested = true
        engine?.cancel(); engine = nil
    }
    @discardableResult
    static func requestPermissions() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    private static func explainCloudVoice() -> Bool {
        let key = "sidekick.elevenLabsVoiceExplained"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = "Speak to Sidekick"
        alert.informativeText = "Hold the notch and speak. Release to send, or press Escape to cancel.\n\nSentient doesn’t save your recordings."
        alert.addButton(withTitle: "Use dictation")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }
}

nonisolated enum VoiceError: LocalizedError, Sendable {
    case notAuthorized, noMicrophone, deviceChanged
    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Turn on microphone access to dictate to Sidekick."
        case .noMicrophone: "No microphone audio is available. Check your input device and try again."
        case .deviceChanged: "The microphone changed. Your available text has been kept."
        }
    }
}
