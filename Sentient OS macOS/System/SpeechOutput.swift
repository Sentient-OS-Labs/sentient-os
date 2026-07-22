//
//  SpeechOutput.swift
//  Sentient OS macOS
//
//  Optional on-device TTS (Phase 5 / #264): AVSpeechSynthesizer reads Sidekick / command-bar
//  outcome lines aloud when the user opts in under Settings → System → Language. Voice locale
//  follows Response language (en-US / ru-RU). Off by default — never speaks without consent.
//

import AVFoundation
import Foundation

@MainActor
enum SpeechOutput {
    /// UserDefaults / @AppStorage key — opt-in; default false.
    static let enabledKey = "tts.speakReplies"

    private static let synthesizer = AVSpeechSynthesizer()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Speak user-facing reply text when opt-in is on. No-op when disabled or text is empty
    /// after stripping status glyphs. Stops any in-flight utterance first.
    static func speak(_ text: String) {
        guard isEnabled else { return }
        let cleaned = sanitize(text)
        guard !cleaned.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = AVSpeechSynthesisVoice(language: preferredLanguageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// Halt any in-flight utterance (new run starting, user STOP, etc.).
    static func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// BCP-47 language for `AVSpeechSynthesisVoice` — matches Response language (spoken replies).
    private static var preferredLanguageCode: String {
        ResponseLanguage.stored.resolved.preferredSpeechLocale.identifier
    }

    /// Drop status glyphs / dashes so the Mac voice doesn't spell punctuation aloud.
    private static func sanitize(_ text: String) -> String {
        var t = text
        for glyph in ["✓", "✗", "■", "—", "–"] {
            t = t.replacingOccurrences(of: glyph, with: " ")
        }
        return t
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
