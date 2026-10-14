// ShortcutPreferences.swift
// One shared Sidekick and Double Tap key, preserving the existing sidekick.hotkey preference.
// Recording suspends live shortcuts until the sheet closes; saves apply without a restart.
// Doc: ../Documentation - System (Permissions, Health, Uninstall).md

import Foundation

@MainActor
enum ShortcutPreferences {
    static let storageKey = "sidekick.hotkey"
    private(set) static var isRecording = false
    static var current: ShortcutKey { key(in: .standard) }

    static func key(in defaults: UserDefaults) -> ShortcutKey {
        ShortcutKey(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .rightCommand
    }

    static func save(_ key: ShortcutKey) {
        UserDefaults.standard.set(key.rawValue, forKey: storageKey)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    static func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }
}

extension Notification.Name {
    // Keep the notification identity used by the existing live Settings binding.
    static let shortcutsChanged = Notification.Name("sidekick.hotkey.changed")
}
