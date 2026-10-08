//
//  CustomInstructions.swift
//  Sentient OS macOS
//
//  The user's standing instructions from Settings: morning-suggestion preferences, Sidekick
//  context, and Double Tap reply preferences. This is the shared source of truth for their
//  UserDefaults keys; the settings panes write them and each feature's prompts read them here.
//  (`sidekick.hotkey` is separate — it drives SidekickHotkeyMonitor, not a prompt.)
//
//  Consumers: Proactive.instructionsBlock · CommandRunModel.commandPrompt · DoubleTapInference.
//

import Foundation

enum CustomInstructions {
    /// Standing instructions for the proactive suggestion writer (what to surface / skip).
    static let proactiveKey = "proactive.instructions"
    /// Standing context for Sidekick + the command bar (preferred apps, browser, norms).
    static let sidekickKey = "sidekick.context"
    /// Reply preferences for Double Tap, independent of Sidekick's task context.
    static let doubleTapKey = "doubletap.instructions"
    static let doubleTapByteLimit = 16_000

    /// The proactive instructions, trimmed ("" when the user has set none).
    static var proactive: String { value(proactiveKey) }
    /// The Sidekick context, trimmed ("" when the user has set none).
    static var sidekick: String { value(sidekickKey) }
    /// Both the existing settings field and automatic learning write the same production key.
    @MainActor static func saveSidekick(_ text: String) { SidekickInstructionStore.saveUserEdit(text) }
    @MainActor static func sidekickSnapshot() -> SidekickInstructionStore.Snapshot { SidekickInstructionStore.snapshot() }
    static var doubleTap: String { value(doubleTapKey) }

    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
