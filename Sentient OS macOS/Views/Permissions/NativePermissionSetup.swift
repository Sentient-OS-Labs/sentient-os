// Remembers successful native setup, solely to avoid an extra setup request on later tasks.
// The helper owns the actual macOS grants and can request them again on any native operation.
import Foundation
import Observation

@MainActor @Observable
final class NativePermissionSetup {
    static let shared = NativePermissionSetup()
    private static let completedKey = "computerUse.nativeHelperSetupCompleted.v2"
    private static let recoveryKey = "computerUse.nativeHelperRecoveryNeeded.v2"
    @ObservationIgnored private let defaults: UserDefaults
    private var completed: Bool
    private(set) var recoveryNeeded: Bool
    private var generation = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        completed = defaults.bool(forKey: Self.completedKey)
        recoveryNeeded = defaults.bool(forKey: Self.recoveryKey)
    }

    /// This is permission to attempt a task, not a cached claim about individual grants.
    var canAttemptTask: Bool { completed && !recoveryNeeded }

    @discardableResult func permissionFailed() -> UUID {
        generation = UUID()
        recoveryNeeded = true
        defaults.set(true, forKey: Self.recoveryKey)
        return generation
    }

    func recovered(ifCurrent token: UUID) {
        guard generation == token else { return }
        verified()
    }

    /// Called only after an actual successful helper operation or capability diagnostic.
    func verified() {
        generation = UUID()
        completed = true
        recoveryNeeded = false
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.recoveryKey)
        defaults.set(true, forKey: HealthCaution.nativeComputerUseEverReadyKey)
    }

    func reset() {
        generation = UUID()
        completed = false
        recoveryNeeded = false
        for key in [Self.completedKey, Self.recoveryKey,
                    "computerUse.nativePermissionRestartProcess", "computerUse.nativePermissionConfirmedProcess",
                    "computerUse.nativePermissionSetupCompleted", "computerUse.nativePermissionRecoveryNeeded",
                    "computerUse.nativePermissionSteps.v1"] {
            defaults.removeObject(forKey: key)
        }
    }
}
