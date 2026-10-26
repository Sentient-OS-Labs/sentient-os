// Offline regression checks for the real FactoryReset orchestration with destructive services
// replaced by no-ops and preferences isolated in a unique suite. No app data or network access.
// Doc: ../Sentient OS macOS/Views/Onboarding/Documentation - Onboarding.md
// Run from the repo root:
// swiftc -parse-as-library Scripts/test_onboarding_reset.swift \
//   "Sentient OS macOS/Ingestion/FactoryReset.swift" -o /tmp/test-onboarding-reset
// /tmp/test-onboarding-reset

import Foundation

private enum TestFailure: Error { case check(String), credentials }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure.check(message) }
}

@main
struct OnboardingResetChecks {
    @MainActor static func main() async throws {
        let suite = "test.sentient.onboarding-reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppState()
        defaults.set(4, forKey: "onboarding.step")
        defaults.set(true, forKey: "onboarding.emailSubmitted")
        defaults.set(true, forKey: AppState.onboardingKey)
        defaults.set(true, forKey: "mcp.mirror.enabled")

        // A failed credential cleanup must not claim that setup has been rewound.
        DirectMCPConnections.shared.fail = true
        let failed = await FactoryReset.run(appState: app, defaults: defaults)
        try check(!failed, "Failed cleanup must return false")
        try check(defaults.bool(forKey: "onboarding.emailSubmitted"), "Failed reset lost email completion")
        try check(defaults.integer(forKey: "onboarding.step") == 4, "Failed reset rewound setup")
        try check(app.hasCompletedOnboarding, "Failed reset changed the live screen")
        try check(app.completedResets == 0, "Failed reset rewound retained Home presentation")
        try check(HostedConnectorSetup.active == false, "Failed reset left teardown active")
        print("PASS: failed reset preserves onboarding state")

        DirectMCPConnections.shared.fail = false
        let reset = await FactoryReset.run(appState: app, defaults: defaults)
        try check(reset, "Reset must succeed")
        try check(!defaults.bool(forKey: "onboarding.emailSubmitted"), "Email sheet would still be skipped after reset")
        try check(defaults.integer(forKey: "onboarding.step") == 0, "Reset must restart setup")
        try check(!defaults.bool(forKey: AppState.onboardingKey), "Persisted onboarding is still complete")
        try check(!app.hasCompletedOnboarding, "Live app was not rewound")
        try check(app.completedResets == 1 && !app.hasCompletedPersonalSetup && !app.hasCompletedFirstSidekickTask,
                  "Successful reset did not use the complete live UI handoff")
        try check(defaults.bool(forKey: "mcp.mirror.enabled"), "Reset lost the mirror opt-in")
        try check(HostedConnectorSetup.active == false, "Successful reset left teardown active")
        print("PASS: successful reset re-arms email and company welcome")

        let reopened = UserDefaults(suiteName: suite)!
        try check(!reopened.bool(forKey: "onboarding.emailSubmitted"), "Reopened preferences skip email")
        // Completing this setup still suppresses repeat prompts until another explicit reset.
        reopened.set(true, forKey: "onboarding.emailSubmitted")
        try check(UserDefaults(suiteName: suite)!.bool(forKey: "onboarding.emailSubmitted"), "Completion did not persist")
        let repeated = await FactoryReset.run(defaults: reopened)
        try check(repeated && !reopened.bool(forKey: "onboarding.emailSubmitted"), "Subsequent reset did not re-arm email")
        print("PASS: completion persists normally; each explicit reset re-arms the prompt")
    }
}

// Compile only with FactoryReset.swift. These replace the destructive collaborators, never
// their orchestration or Foundation preferences, so the test executes the production reset.
enum SidekickInstructionStore { static func resetLearning() {} }
@MainActor final class ComputerUseDoctor {
    static let shared = ComputerUseDoctor()
    func clear(defaults: UserDefaults) async { defaults.removeObject(forKey: "computerUse.lastDiagnostic.v1") }
}
@MainActor enum HostedConnectorSetup {
    static var active = false
    static func beginTeardown() async { active = true }
    static func endTeardown() { active = false }
}
@MainActor final class DirectMCPConnections {
    static let shared = DirectMCPConnections()
    var fail = false
    func removeAll() async throws { if fail { throw TestFailure.credentials } }
}
@MainActor final class CycleStore {
    static let shared = CycleStore()
    func wipeEverything() async {}
}
enum Diagnostics {
    enum Event { case cleanupFailed }
    enum Phase { case reset }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error) {}
    static func removeForCleanup(_ url: URL, phase: Phase, reason: String) {}
}
enum VaultGenerator { static let vaultRoot = URL(fileURLWithPath: "/unused-test-vault") }
enum ProactiveCycle { static func resetAll() {} }
enum OutlookCalendarToolPolicy { static let pendingDirectory = URL(fileURLWithPath: "/unused-test-pending") }
enum LifetimeStats { static func reset() {} }
@MainActor final class MirrorClient {
    static let shared = MirrorClient()
    func deleteRemote() async throws {}
}
enum CodexAuth {
    static let kbOnlyKey = "test.kbOnly"
    static let assertedPlusKey = "test.assertedPlus"
}
@MainActor final class AppState {
    static let onboardingKey = "hasCompletedOnboarding"
    var hasCompletedOnboarding = true
    var hasCompletedPersonalSetup = true
    var hasCompletedFirstSidekickTask = true
    var completedResets = 0
    func didResetPersonalData() {
        completedResets += 1
        hasCompletedPersonalSetup = false
        hasCompletedFirstSidekickTask = false
        hasCompletedOnboarding = false
    }
    let scheduler = Scheduler()
    let commandCoordinator = Coordinator()
    let processing = ProcessingCoordinator.shared
    @MainActor final class Coordinator {
        let run = Run()
        @MainActor final class Run {
            let conversation = SidekickConversation.shared
            func stop() {}
            func stopAndDrain() async -> Bool { true }
        }
    }
    final class Scheduler {
        var needsSchedulerSetup = true
        func reevaluate() {}
    }
}
enum ComputerUseGate { static let micSpeechOfferedKey = "test.micSpeechOffered" }
enum HealthCaution {
    static let nativeComputerUseEverReadyKey = "test.nativeComputerUseEverReady"
    static let computerUseEverReadyKey = "test.computerUseEverReady"
}
enum SidekickHistory { static func reset() {} }
enum OvernightScheduler {
    static let setupEnabledKey = "test.setupEnabled"
    static let firstCycleAtKey = "test.firstCycleAt"
    static let autoEnableFiredKey = "test.autoEnableFired"
    static let prodEnabledKey = "test.prodEnabled"
}
@MainActor final class ComputerUseUpgrade {
    static let shared = ComputerUseUpgrade()
    func reset() {}
}
func Log(_ message: String) {}
@MainActor final class SidekickConversation {
    static let shared = SidekickConversation()
    func beginMaintenance() -> Bool { true }
    func endMaintenance() {}
    func reset(defaults: UserDefaults) throws {}
    func drainBackgroundWork() async {}
}
@MainActor final class ProcessingCoordinator {
    static let shared = ProcessingCoordinator()
    func suspend() async {}
    func resumeMonitoring() {}
    func reset() async {}
}
enum SidekickDiagnostics {
    enum Stage { case reset }; enum Reason { case writeFailed, timeout }; enum Source { case reset }
    static func failure(_ stage: Stage, reason: Reason, source: Source) {}
}
enum DiagnosticHistory { static func reset(defaults: UserDefaults) {} }
enum SourceHealth { static let readStatusKey = "test.sourceHealth" }
enum AppleMailHealth { static let key = "test.mail"; static let needsRetryKey = "test.mailRetry" }
enum AppleCalendarSource { static let issueKey = "test.calendar" }
enum ProcessingPlan { static let key = "test.processing" }
enum PersonalSetupProgress {
    static func reset(defaults: UserDefaults) {
        defaults.removeObject(forKey: "onboarding.personalSetupCompleted")
        defaults.removeObject(forKey: "onboarding.firstSuccessfulSidekickTask")
    }
}
enum PermissionRelaunchDraft { static func clear() {} }
enum PermissionWaitDraft { static func clear() {} }
@MainActor final class NativePermissionCheck {
    static let shared = NativePermissionCheck()
    func close() async {}
}
enum SourceSelection { static let pendingProtectedSourceKey = "test.pendingProtectedSource" }
