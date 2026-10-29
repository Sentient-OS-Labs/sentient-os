// Durable milestones for the Sidekick-first flow. Home admission, source setup, and the
// first completed analysis are separate facts. Permissions are always probed live.
import Foundation

enum PersonalSetupProgress {
    static let homeKey = "hasCompletedOnboarding" // retain the shipped admission key
    static let completedKey = "onboarding.personalSetupCompleted"
    static let startedKey = "onboarding.personalSetupStarted"
    static let stageKey = "onboarding.personalSetupStage"
    static let resumeKey = "onboarding.resumePersonalSetup"
    static let firstTaskKey = "onboarding.firstSuccessfulSidekickTask"
    static let versionKey = "onboarding.sidekickFirstVersion"
    static let version = 1
    static let firstTaskCompleted = Notification.Name("Sentient.personalSetup.firstSidekickTaskCompleted")

    enum Stage: String { case sources, timing }

    /// Return whether old implicit folder selections belong to an established setup. Run before
    /// any picker is constructed. A saved source opt-out is handled by SourceSelection's migration.
    @discardableResult
    static func migrate(defaults: UserDefaults = .standard) -> Bool {
        // Provider access/usage responses decide what a ChatGPT account can do. Retire the
        // old app-side Free/Go lock without erasing its sources, knowledge, or conversations.
        defaults.removeObject(forKey: "plan.kbOnly")
        if defaults.integer(forKey: versionKey) >= version {
            return defaults.bool(forKey: completedKey)
        }
        let oldHome = defaults.bool(forKey: homeKey)
        let learned = ProcessingPlan.initialCompletedAt(defaults) != nil
        let analysisChosen = ProcessingPlan.read(defaults).status != .idle
        let oldSetup = oldHome || learned || analysisChosen
        let passedModel = defaults.integer(forKey: "onboarding.step") >= 2
        defaults.set(oldHome || learned || analysisChosen || passedModel, forKey: homeKey)
        defaults.set(oldSetup, forKey: completedKey)
        defaults.set(oldSetup || defaults.integer(forKey: "onboarding.step") >= 3, forKey: startedKey)
        defaults.set(Stage.sources.rawValue, forKey: stageKey)
        // Incomplete legacy setup becomes an invitation on Home, never another forced wizard.
        defaults.set(version, forKey: versionKey)
        return oldSetup
    }

    static func isComplete(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey) || ProcessingPlan.initialCompletedAt(defaults) != nil
    }

    static func begin(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: startedKey)
    }

    static func recordSuccessfulTask(defaults: UserDefaults = .standard) {
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"], mode != "sidekickapp" { return }
        #endif
        guard !defaults.bool(forKey: firstTaskKey) else { return }
        defaults.set(true, forKey: firstTaskKey)
        NotificationCenter.default.post(name: firstTaskCompleted, object: nil)
    }

    static func finish(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedKey)
        defaults.removeObject(forKey: resumeKey)
        defaults.set(Stage.sources.rawValue, forKey: stageKey)
    }

    /// Only a deliberate permission relaunch reopens setup. Ordinary quits keep its saved
    /// choices but return to Home, where the user can choose when to continue.
    static func consumeRelaunchResume(defaults: UserDefaults = .standard) -> Bool {
        let resume = defaults.bool(forKey: resumeKey)
        defaults.removeObject(forKey: resumeKey)
        return resume
    }

    static func reset(defaults: UserDefaults = .standard) {
        for key in [completedKey, startedKey, stageKey, resumeKey, firstTaskKey] {
            defaults.removeObject(forKey: key)
        }
        // Reset retains explicit source choices. Keep the migration marker so those choices
        // cannot be reinterpreted as a completed legacy onboarding on the next launch.
        defaults.set(version, forKey: versionKey)
    }
}
