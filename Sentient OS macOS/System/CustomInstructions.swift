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
//  Consumers: Proactive.instructionsBlock (PART 1 + PART 2) · CommandRunModel.commandPrompt (Sidekick).
//

import Foundation

enum CustomInstructions {
    /// Standing instructions for the proactive suggestion writer (what to surface / skip).
    static let proactiveKey = "proactive.instructions"
    /// Standing context for Sidekick + the command bar (preferred apps, browser, norms).
    static let sidekickKey = "sidekick.context"

    /// The proactive instructions, trimmed ("" when the user has set none).
    static var proactive: String { value(proactiveKey) }
    /// The Sidekick context, trimmed ("" when the user has set none).
    static var sidekick: String { value(sidekickKey) }

    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
