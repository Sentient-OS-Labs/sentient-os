//
//  VoiceCapture.swift
//  Sentient OS macOS
//
//  The voice front-end for the right-⌘ hotkey: requests microphone + speech permission (once, lazily,
//  on first hold), picks the OS-appropriate transcription engine, and exposes start / stopAndTranscribe
//  / cancel. macOS 26 prefers SpeechAnalyzerEngine; if Russian on-device assets fail but
//  SFSpeechRecognizer is available (e.g. Dictation), capture falls back to the classic engine.
//
//  Key methods: prewarm() · start() · stopAndTranscribe() · cancel().
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class VoiceCapture {
    private var engine: (any QuickTranscriptionEngine)?

    /// Voice works on every supported macOS (15+): SpeechAnalyzer on 26+, SFSpeechRecognizer below.
    static let isAvailable = true

    /// True only when BOTH mic and speech are ALREADY granted — lets a press start the mic with no
    /// prompt (a tap-to-type must never trigger a permission dialog; first-use prompting waits for a hold).
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// How long one capture may run before we force-finalize — the active engine's hard limit.
    static var maxCaptureDuration: TimeInterval {
        if #available(macOS 26, *) { return SpeechAnalyzerEngine.maxUtteranceDuration }
        return SFSpeechRecognizerEngine.maxUtteranceDuration
    }

    /// True while the on-device speech model is genuinely downloading (first run / post-OS-purge) —
    /// a voice hold is answered honestly instead of listening into a model that isn't there.
    /// macOS 15's engine needs no model download.
    static var isModelDownloading: Bool {
        if #available(macOS 26, *) { return SpeechAnalyzerEngine.isModelDownloading }
        return false
    }

    /// Install the on-device speech model ahead of first use (best-effort, off-main).
    func prewarm() {
        if #available(macOS 26, *) {
            Task { await SpeechAnalyzerEngine.prewarm() }   // SFSpeechRecognizer needs no model prewarm
        }
    }

    /// Proactive Russian STT model install when App language resolves to Russian (App = Russian, or
    /// System with Russian as the Mac's primary language). English / non-Russian STT is unchanged —
    /// the coordinator's launch `prewarm()` already covers that path.
    static func prewarmRussianSpeechIfNeeded() {
        guard #available(macOS 26, *) else { return }
        guard AppLanguage.wantsRussianSpeech else { return }
        Log("voice: proactive prewarm — Russian STT model (App language preference)")
        Task { await SpeechAnalyzerEngine.prewarm() }
    }

    // MARK: Capture

    func start() async throws {
        guard await authorize() else { throw VoiceError.notAuthorized }
        if #available(macOS 26, *) {
            let analyzer = SpeechAnalyzerEngine()
            self.engine = analyzer
            do {
                try await analyzer.start()
                return
            } catch {
                analyzer.cancel()
                if case VoiceError.modelUnavailable = error,
                   SFSpeechRecognizerEngine.russianRecognizerIsAvailable() {
                    Log("voice: SpeechAnalyzer Russian on-device model unavailable — falling back to SFSpeechRecognizer (Dictation-backed)")
                    let fallback = SFSpeechRecognizerEngine()
                    self.engine = fallback
                    do {
                        try await fallback.start()
                        return
                    } catch {
                        fallback.cancel()
                        self.engine = nil
                        throw error
                    }
                }
                self.engine = nil
                throw error
            }
        }
        let engine = SFSpeechRecognizerEngine()
        self.engine = engine
        do {
            try await engine.start()
        } catch {
            engine.cancel()
            self.engine = nil
            throw error
        }
    }

    func stopAndTranscribe() async throws -> String {
        guard let engine else { return "" }
        defer { self.engine = nil }
        return Self.correctMishears(try await engine.stopAndTranscribe())
    }

    /// Fix the speech model's common brand mishears the moment transcription completes — before the
    /// transcript is shown or fired. It reliably hears "Sentient" as "ascension"; swap it back. Whole-word
    /// and case-insensitive, preserving the match's leading-letter case ("Ascension" → "Sentient").
    static func correctMishears(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\bascension\\b", options: [.caseInsensitive])
        else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let capitalized = result.substring(with: match.range).first?.isUppercase == true
            result.replaceCharacters(in: match.range, with: capitalized ? "Sentient" : "sentient")
        }
        return result as String
    }

    func cancel() {
        engine?.cancel()
        engine = nil
    }

    // MARK: Engine selection

    // MARK: Permissions (lazy, on first hold)

    /// Microphone (always needed) + speech recognition (the Speech framework gate). Each prompts only
    /// the first time. Returns false if either is denied / restricted.
    private func authorize() async -> Bool {
        guard await Self.requestMicrophone() else { Log("voice: microphone access denied"); return false }
        guard await Self.requestSpeech() else { Log("voice: speech-recognition access denied"); return false }
        return true
    }

    /// Request mic + speech, surfacing the system prompts on first ask. Public entry point for the dev
    /// Permissions panel; the live capture path uses `authorize()`, which calls the same two requests.
    @discardableResult
    static func requestPermissions() async -> Bool {
        guard await requestMicrophone() else { return false }
        return await requestSpeech()
    }

    private static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static func requestSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }
}
