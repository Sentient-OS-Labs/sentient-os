//
//  CustomInstructions.swift
//  Sentient OS macOS
//
//  The user's standing instructions from Settings: morning-suggestion preferences, Sidekick
//  memory, and Double Tap reply preferences. SidekickMemory.md is authoritative for Sidekick;
//  the other instructions stay in UserDefaults. Settings and prompts share these accessors.
//  (`sidekick.hotkey` is separate — it drives SidekickHotkeyMonitor, not a prompt.)
//
//  Consumers: Proactive.instructionsBlock · CommandRunModel.commandPrompt · DoubleTapInference.
//

import Foundation

enum CustomInstructions {
    /// Standing instructions for the proactive suggestion writer (what to surface / skip).
    static let proactiveKey = "proactive.instructions"
    /// Legacy storage and observation mirror; SidekickMemory.md is authoritative.
    static let sidekickKey = "sidekick.context"
    /// Reply preferences for Double Tap, independent of Sidekick's task context.
    static let doubleTapKey = "doubletap.instructions"
    static let doubleTapByteLimit = 16_000

    /// The proactive instructions, trimmed ("" when the user has set none).
    static var proactive: String { value(proactiveKey) }
    /// The Sidekick context, trimmed ("" when the user has set none).
    @MainActor static var sidekick: String {
        let memory = sidekickSnapshot()
        return memory.readError == nil ? memory.text.trimmingCharacters(in: .whitespacesAndNewlines) : memory.promptBlock
    }
    /// The user and main Sidekick agent share one file. Saving errors reach the editor.
    @MainActor static func saveSidekick(_ text: String) throws { try SidekickInstructionStore.saveUserEdit(text) }
    @MainActor static func sidekickSnapshot() -> SidekickInstructionStore.Snapshot { SidekickInstructionStore.snapshot() }
    static var doubleTap: String { value(doubleTapKey) }

    private static func value(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
