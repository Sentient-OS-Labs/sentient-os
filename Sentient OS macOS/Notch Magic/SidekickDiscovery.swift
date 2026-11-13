// Local acknowledgements for Home’s temporary notch cue.
// Doc: Documentation - Sidekick - General.md
import Foundation

nonisolated enum SidekickDiscovery {
    static let notchUsesKey = "sidekick.discovery.notchUses"
    static let notchLearningUses = 3

    static func recordNotchUse(in defaults: UserDefaults = .standard) {
        let uses = min(notchLearningUses, max(0, defaults.integer(forKey: notchUsesKey)))
        if uses < notchLearningUses { defaults.set(uses + 1, forKey: notchUsesKey) }
    }

}
