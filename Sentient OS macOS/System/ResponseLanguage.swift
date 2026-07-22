//
//  ResponseLanguage.swift
//  Sentient OS macOS
//
//  Preference for the language of model-written user-facing text (Sidekick replies, morning
//  cards, gift letter, STATUS summaries shown to the user). Separate from App language (#267):
//  UI can stay English while responses are Russian, or follow App language by default.
//
//  Consumers inject `promptBlock` / `promptLine` into prompt builders on EVERY request —
//  computed live from `stored.resolved`. Never persist these strings into UserDefaults,
//  CustomInstructions, vault files, or any user-editable field (that made the instruction
//  look "deletable" and never come back).
//
//  Never translate harness markers (STATUS: DONE / STATUS: COULD_NOT, JSON keys, tool names);
//  those stay English.
//

import SwiftUI

enum ResponseLanguage: String, CaseIterable, Identifiable {
    /// Follow whatever App language resolves to (default).
    case sameAsApp = "same"
    case english = "en"
    case russian = "ru"

    /// UserDefaults / @AppStorage key.
    static let key = "response.language"

    var id: String { rawValue }

    /// Chip / menu label key (resolved through the String Catalog).
    var labelKey: LocalizedStringKey {
        switch self {
        case .sameAsApp: return "Same as app"
        case .english:   return "English"
        case .russian:   return "Russian"
        }
    }

    static var stored: ResponseLanguage {
        ResponseLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .sameAsApp
    }

    /// Concrete language the model should write user-facing text in.
    enum Resolved: Equatable {
        case english
        case russian

        /// English name used inside English prompt instructions (not UI copy).
        var promptLanguageName: String {
            switch self {
            case .english: return "English"
            case .russian: return "Russian"
            }
        }

        /// Locale for TTS voice selection (`AVSpeechSynthesisVoice`) — regional form matching STT.
        var preferredSpeechLocale: Locale {
            switch self {
            case .english: return Locale(identifier: "en-US")
            case .russian: return Locale(identifier: "ru-RU")
            }
        }
    }

    /// Resolve Same as app → AppLanguage → system **primary** language (never a secondary `ru`
    /// in `preferredLanguages` while the Mac / App UI is English).
    var resolved: Resolved {
        switch self {
        case .english: return .english
        case .russian: return .russian
        case .sameAsApp:
            switch AppLanguage.stored {
            case .english: return .english
            case .russian: return .russian
            case .system:
                return AppLanguage.systemPrimaryIsRussian ? .russian : .english
            }
        }
    }

    /// Shared injection for prompt builders. Always present so English is also explicit.
    /// Recomputed every access from the current preference — never a cached/persisted copy.
    static var promptBlock: String {
        """

        ## RESPONSE LANGUAGE
        \(promptInstruction)

        """
    }

    /// One-line form for compact prompts (command bar / fire wrappers) that don't use markdown sections.
    static var promptLine: String {
        promptInstruction
    }

    /// The live language directive for the current resolved preference. Prompt-layer only
    /// (not String Catalog UI copy). Russian body only when resolved is Russian — never always-on.
    private static var promptInstruction: String {
        switch stored.resolved {
        case .english:
            return """
            CRITICAL: All user-facing text you write MUST be in English. \
            Always show titles, descriptions, action plans, and buttons of all morning \
            suggestions and tasks in English. Do not use other languages except for product \
            names, websites, and technical identifiers. \
            That also includes: the human-readable phrase after `STATUS: DONE —` / \
            `STATUS: COULD_NOT —` (Sidekick outcomes), card_summary, prepared_content the user \
            reads or edits, button_text, detail_label, review_note, and gift-letter prose. \
            Keep machine markers exactly as specified \
            (STATUS: DONE / STATUS: COULD_NOT, JSON keys, tool names) in English.
            """
        case .russian:
            // Prompt-layer instruction for the model (not UI catalog copy). Applied only when
            // Response language resolves to Russian. Cover Sidekick + morning cards + letters.
            return """
            CRITICAL: All user-facing text you write MUST be in Russian (русский язык). \
            Всегда показывай названия, описания, планы действий и кнопки всех утренних \
            предложений и задач на русском языке. Не используй английский язык, кроме \
            названий продуктов, сайтов и технических идентификаторов. \
            That also includes: the human-readable phrase after `STATUS: DONE —` / \
            `STATUS: COULD_NOT —` (Sidekick outcomes), card_summary, prepared_content the user \
            reads or edits, button_text, detail_label, review_note, and gift-letter prose. \
            Keep machine markers exactly as specified \
            (STATUS: DONE / STATUS: COULD_NOT, JSON keys, tool names) in English.
            """
        }
    }
}
