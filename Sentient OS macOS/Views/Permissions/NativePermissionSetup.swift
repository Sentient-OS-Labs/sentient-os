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
    enum Grant: String { case accessibility, screenRecording }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let processID: String
    private(set) var restartProcess: String?
    private var confirmedProcess: String?
    private var completed: Bool
    private(set) var recoveryNeeded: Bool
    private(set) var dropped: Set<Grant> = []
    private var generation = UUID()

    init(defaults: UserDefaults = .standard, processID: String = UUID().uuidString) {
        self.defaults = defaults
        self.processID = processID
        restartProcess = defaults.string(forKey: Self.restartKey)
        confirmedProcess = defaults.string(forKey: Self.confirmedKey)
        completed = defaults.bool(forKey: Self.completedKey)
        recoveryNeeded = defaults.bool(forKey: Self.recoveryKey)
    }

    var hasRestarted: Bool { restartProcess.map { $0 != processID } ?? false }
    var needsRestart: Bool {
        if let restartProcess { return restartProcess == processID || confirmedProcess != restartProcess }
        return !completed && !defaults.bool(forKey: HealthCaution.nativeComputerUseEverReadyKey)
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

    func didDrop(_ grant: Grant) { dropped.insert(grant) }

    func requestRestart() {
        generation = UUID()
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
