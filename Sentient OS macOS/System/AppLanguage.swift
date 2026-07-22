//
//  AppLanguage.swift
//  Sentient OS macOS
//
//  Single source of truth for the in-app UI language preference (Settings → System).
//  Closes the gap where macOS language ≠ desired Sentient language (#267): System follows
//  the Mac; English / Russian force the SwiftUI locale via `.environment(\.locale)`.
//

import SwiftUI

extension Notification.Name {
    /// Posted when Settings → System → App language changes (`AppLanguage.key`).
    static let appLanguageDidChange = Notification.Name("app.language.changed")
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    /// UserDefaults / @AppStorage key.
    static let key = "app.language"

    var id: String { rawValue }

    /// Locale forced into the SwiftUI tree. `nil` = follow macOS preferred languages.
    var localeOverride: Locale? {
        switch self {
        case .system:  return nil
        case .english: return Locale(identifier: "en")
        case .russian: return Locale(identifier: "ru")
        }
    }

    /// Chip / menu label key (resolved through the String Catalog).
    var labelKey: LocalizedStringKey {
        switch self {
        case .system:  return "System"
        case .english: return "English"
        case .russian: return "Russian"
        }
    }

    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Locale for `String(localized:)` outside the SwiftUI environment (status lines, banners).
    static var resolvedLocale: Locale {
        stored.localeOverride ?? .autoupdatingCurrent
    }

    /// Locale for speech-to-text engines. System follows the Mac; English / Russian force a
    /// speech-appropriate regional identifier so STT matches the in-app language when it differs
    /// from macOS (e.g. App = Russian, system = English → `ru-RU`).
    var preferredSpeechLocale: Locale {
        switch self {
        case .system:
            if let first = Locale.preferredLanguages.first {
                return Locale(identifier: first)
            }
            return .current
        case .english: return Locale(identifier: "en-US")
        case .russian: return Locale(identifier: "ru-RU")
        }
    }

    static var preferredSpeechLocale: Locale {
        stored.preferredSpeechLocale
    }

    /// Whether STT should target Russian (App = Russian, or System with Russian as the Mac's
    /// **primary** language — never a secondary `ru` in preferred languages).
    static var wantsRussianSpeech: Bool {
        switch stored {
        case .russian: return true
        case .english: return false
        case .system:  return systemPrimaryIsRussian
        }
    }

    /// When false, speech engines must not capture/transcribe with an English model — Russian speech
    /// through en-US STT comes out as Latin phonetics, which is worse than a clear "model not ready" error.
    static var allowsEnglishSpeechFallback: Bool { !wantsRussianSpeech }

    /// Whether an on-device / recognizer locale matches the current App-language STT preference.
    static func speechLocaleMatchesPreference(_ locale: Locale) -> Bool {
        let lang = locale.language.languageCode?.identifier
        if wantsRussianSpeech { return lang == "ru" }
        if stored == .english { return lang == "en" }
        let preferred = preferredSpeechLocale.language.languageCode?.identifier
        return lang == preferred
    }

    /// Whether the Mac's primary language is Russian (matches System App-language behavior).
    /// Do **not** scan the full `preferredLanguages` list for a secondary `ru`.
    static var systemPrimaryIsRussian: Bool {
        if let code = Locale.current.language.languageCode?.identifier {
            return code == "ru"
        }
        guard let first = Locale.preferredLanguages.first else { return false }
        return Locale(identifier: first).language.languageCode?.identifier == "ru"
    }

    private static var systemPrimaryIsEnglish: Bool {
        if let code = Locale.current.language.languageCode?.identifier {
            return code == "en"
        }
        guard let first = Locale.preferredLanguages.first else { return false }
        return Locale(identifier: first).language.languageCode?.identifier == "en"
    }

    /// Ordered STT locale candidates for the current App language. Engines try these against
    /// framework-supported / installable locales before any English fallback — so `ru-RU` vs
    /// `ru_RU` vs bare `ru` does not silently strand recognition on English.
    static var speechLocaleCandidates: [Locale] {
        var list: [Locale] = []
        let append: (Locale) -> Void = { loc in
            let id = normalizedSpeechID(loc)
            if !list.contains(where: { normalizedSpeechID($0) == id }) {
                list.append(loc)
            }
        }

        append(preferredSpeechLocale)
        switch stored {
        case .russian:
            ["ru-RU", "ru_RU", "ru"].forEach { append(Locale(identifier: $0)) }
        case .english:
            ["en-US", "en_US", "en-GB", "en"].forEach { append(Locale(identifier: $0)) }
        case .system:
            if systemPrimaryIsRussian {
                ["ru-RU", "ru_RU", "ru"].forEach { append(Locale(identifier: $0)) }
            } else if systemPrimaryIsEnglish {
                ["en-US", "en_US", "en-GB", "en"].forEach { append(Locale(identifier: $0)) }
            }
        }
        return list
    }

    /// BCP-47 form for comparing speech locales (`ru_RU` ≡ `ru-RU`).
    static func normalizedSpeechID(_ locale: Locale) -> String {
        locale.identifier(.bcp47).lowercased()
    }
}

/// Applies the App language preference as a SwiftUI `locale` environment value.
struct AppLanguageEnvironment: ViewModifier {
    @AppStorage(AppLanguage.key) private var languageRaw = AppLanguage.system.rawValue

    func body(content: Content) -> some View {
        let language = AppLanguage(rawValue: languageRaw) ?? .system
        if let locale = language.localeOverride {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}

extension View {
    /// Inherit Settings → System → App language for this view subtree.
    func appLanguage() -> some View {
        modifier(AppLanguageEnvironment())
    }
}
