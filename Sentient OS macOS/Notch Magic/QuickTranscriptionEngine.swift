//
//  QuickTranscriptionEngine.swift
//  Sentient OS macOS
//
//  The seam between VoiceCapture and a concrete speech-to-text backend, so the macOS 26 engine
//  (SpeechAnalyzerEngine) and a future macOS 15 engine (SFSpeechRecognizer) are swappable. We capture
//  the whole utterance and return ONE final, high-quality transcript — no streaming partials.
//
//  Only the macOS 26 engine is implemented for now; older macOS reports unavailable.
//

import Foundation

protocol QuickTranscriptionEngine: AnyObject {
    /// Begin capturing from the microphone. Authorization is handled by VoiceCapture beforehand.
    func start() async throws
    /// Stop capturing and return the finalized transcript (may be empty).
    func stopAndTranscribe() async throws -> String
    /// Abandon the session and discard any result (a quick tap, or a cancelled hold).
    func cancel()
}

enum VoiceError: LocalizedError {
    case unavailable        // no transcription engine on this macOS
    case notAuthorized      // microphone or speech-recognition permission denied
    case modelUnavailable   // the on-device speech model isn't installed / ready

    var errorDescription: String? {
        switch self {
        case .unavailable:      return "Voice input needs macOS 26 or later."
        case .notAuthorized:    return "Microphone or speech-recognition access is off."
        case .modelUnavailable: return "The on-device speech model isn't ready yet."
        }
    }
}
