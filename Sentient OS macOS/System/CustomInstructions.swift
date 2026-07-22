//
//  CustomInstructions.swift
//  Sentient OS macOS
//
//  The user's standing, free-text instructions set in Settings → Proactive & Sidekick: what to care
//  about / skip in the morning suggestions, and standing context for Sidekick ("text via WhatsApp,
//  my browser is Edge"). This is the ONE source of truth for those two UserDefaults keys — the pane
//  (ProactivePane) writes them, the prompts read them here, so a rename can never silently unwire.
//  (`sidekick.hotkey` is separate — it drives SidekickHotkeyMonitor, not a prompt.)
//
//  Response / App language instructions do NOT live here — those are computed every request by
//  `ResponseLanguage.promptBlock` / `promptLine`. A localization string that was once pasted into
//  `proactive.instructions` is stripped on launch so language stays a live preference, not
//  deletable user content.
//
//  Consumers: Proactive.instructionsBlock (PART 1 + PART 2) · CommandRunModel.commandPrompt (Sidekick).
//

import Foundation

enum CustomInstructions {
    /// Standing instructions for the proactive suggestion writer (what to surface / skip).
    static let proactiveKey = "proactive.instructions"
    /// Standing context for Sidekick + the command bar (preferred apps, browser, norms).
    static let sidekickKey = "sidekick.context"

    /// The proactive instructions, trimmed ("" when the user has set none).
    /// Never returns a misplaced Response-language string (those belong in `ResponseLanguage`).
    static var proactive: String {
        sanitizeProactive(value(proactiveKey))
    }

    /// The Sidekick context, trimmed ("" when they've set none).
    static var sidekick: String { value(sidekickKey) }

    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Misplaced language-instruction cleanup

    /// Exact strings that were incorrectly stored as editable Proactive instructions during early
    /// i18n work. Language directives must come from `ResponseLanguage` on every AI call — not
    /// from this UserDefaults field (deleting the field must not "lose" localization).
    private static let misplacedLanguageInstructions: Set<String> = [
        "Всегда показывай названия, описания, планы действий и кнопки всех утренних предложений и задач на русском языке. Не используй английский язык, кроме названий продуктов, сайтов и технических идентификаторов.",
        "Always show titles, descriptions, action plans, and buttons of all morning suggestions and tasks in English. Do not use other languages except for product names, websites, and technical identifiers.",
        "Always show titles, descriptions, action plans, and buttons of all morning suggestions and tasks in English. Do not use other languages except for product names, website names, and technical identifiers.",
    ]

    /// Drop a stored `proactive.instructions` value when it is ONLY a misplaced language line
    /// (or that line plus blank lines). Call once at launch; also applied on every `proactive` read.
    static func stripMisplacedLanguageInstructionsIfNeeded() {
        let raw = (UserDefaults.standard.string(forKey: proactiveKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let cleaned = sanitizeProactive(raw)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: proactiveKey)
            Log("CustomInstructions: cleared misplaced Response-language text from proactive.instructions (language is live via ResponseLanguage)")
        } else if cleaned != raw {
            UserDefaults.standard.set(cleaned, forKey: proactiveKey)
            Log("CustomInstructions: stripped misplaced Response-language line(s) from proactive.instructions")
        }
    }

    /// Remove known language-instruction paragraphs; keep the user's real standing preferences.
    private static func sanitizeProactive(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isMisplacedLanguageInstruction($0) }
        // Also drop single-line matches inside a multi-line blob without blank separators.
        let kept = paragraphs.compactMap { paragraph -> String? in
            let lines = paragraph
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let filtered = lines.filter { !isMisplacedLanguageInstruction($0) }
            if filtered.isEmpty { return nil }
            if filtered.count == lines.count { return paragraph }
            return filtered.joined(separator: "\n")
        }
        return kept.joined(separator: "\n\n")
    }

    private static func isMisplacedLanguageInstruction(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if misplacedLanguageInstructions.contains(t) { return true }
        // Prefix match: user may have appended STATUS-marker notes to the same pasted blob.
        return misplacedLanguageInstructions.contains { seed in
            t.hasPrefix(seed) && t.count <= seed.count + 200
        }
    }
}
