//
//  QuickTranscriptionEngine.swift
//  Sentient OS macOS
//
//  The seam between VoiceCapture and a concrete speech-to-text backend: SpeechAnalyzerEngine on
//  macOS 26+, SFSpeechRecognizerEngine on macOS 15 — both behind this one protocol. We capture
//  the whole utterance and return ONE final, high-quality transcript — no streaming partials.
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
    case noMicrophone       // no input device (the hardware format is 0 Hz / 0 ch)
    case deviceChanged      // the audio engine's bus format is stale after an input-device change (MicrophoneEngine rebuilds)

    var errorDescription: String? {
        switch self {
        case .unavailable:      return "Voice input needs macOS 26 or later."
        case .notAuthorized:    return "Microphone or speech-recognition access is off."
        case .modelUnavailable: return "The on-device speech model isn't ready yet."
        case .noMicrophone:     return "No microphone is available."
        case .deviceChanged:    return "The microphone changed — try again."
        }
    }
}
