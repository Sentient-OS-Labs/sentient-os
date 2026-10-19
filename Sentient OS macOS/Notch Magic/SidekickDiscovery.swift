// Local discovery acknowledgements for Home's shortcuts. No task content or telemetry.
// The analysis timestamp makes the ready hint one-shot per completed initial analysis.
// Doc: Documentation - Sidekick - General.md
import Foundation

nonisolated enum SidekickDiscovery {
    static let readyHintSeenKey = "doubletap.discovery.readyHintSeenAt"
    static let notchUsesKey = "sidekick.discovery.notchUses"
    static let notchLearningUses = 3

    static func recordNotchUse(in defaults: UserDefaults = .standard) {
        let uses = min(notchLearningUses, max(0, defaults.integer(forKey: notchUsesKey)))
        if uses < notchLearningUses { defaults.set(uses + 1, forKey: notchUsesKey) }
    }

    static func readyHintPending(completedAt: Double, seenAt: Double) -> Bool {
        completedAt.isFinite && completedAt > 0 && completedAt != seenAt
    }
}
