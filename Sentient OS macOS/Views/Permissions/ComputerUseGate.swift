// Holds user-fired tasks only for Sentient's own required grants.
// Native helper requests own their consent when a task uses a computer tool; voice is optional.
// Key methods: intercept(), refresh(), requestAutomation(), continueNow().
// Doc: Documentation - Permission Gate & Guide.md

import AppKit
import AVFoundation
import SwiftUI

@MainActor
@Observable
final class ComputerUseGate {

    static let shared = ComputerUseGate()
    private init() {}

    // MARK: Grant status (probed, not cached beyond the last refresh)

    /// Sentient's mic + speech recognition — Sidekick's ears. OPTIONAL: without it, the notch's mic
    /// stays off (a click on it flashes the mic notice); typed commands are untouched. Detail
    /// preserved for the fix action.
    enum MicSpeechState { case granted, notAsked, denied }
    private(set) var micSpeech: MicSpeechState = .notAsked

    /// The Microphone row's hover tip — one string for the gate window and Settings → Health.
    static let micSpeechTip = PrivacyCopy.voiceInput

    /// Sentient's own Screen Recording — the cua driver's EYES (per-window screenshots) and the
    /// screen-context snapshot at fire time, since the driver runs inside Sentient's TCC chain and
    /// captures windows as us.
    private(set) var sentientScreen = false

    /// Sentient's own Accessibility — the cua driver's HANDS: every AX read and every background
    /// click the driver makes is answered with Sentient's grant, because Sentient is the
    /// responsible app in the chain that spawned it.
    private(set) var sentientAccessibility = false

    /// The selected runtime's grants are separate from optional voice access.
    private(set) var backend = ComputerUseBackend.current
    var helperAccessibility: Bool { helperPermissionState.accessibility == .verified }
    var helperScreen: Bool { helperPermissionState.screenRecording == .verified }
    var helperPermissionState: NativePermissionReadiness.Snapshot {
        NativePermissionCheck.shared.snapshot
    }
    private(set) var showingVoiceRepair = false
    private(set) var automation: Permissions.AutomationState = .unavailable
    var needsAutomation: Bool {
        backend == .openAI && (automation == .notAsked || automation == .denied)
    }
    private(set) var requestingAutomation = false
    private(set) var checkingAutomation = false
    private enum CheckStage: String { case runtime, automation, capability }
    private enum CheckEntryPoint: String {
        case passive, explicitCheck = "explicit_check", restart
    }
    private enum CheckOutcome: String { case success, blocked, failure, cancelled, stale }
    private enum CheckReason: String {
        case automationGranted = "automation_granted", capabilityVerified = "capability_verified"
        case automationNotAsked = "automation_not_asked", automationDenied = "automation_denied"
        case automationUnavailable = "automation_unavailable", cancelled, superseded
        case runtimeError = "runtime_error", nativeError = "native_error", otherError = "other_error"
    }
    private struct CheckFailure {
        let message: String
        var restartRequired = false
        let proofID: UUID?
    }
    private var runtimeFailure: CheckFailure?
    private var automationFailure: CheckFailure?
    private var capabilityFailure: CheckFailure?
    /// A newer committed proof (including a Settings diagnostic) supersedes only the failed
    /// capability attempt. Runtime and Automation failures have independent recovery paths.
    private var unresolvedCapabilityFailure: CheckFailure? {
        guard let failure = capabilityFailure else { return nil }
        if helperPermissionState.isReady, let proofID = NativePermissionCheck.shared.proofID,
           proofID != failure.proofID { return nil }
        return failure
    }
    var nativePermissionError: String? {
        runtimeFailure?.message ?? automationFailure?.message ?? unresolvedCapabilityFailure?.message
    }
    var capabilityCheckFailed: Bool { unresolvedCapabilityFailure != nil }
    /// A competing helper is a recoverable startup condition, not missing permission.
    private var nativeHelperConflict = false
    var nativeRestartRequired: Bool { runtimeFailure?.restartRequired == true }
    private(set) var restartingNative = false
    private(set) var checkingCapabilities = false
    private(set) var nativeRepairSucceeded = false
    /// Grant actions reveal Restart; completing the drag enables it.
    enum PermissionAction { case sentientScreen }
    private var permissionActions: Set<PermissionAction> = []
    private var completedPermissionDrags: Set<PermissionAction> = []
    private var ownsPermissionRelaunch = false
    private var teardownDepth = 0
    @ObservationIgnored private var nativeOperationID = UUID()
    @ObservationIgnored private var automationProbeID: UUID?
    @ObservationIgnored private var permissionRequestID: UUID?
    @ObservationIgnored private var automationProbe: Task<Void, Never>?
    @ObservationIgnored private var permissionRequest: Task<Void, Never>?
    @ObservationIgnored private var lastAutomationProbe: Date?
    var setup: ComputerUseSetup { .instance(for: backend) }

    /// Only Sentient's own capture grant can require a host-app restart here.
    var requiresPermissionRestart: Bool {
        backend == .openAI && permissionActions.contains(.sentientScreen) && !sentientScreen
    }

    var canRestartAfterPermissions: Bool {
        requiresPermissionRestart && completedPermissionDrags.contains(.sentientScreen)
            && !requestingAutomation && !checkingCapabilities
            && (SafeAppRelaunch.shared.canRelaunchPermissionWait || SafeAppRelaunch.shared.canRelaunch)
    }

    func beganPermissionAction(_ action: PermissionAction) {
        guard teardownDepth == 0, backend == .openAI else { return }
        permissionActions.insert(action)
        completedPermissionDrags.remove(action)
    }

    func completedPermissionDrag(_ action: PermissionAction) {
        guard teardownDepth == 0, backend == .openAI, permissionActions.contains(action) else { return }
        completedPermissionDrags.insert(action)
    }

    var hasWaitingAction: Bool { pending != nil }

    /// Explicitly leave an external/preparing task when it cannot be preserved as a draft.
    /// This only cancels the gate's waiter; it cannot interrupt an admitted computer task.
    func stopWaitingAction() { cancelPendingAction() }

    func restartAfterPermissions() {
        guard teardownDepth == 0, requiresPermissionRestart, canRestartAfterPermissions else { return }
        let relaunch = SafeAppRelaunch.shared
        ownsPermissionRelaunch = true
        let accepted = relaunch.canRelaunchPermissionWait
            ? relaunch.relaunchPermissionWait() : relaunch.relaunchPreservingDraft()
        if !accepted { ownsPermissionRelaunch = false }
    }

    /// Synchronous grants and installation state. A service starting in the background is not
    /// evidence that these permissions need to be granted again.
    private var nativeInstallationReady: Bool {
        CodexSetup.shared.computerUseReady && setup.ready && backend.isInstalled
    }
    private var localRequirementsReady: Bool {
        guard sentientScreen else { return false }
        switch backend {
        case .cua:
            // Preserve CUA's existing first-use flow. Its task runner joins any background
            // installation before starting the daemon; the permission gate checks the grants.
            return sentientAccessibility
        case .openAI:
            return nativeInstallationReady && helperAccessibility && helperScreen
        }
    }

    var allRequiredGranted: Bool {
        teardownDepth == 0 && localRequirementsReady && (backend == .cua || (automation == .granted && nativePermissionError == nil && !nativeHelperConflict))
    }

    /// Chat admission depends only on Sentient's own grants. A greeting must not require
    /// native computer control; actual native requests enforce the helper's permissions.
    var isReadyForTask: Bool {
        if backend == .cua { return allRequiredGranted }
        return teardownDepth == 0 && sentientScreen && !needsAutomation
    }

    /// The runtime calls this after starting the owned helper. Only an explicit macOS
    /// missing-grant result opens setup; an unavailable observation permits the real request.
    func waitForNativeAutomation(observed state: Permissions.AutomationState) async throws {
        try Task.checkCancellation()
        guard teardownDepth == 0 else { throw CancellationError() }
        refreshGrants()
        guard backend == .openAI else { return }
        automation = state
        guard needsAutomation else { return }
        try await waitUntilReady()
    }

    /// Reset and uninstall close admission before draining work. A permission request can be
    /// suspended in installation or Automation before the shared proof owner sees it, so the
    /// gate must drain its producers as well as cancelling the held task.
    func beginTeardown() async {
        teardownDepth += 1
        permissionActions.removeAll()
        completedPermissionDrags.removeAll()
        nativeRepairSucceeded = false
        nativeOperationID = UUID()
        checkingCapabilities = false
        let request = permissionRequest
        let probe = automationProbe
        request?.cancel(); probe?.cancel()
        cancelPendingAction()
        dismissWindow()
        await request?.value
        await probe?.value
    }

    func endTeardown() {
        guard teardownDepth > 0 else { return }
        teardownDepth -= 1
    }

    func requestAutomation() {
        if automation == .denied {
            Permissions.openAutomationSettings()
            return
        }
        requestNativeAccess(ask: true, verifyCapabilities: false)
    }

    func verifyNativePermissions() {
        guard sentientScreen else { return }
        requestNativeAccess(ask: false, verifyCapabilities: true)
    }

    /// Settings repair is explicit and cannot depend on an unqueryable helper-grant cache.
    func fixNativePermissions() {
        refreshGrants()
        requestNativeAccess(ask: true, verifyCapabilities: true, explicitRepair: true)
    }

    /// Opening Settings only refreshes transport/Automation observations. Native setup is
    /// user initiated, so visiting Settings cannot unexpectedly open another app's window.
    func checkNativePermissionsIfNeeded() async {
        refreshAutomation()
        await awaitAutomationRefresh()
    }

    private func requestNativeAccess(ask: Bool, verifyCapabilities: Bool, explicitRepair: Bool = false) {
        guard teardownDepth == 0, backend == .openAI, setup.ready, !requestingAutomation else { return }
        let id = beginNativeOperation()
        permissionRequestID = id
        requestingAutomation = true
        if explicitRepair { nativeRepairSucceeded = false }
        if verifyCapabilities { capabilityFailure = nil }
        permissionRequest = Task {
            defer { finishPermissionRequest(id) }
            do {
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                try requireCurrentOperation(id)
                guard await ComputerUseSetup.instance(for: .openAI).ensureInstalled() else {
                    throw OpenAIComputerUse.RuntimeError.incomplete
                }
                try requireCurrentOperation(id)
                _ = await automationProbe?.value
                try requireCurrentOperation(id)
                try await checkNativeAccess(ask: ask, configuration: configuration,
                                            stoppingConflictingHelpers: verifyCapabilities,
                                            verifyCapabilities: verifyCapabilities,
                                            explicitRepair: explicitRepair,
                                            operationID: id, entryPoint: .explicitCheck)
                if explicitRepair { nativeRepairSucceeded = NativePermissionSetup.shared.canAttemptTask && automation == .granted }
                finishPermissionRequest(id)
                refresh()
                if explicitRepair, nativeRepairSucceeded, isReadyForTask, let action = pending {
                    pending = nil
                    dismissWindow()
                    action.proceed()
                }
            } catch {
                recordNativeFailure(error, operationID: id)
            }
        }
    }

    /// Explicit recovery for an existing helper with stale startup settings. The runtime checks
    /// that Sentient is idle and never force-kills or stops a different installed helper bundle.
    func restartComputerUse() {
        guard teardownDepth == 0, backend == .openAI, !requestingAutomation, !restartingNative else { return }
        let id = beginNativeOperation()
        permissionRequestID = id
        requestingAutomation = true
        restartingNative = true
        permissionRequest = Task {
            defer { finishPermissionRequest(id) }
            _ = await automationProbe?.value
            do {
                try requireCurrentOperation(id)
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                try requireCurrentOperation(id)
                await NativePermissionCheck.shared.close()
                try requireCurrentOperation(id)
                try await OpenAIComputerUseRuntime.shared.restart(configuration: configuration)
                try requireCurrentOperation(id)
                try await checkNativeAccess(ask: true, configuration: configuration,
                                            verifyCapabilities: false,
                                            operationID: id, entryPoint: .restart)
            } catch { recordNativeFailure(error, operationID: id) }
        }
    }

    private func beginNativeOperation() -> UUID {
        let id = UUID(); nativeOperationID = id
        checkingCapabilities = false
        return id
    }

    private func requireCurrentOperation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard teardownDepth == 0, nativeOperationID == id, backend == .openAI else { throw CancellationError() }
    }

    private func finishPermissionRequest(_ id: UUID) {
        guard permissionRequestID == id else { return }
        permissionRequestID = nil; permissionRequest = nil
        requestingAutomation = false; restartingNative = false; lastAutomationProbe = Date()
    }

    private struct AccessFailure: Error {
        let underlying: Error
        let stage: CheckStage
        let proofID: UUID?
    }

    private func checkNativeAccess(ask: Bool, configuration supplied: OpenAIComputerUse.Configuration? = nil,
                                   stoppingConflictingHelpers: Bool = false, verifyCapabilities: Bool = false,
                                   explicitRepair: Bool = false,
                                   operationID id: UUID, entryPoint: CheckEntryPoint) async throws {
        var stage = CheckStage.runtime
        var proofID = NativePermissionCheck.shared.proofID
        let started = Date()
        var outcome = CheckOutcome.success
        var reason = CheckReason.automationGranted
        var nativeFailure: NativeComputerUseFailure?
        let capabilityRequested = verifyCapabilities && (explicitRepair || sentientScreen)
        Analytics.signal("PermissionGate.nativeCheckStarted", parameters: [
            "entry_point": entryPoint.rawValue, "stage": stage.rawValue,
            "capability_requested": String(capabilityRequested), "proof_present": String(proofID != nil)
        ], tier: .extended)
        defer {
            // Counts and closed categories only. In particular, a passive success says that
            // Automation was checked; it never claims a successful capability proof.
            var fields = ["entry_point": entryPoint.rawValue, "stage": stage.rawValue,
                "outcome": outcome.rawValue, "reason": reason.rawValue,
                "capability_requested": String(capabilityRequested),
                "proof_present": String(NativePermissionCheck.shared.proofID != nil),
                "elapsed_ms": String(Int(min(600_000, max(0, Date().timeIntervalSince(started) * 1_000))))]
            if let nativeFailure {
                fields["native_kind"] = nativeFailure.kind.rawValue
                fields["native_detail"] = nativeFailure.detail.rawValue
                fields["failure_stage"] = nativeFailure.stage.rawValue
                if let code = nativeFailure.code { fields["native_error_code"] = String(code) }
                if let code = nativeFailure.rpcCode { fields["rpc_error_code"] = String(code) }
            }
            Analytics.signal("PermissionGate.nativeCheckFinished", parameters: fields, tier: .extended)
        }
        do {
            try requireCurrentOperation(id)
            let configuration: OpenAIComputerUse.Configuration
            if let supplied { configuration = supplied }
            else { configuration = try await OpenAIComputerUse.Configuration.resolveForSetup() }
            try requireCurrentOperation(id)
            let helper = try await OpenAIComputerUseRuntime.shared.start(configuration: configuration,
                stoppingConflictingHelpers: ask || stoppingConflictingHelpers)
            try requireCurrentOperation(id)
            await NativePermissionCheck.shared.refresh(configuration: configuration, helper: helper,
                                                        observedProofID: proofID)
            try requireCurrentOperation(id)
            nativeHelperConflict = false; runtimeFailure = nil
            stage = .automation
            let state = await Permissions.nativeAutomationState(ask: ask)
            try requireCurrentOperation(id)
            automation = state
            automationFailure = state == .unavailable
                ? CheckFailure(message: "The macOS Automation permission could not be checked. Try again.", proofID: nil) : nil
            guard state == .granted else {
                outcome = .blocked
                switch state {
                case .notAsked: reason = .automationNotAsked
                case .denied: reason = .automationDenied
                case .unavailable: reason = .automationUnavailable
                case .granted: break
                }
                return
            }
            // Passive refresh validates existing evidence but never manufactures a capability
            // success or clears its failure merely because Automation is granted.
            if capabilityRequested {
                stage = .capability
                proofID = NativePermissionCheck.shared.proofID
                checkingCapabilities = true
                defer { if nativeOperationID == id { checkingCapabilities = false } }
                try await NativePermissionCheck.shared.check(configuration: configuration, helper: helper, useHelperSetup: true)
                try requireCurrentOperation(id)
                guard NativePermissionSetup.shared.canAttemptTask, NativePermissionCheck.shared.proofID != nil else {
                    throw CancellationError()
                }
                capabilityFailure = nil
                NativePermissionSetup.shared.verified()
                reason = .capabilityVerified
            }
        } catch {
            if Task.isCancelled {
                outcome = .cancelled; reason = .cancelled
            } else if nativeOperationID != id || teardownDepth > 0 || backend != .openAI {
                outcome = .stale; reason = .superseded
            } else if error is CancellationError {
                outcome = .cancelled; reason = .cancelled
            } else {
                outcome = .failure
                nativeFailure = error as? NativeComputerUseFailure
                reason = nativeFailure != nil ? .nativeError
                    : (error is OpenAIComputerUse.RuntimeError ? .runtimeError : .otherError)
            }
            throw AccessFailure(underlying: error, stage: stage, proofID: proofID)
        }
    }

    private func recordNativeFailure(_ error: Error, operationID id: UUID, passive: Bool = false) {
        let scoped = error as? AccessFailure
        let error = scoped?.underlying ?? error
        guard !Task.isCancelled, !(error is CancellationError), nativeOperationID == id else { return }
        OpenAIComputerUseRuntime.shared.invalidate()
        let failure = error as? OpenAIComputerUse.RuntimeError
        if failure == .conflictingHelper && passive {
            nativeHelperConflict = true
            runtimeFailure = nil
            return
        }
        nativeHelperConflict = false
        let message = (error as? NativeComputerUseFailure)?.isReadinessInterruption == true
            ? "Computer-use setup was interrupted. Open the helper’s setup to continue."
            : error.localizedDescription
        let recorded = CheckFailure(message: message,
            restartRequired: failure == .restartRequired || failure == .backendUnavailable,
            proofID: scoped?.proofID)
        switch scoped?.stage ?? .runtime {
        case .runtime: runtimeFailure = recorded
        case .automation: automationFailure = recorded
        case .capability: capabilityFailure = recorded
        }
        if !Diagnostics.isExpected(error) {
            Diagnostics.report(.readinessFailed, phase: .probe, error: error)
        }
    }

    // MARK: The gate

    /// Legacy key retained so Factory Reset can remove it. Typed computer use never offers voice.
    static let micSpeechOfferedKey = "computerUse.micSpeechOffered"

    private struct PendingAction {
        let id: UUID
        let proceed: @MainActor () -> Void
        let cancel: @MainActor () -> Void
    }
    private var pending: PendingAction?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    var isPresenting: Bool { window != nil }

    /// Closing required setup is distinct from cancelling the owning task.
    nonisolated struct SetupCancelled: Error {}

    /// The request already owns the notch and the one-task lock while waiting here. Closing a
    /// blocking setup or pressing STOP releases it; no late permission result can revive it.
    func waitUntilReady() async throws {
        guard teardownDepth == 0 else { throw CancellationError() }
        while setup.isInstalling {
            try await Task.sleep(for: .milliseconds(100))
            guard teardownDepth == 0 else { throw CancellationError() }
        }
        try Task.checkCancellation()
        // Revisit a previous denial before displaying setup on a new request.
        // The user may have granted access directly in System Settings meanwhile.
        if needsAutomation {
            refreshAutomation(force: true)
            await awaitAutomationRefresh()
            try Task.checkCancellation()
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, teardownDepth == 0 else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let intent = PendingAction(id: id,
                    proceed: { continuation.resume() },
                    cancel: { continuation.resume(throwing: SetupCancelled()) })
                if !intercept(intent) { continuation.resume() }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in
                guard self.pending?.id == id else { return }
                self.cancelPendingAction()
                // Saving this waiter as a draft is part of an explicit restart. Keep its
                // setup surface available to explain a cancelled/failed relaunch.
                if !self.ownsPermissionRelaunch || !SafeAppRelaunch.shared.isPreparing { self.dismissWindow() }
            }
        }
    }

    /// Holds the requested action only while required setup is incomplete. Voice consent is
    /// independent and never opens this gate for a typed command.
    func intercept(_ action: @escaping @MainActor () -> Void) -> Bool {
        intercept(PendingAction(id: UUID(), proceed: action, cancel: {}))
    }

    private func intercept(_ intent: PendingAction) -> Bool {
        guard teardownDepth == 0 else {
            intent.cancel()
            return true
        }
        // A newer user intent replaces the held one. Cancelling this waiter must not cancel the
        // shared native probe, which Settings or health may also be awaiting.
        cancelPendingAction()
        refresh()
        if canProceedWithoutSetup {
            dismissWindow()
            return false
        }
        pending = intent
        showingVoiceRepair = false
        presentPendingAction()
        return true
    }

    private var canProceedWithoutSetup: Bool {
        guard isReadyForTask else { return false }
        if allRequiredGranted { HealthCaution.latchComputerUse() }
        return true
    }

    private func presentPendingAction() {
        let blocking = !isReadyForTask
        let wasVisible = window?.isVisible ?? false
        present()
        if wasVisible {
            Log("ComputerUseGate: re-intercepted — setup window already up, action re-held")
        } else {
            Analytics.signal("PermissionGate.shown", parameters: ["blocking": String(blocking)])
            Log("ComputerUseGate: setup window up (\(blocking ? blockingReason : "required setup ready"))")
        }
    }

    private var blockingReason: String {
        if !sentientScreen { return "Sentient Screen Recording missing" }
        if needsAutomation { return "Sentient Automation missing" }
        if backend == .cua && !sentientAccessibility { return "Sentient Accessibility missing" }
        return "setup unavailable during teardown"
    }

    /// Escape can cancel a held intent even before a window or typing field is visible.
    /// Visible setup keeps its existing close/Continue behavior.
    @discardableResult
    func cancelBeforePresentation() -> Bool {
        guard window == nil, pending != nil else { return false }
        cancelPendingAction()
        Log("ComputerUseGate: held action cancelled before setup")
        return true
    }

    /// A voice HOLD against a DENIED mic/speech grant — an unambiguous "I want to talk" that can
    /// never work and has no native prompt left to re-show (denied prompts appear once, ever). So
    /// raise the setup window as a FIX SURFACE: non-blocking, nothing held, its Mic & Speech row
    /// one Fix… away from the right System Settings pane. Voice stays optional — typed commands
    /// and taps never reach this. Returns true when the window was raised (denied confirmed by a
    /// fresh probe) and the caller should stand down; false means not denied — proceed to capture
    /// (a not-asked-yet grant gets the native prompt instead).
    func presentVoiceFixIfDenied() -> Bool {
        // Consume the gesture while reset/uninstall owns teardown; no capture should start.
        guard teardownDepth == 0 else { return true }
        refresh()
        guard micSpeech == .denied else { return false }
        showingVoiceRepair = true
        present()
        Log("ComputerUseGate: mic click hit a denied mic/speech — setup window up as the fix surface")
        return true
    }

    /// An open setup window follows grants made in System Settings. Native helper
    /// Accessibility and Screen Recording remain owned by its actual tool requests.
    func refresh() {
        guard teardownDepth == 0 else { return }
        refreshGrants()
        if window != nil, !showingVoiceRepair { refreshAutomation() }
    }

    private func refreshGrants() {
        backend = .current
        setup.refresh()
        if backend == .openAI { NativePermissionCheck.shared.refresh() }
        if backend == .openAI, helperPermissionState.isReady, NativePermissionSetup.shared.recoveryNeeded {
            NativePermissionSetup.shared.verified()
        }
        if capabilityFailure != nil, unresolvedCapabilityFailure == nil { capabilityFailure = nil }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted {
            micSpeech = .denied
        } else {
            micSpeech = .notAsked
        }
        // Match ScreenCapture's effective permission. A stored TCC row may authorize an older
        // signing identity, so its bundle ID alone must not turn this row green.
        sentientScreen = Permissions.hasScreenRecording()
        sentientAccessibility = Permissions.hasAccessibility()
    }

    /// The supported Apple Events preflight works even when macOS prevents reads of its
    /// per-user TCC database. Starting the signed helper first avoids mistaking -600 for denial.
    private func refreshAutomation(force: Bool = false) {
        guard teardownDepth == 0, backend == .openAI, setup.ready, !requestingAutomation, automationProbe == nil,
              force || (lastAutomationProbe.map({ Date().timeIntervalSince($0) >= (window == nil ? 5 : 1) }) ?? true) else { return }
        let id = beginNativeOperation()
        automationProbeID = id
        checkingAutomation = true
        automationProbe = Task {
            defer {
                if automationProbeID == id {
                    automationProbeID = nil; automationProbe = nil
                    checkingAutomation = false; lastAutomationProbe = Date()
                }
            }
            do {
                try await checkNativeAccess(ask: false, operationID: id, entryPoint: .passive)
            } catch {
                // A failed observation cannot preserve a stale permission denial.
                if nativeOperationID == id, !Task.isCancelled { automation = .unavailable }
                recordNativeFailure(error, operationID: id, passive: true)
            }
        }
    }

    /// Wait for a scheduled preflight at explicit setup checkpoints, without blocking AppKit.
    func awaitAutomationRefresh() async { _ = await automationProbe?.value }

    /// Continue only checks Sentient's own grants. Helper setup belongs to the first
    /// native tool call, after the agent decides whether computer control is needed.
    func continueNow() {
        guard teardownDepth == 0 else { return }
        if showingVoiceRepair { dismissWindow(); return }
        refreshGrants()
        if requiresPermissionRestart { restartAfterPermissions(); return }
        guard window != nil, isReadyForTask else { return }
        if allRequiredGranted { HealthCaution.latchComputerUse() }
        let action = pending
        pending = nil
        let runtime = backend
        Analytics.signal("PermissionGate.continued", parameters: ["all_granted": String(allRequiredGranted)])
        dismissWindow()
        if runtime == .cua {
            Task { await CuaDriverHost.shared.markGrantsChanged(); action?.proceed() }
        } else {
            action?.proceed()
        }
    }

    private func cancelPendingAction() {
        let action = pending
        pending = nil
        action?.cancel()
    }

    // MARK: Window lifecycle (AppKit-owned — it must be able to appear over OTHER apps, since
    // Sidekick fires from anywhere; a SwiftUI Window scene can't be raised from the coordinator)

    private func present() {
        if window == nil {
            let hosting = NSHostingController(rootView: ComputerUseGateView(gate: self))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.isMovableByWindowBackground = true
            window = w
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main
            ) { [weak self] _ in
                // willClose is delivered on the main queue. Finish synchronously so a delayed
                // close callback cannot erase the action from a newly opened setup window.
                MainActor.assumeIsolated { self?.windowClosed() }
            }
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    private func dismissWindow() {
        guard let window else { return }
        PermissionGuide.shared.close()   // take any drag panel down with the gate
        window.close()                  // willClose → windowClosed(), which finds pending already nil on Continue
    }

    /// Closing setup always drops the held action. Optional voice repair owns no typed action.
    private func windowClosed() {
        if ownsPermissionRelaunch, SafeAppRelaunch.shared.isPreparing,
           !SafeAppRelaunch.shared.isApplicationTerminating {
            SafeAppRelaunch.shared.cancelPendingRelaunch()
        }
        ownsPermissionRelaunch = false
        permissionRequest?.cancel()
        cancelPendingAction()
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window?.contentViewController = nil
        window = nil
        showingVoiceRepair = false
        PermissionGuide.shared.close()
    }
}
