// Persisted preference for the idle notch click affordance; open Sidekick controls stay interactive.
// Doc: Documentation - Sidekick - General.md
import Foundation

/// Only the idle notch affordance is optional. An open Sidekick keeps its normal controls.
nonisolated enum NotchPreferences {
    static let clickEnabledKey = "sidekick.notchClickEnabled"
    static func clickEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: clickEnabledKey) as? Bool ?? true
    }
}

extension Notification.Name {
    static let notchInteractionChanged = Notification.Name("sidekick.notchInteractionChanged")
}
