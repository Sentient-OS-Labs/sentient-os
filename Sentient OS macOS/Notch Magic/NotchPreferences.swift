// Persisted notch interaction and processing appearance preferences.
// Doc: Documentation - Sidekick - General.md
import Foundation

nonisolated enum NotchPreferences {
    static let clickEnabledKey = "sidekick.notchClickEnabled"
    static let compactModeKey = "sidekick.compactNotchMode"
    static func clickEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: clickEnabledKey) as? Bool ?? true
    }

    static func compactModeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: compactModeKey)
    }
}

extension Notification.Name {
    static let notchInteractionChanged = Notification.Name("sidekick.notchInteractionChanged")
    static let notchAppearanceChanged = Notification.Name("sidekick.notchAppearanceChanged")
}
