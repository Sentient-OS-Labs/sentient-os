// Owns current native capability evidence and serializes explicit readiness/Settings checks.
// check(), withSettingsProof() and close() cover admission through cleanup, including cached reads.
// Doc: Documentation - Permission Gate & Guide.md
import AppKit
import Observation

@MainActor @Observable final class NativePermissionCheck {
    static let shared = NativePermissionCheck()
    private init() {}

    private struct Proof {
        let id = UUID()
        let snapshot: NativePermissionReadiness.Snapshot
        let helper: NSRunningApplication
        let configuration: OpenAIComputerUse.Configuration
        let connection: OpenAIComputerUseSession
    }
    private enum Operation { case readiness, settings }
    private enum ProofStage: String { case helperStart, sessionOpen, helperIdentity, windowActivation, windowRead, commit }
    private var proof: Proof?
    private var failureSnapshot = NativePermissionReadiness.Snapshot()
    var snapshot: NativePermissionReadiness.Snapshot { proof?.snapshot ?? failureSnapshot }
    var proofID: UUID? { proof?.id }
    @ObservationIgnored private var activeCheck: Task<Void, Error>?
    private var activeCheckID: UUID?
    private var activeCheckEpoch: UUID?
    private var activeOperation: Operation?
    private var epoch = UUID()
    private var closeDepth = 0
    @ObservationIgnored private var closingConnections: [UUID: Task<Void, Never>] = [:]
    var isChecking: Bool { activeCheckID != nil }
    var isTearingDown: Bool { closeDepth > 0 }

    /// Passive observations never create evidence, capture a window or cancel a newer candidate.
    func refresh() {
        guard let proof else { return }
        if !identityIsCurrent(proof) { clearProof(ifCurrent: proof.id) }
    }

    func refresh(configuration: OpenAIComputerUse.Configuration, helper: NSRunningApplication) async {
        _ = await validateProof(configuration: configuration, helper: helper)
    }

    /// Configuration/helper lookup can itself suspend. Do not apply that older observation
    /// to evidence committed by a check while the lookup was in progress.
    func refresh(configuration: OpenAIComputerUse.Configuration, helper: NSRunningApplication,
                 observedProofID: UUID?) async {
        guard proof?.id == observedProofID else { return }
        _ = await validateProof(configuration: configuration, helper: helper)
    }

    private func identityIsCurrent(_ proof: Proof) -> Bool {
        !proof.helper.isTerminated
            && proof.helper.bundleURL?.standardizedFileURL == proof.configuration.appURL.standardizedFileURL
            && proof.configuration.appURL == OpenAIComputerUse.appURL
            && OpenAIComputerUse.installation(at: proof.configuration.appURL) != nil
    }

    private func validateProof(configuration: OpenAIComputerUse.Configuration,
                               helper: NSRunningApplication) async -> Bool {
        refresh()
        guard let examined = proof else { return false }
        guard examined.configuration == configuration,
              examined.helper.processIdentifier == helper.processIdentifier else {
            clearProof(ifCurrent: examined.id); return false
        }
        let usable = await examined.connection.isUsable()
        // Another operation can replace or retire this record while liveness is suspended.
        guard proof?.id == examined.id else { return false }
        guard usable, identityIsCurrent(examined), !helper.isTerminated else {
            clearProof(ifCurrent: examined.id); return false
        }
        return true
    }

    /// Explicit permission evidence and teardown invalidate admitted work as well as old proof.
    func invalidate(failure: NativeComputerUseFailure? = nil) {
        epoch = UUID()
        activeCheck?.cancel()
        clearProof(failure: failure)
    }

    private func clearProof(ifCurrent id: UUID? = nil, failure: NativeComputerUseFailure? = nil) {
        if let id, proof?.id != id { return }
        if let failure, failure.requiresSystemPermissionSetup { NativePermissionSetup.shared.permissionFailed() }
        let previous = proof?.connection
        proof = nil
        failureSnapshot = NativePermissionReadiness.afterFailure(failure)
        retire(previous)
    }

    private func retire(_ connection: OpenAIComputerUseSession?) {
        guard let connection else { return }
        let id = UUID()
        closingConnections[id] = Task {
            await connection.close()
            closingConnections[id] = nil
        }
    }

    private func drainRetiredConnections() async {
        while !closingConnections.isEmpty {
            for closing in Array(closingConnections.values) { await closing.value }
        }
    }

    func close() async {
        closeDepth += 1
        defer { closeDepth -= 1 }
        epoch = UUID()
        let checking = activeCheck
        checking?.cancel()
        _ = await checking?.result
        clearProof()
        await drainRetiredConnections()
    }

    /// Reset/uninstall hold admission closed through all subsequent filesystem/defaults work.
    /// A plain close only drains work that was already admitted.
    func beginTeardown() async {
        closeDepth += 1
        await close()
    }

    func endTeardown() {
        precondition(closeDepth > 0)
        closeDepth -= 1
    }

    /// The operation is registered before its first await, including the cached-proof path.
    /// Additional waiters can leave without cancelling the check's original owner.
    func check(configuration: OpenAIComputerUse.Configuration, helper: NSRunningApplication,
               useHelperSetup: Bool = false) async throws {
        try Task.checkCancellation()
        let admittedEpoch = epoch
        var selectedHelper = helper
        while let checking = activeCheck, let id = activeCheckID {
            let wasSettings = activeOperation == .settings
            try await wait(for: checking, id: id, owns: false)
            try ensureAdmission(admittedEpoch)
            // Settings may have repaired/replaced the helper while this caller was waiting.
            if wasSettings, let proof, proof.configuration == configuration { selectedHelper = proof.helper }
        }
        try ensureAdmission(admittedEpoch)
        let id = UUID()
        let task = startOperation(id: id, kind: .readiness, epoch: admittedEpoch) { [self, selectedHelper] in
            // A caller can have waited with a handle retired by Settings or another check.
            // Resolve its replacement only after registering this operation for teardown.
            let currentHelper = selectedHelper.isTerminated
                ? try await OpenAIComputerUseRuntime.shared.start(configuration: configuration)
                : selectedHelper
            try ensureOperation(id)
            // Repair is an explicit fresh check. A cached successful connection cannot tell
            // whether macOS permissions were revoked since the last read.
            var ready = false
            if !useHelperSetup { ready = await validateProof(configuration: configuration, helper: currentHelper) }
            try ensureOperation(id)
            if ready { return }
            try await performCheck(configuration: configuration, attempt: id, useHelperSetup: useHelperSetup)
        }
        try await wait(for: task, id: id, owns: true)
        try ensureAdmission(admittedEpoch)
    }

    /// Settings supplies its own diagnostic reservation and session. Agent-owned sessions never
    /// enter this method. Cancelling a candidate leaves an otherwise valid committed proof intact.
    func withSettingsProof(_ operation: @escaping @MainActor (UUID) async throws -> Void) async throws {
        try Task.checkCancellation()
        let admittedEpoch = epoch
        while let checking = activeCheck, let id = activeCheckID {
            // A failed ordinary check is a reason to run the explicit diagnostic, not skip it.
            do { try await wait(for: checking, id: id, owns: false) }
            catch { try Task.checkCancellation() }
            try ensureAdmission(admittedEpoch)
        }
        try ensureAdmission(admittedEpoch)
        let id = UUID()
        let task = startOperation(id: id, kind: .settings, epoch: admittedEpoch) { [self] in
            await drainRetiredConnections()
            try ensureOperation(id, kind: .settings)
            try await operation(id)
        }
        try await wait(for: task, id: id, owns: true)
        try ensureAdmission(admittedEpoch)
    }

    func retireProofForRepair(attempt: UUID) async throws {
        try ensureOperation(attempt, kind: .settings)
        clearProof()
        await drainRetiredConnections()
        try ensureOperation(attempt, kind: .settings)
    }

    func recordSettingsFailure(attempt: UUID, failure: NativeComputerUseFailure) throws {
        try ensureOperation(attempt, kind: .settings)
        if failure.kind == .permission { clearProof(failure: failure) }
    }

    /// On success the caller relinquishes its session. On failure it still owns cleanup.
    func adoptSettingsProof(attempt: UUID, evidence: NativePermissionReadiness.Evidence,
                            configuration: OpenAIComputerUse.Configuration, helper: NSRunningApplication,
                            session: OpenAIComputerUseSession) async throws {
        try ensureOperation(attempt, kind: .settings)
        let usable = await session.isUsable()
        try ensureOperation(attempt, kind: .settings)
        let candidate = Proof(snapshot: evidence.snapshot, helper: helper,
                              configuration: configuration, connection: session)
        guard usable, identityIsCurrent(candidate) else { throw OpenAIComputerUse.RuntimeError.backendUnavailable }
        publish(candidate)
    }

    private func publish(_ candidate: Proof) {
        NativePermissionSetup.shared.verified()
        let previous = proof?.connection
        proof = candidate
        failureSnapshot = .init()
        if let previous, previous !== candidate.connection { retire(previous) }
    }

    private func ensureAdmission(_ admittedEpoch: UUID) throws {
        try Task.checkCancellation()
        guard closeDepth == 0, epoch == admittedEpoch else { throw CancellationError() }
    }

    private func ensureOperation(_ id: UUID, kind: Operation? = nil) throws {
        try Task.checkCancellation()
        guard closeDepth == 0, activeCheckID == id, activeCheckEpoch == epoch,
              kind == nil || activeOperation == kind else { throw CancellationError() }
    }

    private func startOperation(id: UUID, kind: Operation, epoch admittedEpoch: UUID,
                                body: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let task = Task { @MainActor in
            defer {
                if activeCheckID == id {
                    activeCheck = nil; activeCheckID = nil; activeCheckEpoch = nil; activeOperation = nil
                }
            }
            try ensureOperation(id)
            try await body()
            try ensureOperation(id)
        }
        activeCheckID = id; activeCheckEpoch = admittedEpoch; activeOperation = kind; activeCheck = task
        return task
    }

    private func wait(for task: Task<Void, Error>, id: UUID, owns: Bool) async throws {
        if owns {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: { task.cancel() }
        } else {
            // Task.value does not release a cancelled observer. This cancellable wait observes
            // only operation completion and never creates another native request or window.
            while activeCheckID == id { try await Task.sleep(for: .milliseconds(25)) }
            try Task.checkCancellation()
            try await task.value
        }
    }

    private func recordProofStage(_ stage: ProofStage, began: Date, error: Error? = nil,
                                  helperStable: Bool? = nil) {
        var fields = ["stage": stage.rawValue,
            "outcome": error == nil ? "passed" : (error is CancellationError || Task.isCancelled ? "cancelled" : "failed"),
            "elapsed_ms": String(Int(min(600_000, max(0, Date().timeIntervalSince(began) * 1000)))),
            "helper_build": String(CodexRuntime.release.helperBuild)]
        if let helperStable { fields["helper_identity_stable"] = String(helperStable) }
        if let failure = error as? NativeComputerUseFailure {
            fields["native_kind"] = failure.kind.rawValue
            fields["native_detail"] = failure.detail.rawValue
            fields["failure_stage"] = failure.stage.rawValue
        }
        Analytics.signal("ComputerUse.permissionProofStage", parameters: fields)
    }

    private func performCheck(configuration supplied: OpenAIComputerUse.Configuration, attempt: UUID,
                              useHelperSetup: Bool) async throws {
        try ensureOperation(attempt)
        let runtime = OpenAIComputerUseRuntime.shared
        guard let reservation = runtime.reserveDiagnostic() else { throw OpenAIComputerUse.RuntimeError.helperRunning }
        defer { runtime.endDiagnostic(reservation) }
        clearProof()
        // Last-client teardown can retire the helper. Select the next helper only after all
        // previous clients have drained, never bind a new successful read to the old handle.
        await drainRetiredConnections()
        try ensureOperation(attempt)
        let lease = try await CodexRuntime.sharedRuntimeLease()
        defer { lease.unlock() }
        let configuration = try supplied.afterRuntimeLease()
        _ = try await OpenAIComputerUse.validate(at: configuration.appURL)
        try ensureOperation(attempt)
        var setupDeadline: TimeInterval?
        // One initial connection, one startup replacement, and one grant-driven relaunch.
        // Only the helper's read-only setup request can retry across that relaunch.
        for startupAttempt in 0..<3 {
            var opened: OpenAIComputerUseSession?
            var stage = ProofStage.helperStart
            var began = Date()
            var helperStable: Bool?
            do {
                let helper = try await runtime.start(configuration: configuration)
                try ensureOperation(attempt)
                recordProofStage(stage, began: began)
                stage = .sessionOpen; began = Date()
                let session = try await OpenAIComputerUseSession.open(configuration)
                opened = session
                recordProofStage(stage, began: began)
                stage = .helperIdentity; began = Date()
                let current = try await runtime.start(configuration: configuration)
                try ensureOperation(attempt)
                helperStable = !helper.isTerminated && helper.processIdentifier == current.processIdentifier
                guard !helper.isTerminated, helper.processIdentifier == current.processIdentifier else {
                    await session.close(); opened = nil
                    if startupAttempt == 0 {
                        recordProofStage(stage, began: began, error: OpenAIComputerUse.RuntimeError.backendUnavailable, helperStable: false)
                        continue
                    }
                    throw OpenAIComputerUse.RuntimeError.backendUnavailable
                }
                recordProofStage(stage, began: began, helperStable: helperStable)
                let result: NativePermissionReadiness.Snapshot
                if useHelperSetup {
                    stage = .windowRead; began = Date()
                    let deadline = setupDeadline
                        ?? (ProcessInfo.processInfo.systemUptime + OpenAIComputerUseSession.permissionSetupTimeout)
                    setupDeadline = deadline
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else {
                        throw NativeComputerUseFailure(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .probe)
                    }
                    result = try await NativeHelperPermissionNote.withGuide(appURL: configuration.appURL) {
                        try await NativePermissionReadiness.helperSetup { tool, arguments in
                            try await session.call(tool, arguments: arguments, timeout: remaining)
                        }
                    }
                } else {
                    stage = .windowActivation; began = Date()
                    let panel = NativePermissionCheckWindow()
                    panel.show()
                    defer { panel.close() }
                    try await panel.waitUntilCurrent()
                    recordProofStage(stage, began: began)
                    stage = .windowRead; began = Date()
                    let helperBuild = CodexRuntime.release.helperBuild
                    result = try await NativePermissionReadiness.verify(app: Bundle.main.bundleURL.path,
                        marker: panel.marker, isCurrent: { panel.isCurrent }, observe: { observation in
                            // The value contains only enums, bounded counts and booleans. The task
                            // emits analytics only and never participates in readiness ownership.
                            Task { @MainActor in
                                var fields = ["read_index": String(observation.readIndex),
                                    "elapsed_ms": String(observation.elapsedMilliseconds),
                                    "marker_observed": String(observation.markerObserved),
                                    "capture_validated": String(observation.captureValidated),
                                    "outcome": observation.outcome.rawValue,
                                    "helper_build": String(helperBuild)]
                                if let current = observation.beforeCurrent { fields["window_current_before"] = String(current) }
                                if let current = observation.afterCurrent { fields["window_current_after"] = String(current) }
                                if let detail = observation.detail { fields["detail"] = detail.rawValue }
                                Analytics.signal("ComputerUse.permissionProofRead", parameters: fields)
                            }
                        }, timedCall: { tool, arguments, remaining in
                            try await session.call(tool, arguments: arguments, timeout: remaining)
                        })
                }
                recordProofStage(stage, began: began)
                stage = .commit; began = Date()
                let usable = await session.isUsable()
                try ensureOperation(attempt)
                let candidate = Proof(snapshot: result, helper: helper, configuration: configuration, connection: session)
                helperStable = identityIsCurrent(candidate)
                guard usable, helperStable == true else { throw OpenAIComputerUse.RuntimeError.backendUnavailable }
                publish(candidate)
                recordProofStage(stage, began: began, helperStable: true)
                return
            } catch {
                recordProofStage(stage, began: began, error: error, helperStable: helperStable)
                if let failure = error as? NativeComputerUseFailure {
                    NativeComputerUseErrorLog.record(tool: "permission_setup", failure: failure)
                }
                await opened?.close()
                let canReconnect = (error as? NativeComputerUseFailure)?.permitsSessionRecovery == true
                    || (error as? OpenAIComputerUse.RuntimeError) == .backendUnavailable
                if useHelperSetup, startupAttempt < 2, canReconnect,
                   setupDeadline.map({ $0 > ProcessInfo.processInfo.systemUptime }) == true {
                    try ensureOperation(attempt)
                    continue
                }
                if activeCheckID == attempt, activeCheckEpoch == epoch {
                    clearProof(failure: error as? NativeComputerUseFailure)
                }
                throw error
            }
        }
    }
}
