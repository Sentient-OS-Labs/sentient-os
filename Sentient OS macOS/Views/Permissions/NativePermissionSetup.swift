// Records only the permission-setup workflow, never evidence of a macOS grant.
// A confirmed setup and a real relaunch permit a task to try, never a fabricated grant.
import Foundation
import Observation

@MainActor @Observable
final class NativePermissionSetup {
    static let shared = NativePermissionSetup()
    static let restartKey = "computerUse.nativePermissionRestartProcess"
    private static let confirmedKey = "computerUse.nativePermissionConfirmedProcess"
    private static let completedKey = "computerUse.nativePermissionSetupCompleted"
    private static let recoveryKey = "computerUse.nativePermissionRecoveryNeeded"
    private static let stepsKey = "computerUse.nativePermissionSteps.v1"
    enum Grant: String, CaseIterable { case accessibility, screenRecording }
    private struct Steps: Codable {
        var requested: [String: String] = [:]
        var dropped: [String: String] = [:]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let processID: String
    private(set) var restartProcess: String?
    private var confirmedProcess: String?
    private var completed: Bool
    private(set) var recoveryNeeded: Bool
    private(set) var dropped: Set<Grant> = []
    private var steps: Steps
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, processID: String = UUID().uuidString) {
        self.defaults = defaults
        self.processID = processID
        restartProcess = defaults.string(forKey: Self.restartKey)
        confirmedProcess = defaults.string(forKey: Self.confirmedKey)
        completed = defaults.bool(forKey: Self.completedKey)
        recoveryNeeded = defaults.bool(forKey: Self.recoveryKey)
        steps = defaults.data(forKey: Self.stepsKey)
            .flatMap { try? JSONDecoder().decode(Steps.self, from: $0) } ?? Steps()
        dropped = Set(steps.dropped.keys.compactMap(Grant.init(rawValue:)))
    }

    var hasRestarted: Bool { restartProcess.map { $0 != processID } ?? false }
    var needsRestart: Bool {
        if let restartProcess { return restartProcess == processID || !helperStepsVisited }
        if steps.requested.values.contains(processID) || steps.dropped.values.contains(processID) { return true }
        return !helperStepsVisited
    }

    private var previouslySetUp: Bool {
        completed || confirmedProcess != nil || defaults.bool(forKey: HealthCaution.nativeComputerUseEverReadyKey)
    }
    private var helperStepsVisited: Bool { Grant.allCases.allSatisfy(hasVisited) }

    func hasVisited(_ grant: Grant) -> Bool {
        previouslySetUp || steps.requested[grant.rawValue] != nil || steps.dropped[grant.rawValue] != nil
    }

    func stepNeedsRestart(_ grant: Grant) -> Bool {
        steps.requested[grant.rawValue] == processID || steps.dropped[grant.rawValue] == processID
            || (confirmedProcess == processID && !completed)
    }

    func stepIsApplied(_ grant: Grant) -> Bool { !recoveryNeeded && hasVisited(grant) && !stepNeedsRestart(grant) }

    func beganGrant(_ grant: Grant) {
        steps.requested[grant.rawValue] = processID
        saveSteps()
    }

    private func saveSteps() {
        if let data = try? JSONEncoder().encode(steps) { defaults.set(data, forKey: Self.stepsKey) }
    }

    var canAttemptTask: Bool { !needsRestart && !recoveryNeeded }

    /// Consume the restart receipt once the old helper has been safely retired. Later app
    /// launches reuse the completed workflow instead of restarting a healthy helper again.
    func preparedAfterRestart() {
        guard hasRestarted, canAttemptTask else { return }
        completed = true
        defaults.set(true, forKey: Self.completedKey)
        clearPending()
    }

    func didDrop(_ grant: Grant) {
        dropped.insert(grant)
        steps.dropped[grant.rawValue] = processID
        saveSteps()
    }

    func requestRestart() {
        generation = UUID()
        recoveryNeeded = false
        defaults.removeObject(forKey: Self.recoveryKey)
        restartProcess = processID
        confirmedProcess = nil
        defaults.set(processID, forKey: Self.restartKey)
        defaults.removeObject(forKey: Self.confirmedKey)
    }

    func confirmForRestart() {
        requestRestart()
        confirmedProcess = processID
        defaults.set(processID, forKey: Self.confirmedKey)
    }

    @discardableResult func permissionFailed() -> UUID {
        generation = UUID()
        recoveryNeeded = true
        defaults.set(true, forKey: Self.recoveryKey)
        return generation
    }

    /// A successful helper setup response completes the workflow, not a per-grant status API.
    func recovered(ifCurrent token: UUID) {
        guard generation == token else { return }
        completed = true
        defaults.set(true, forKey: Self.completedKey)
        clearPending()
    }

    private func clearPending() {
        generation = UUID()
        recoveryNeeded = false
        dropped.removeAll()
        steps = Steps()
        defaults.removeObject(forKey: Self.stepsKey)
        defaults.removeObject(forKey: Self.recoveryKey)
        defaults.removeObject(forKey: Self.confirmedKey)
        defaults.removeObject(forKey: Self.restartKey)
        confirmedProcess = nil
        restartProcess = nil
    }

    /// Called only after fresh native capability evidence was obtained.
    func verified() {
        defaults.set(true, forKey: HealthCaution.nativeComputerUseEverReadyKey)
        clearPending()
    }

    func reset() {
        clearPending()
        completed = false
        defaults.removeObject(forKey: Self.completedKey)
    }
}
