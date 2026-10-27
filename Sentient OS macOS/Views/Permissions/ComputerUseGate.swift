// Holds user-fired computer tasks until the selected runtime and its required grants are ready.
// Native OpenAI grants and CUA's Sentient grants share the same gate; voice remains optional.
// Key methods: intercept(), refresh(), requestAutomation(), continueNow().
// Doc: Documentation - Permission Gate & Guide.md

import AppKit
import AVFoundation
import Speech
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

    /// The Microphone & Speech row's hover tip — one string for the gate window and Settings → Health.
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
    private(set) var requestingAutomation = false
    private(set) var checkingAutomation = false
    private(set) var nativePermissionError: String?
    /// A competing helper is a recoverable startup condition, not missing permission.
    private var nativeHelperConflict = false
    private(set) var nativeRestartRequired = false
    private(set) var restartingNative = false
    @ObservationIgnored private var automationProbe: Task<Void, Never>?
    @ObservationIgnored private var permissionRequest: Task<Void, Never>?
    @ObservationIgnored private var lastAutomationProbe: Date?
    var setup: ComputerUseSetup { .instance(for: backend) }

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
        localRequirementsReady && (backend == .cua || (automation == .granted && nativePermissionError == nil && !nativeHelperConflict))
    }

    /// The visible setup surface owns the native consent request. Already-granted and denied
    /// states never raise another prompt just because the permission rows were displayed.
    func prepareNativePermissions() async {
        refresh()
        guard backend == .openAI, setup.ready else { return }
        await awaitAutomationRefresh()
        guard !Task.isCancelled, backend == .openAI, setup.ready, automation == .notAsked else { return }
        requestAutomation()
    }

    func requestAutomation() {
        guard backend == .openAI, setup.ready, !requestingAutomation else { return }
        requestingAutomation = true
        nativePermissionError = nil
        permissionRequest = Task {
            defer { permissionRequest = nil; requestingAutomation = false; lastAutomationProbe = Date() }
            do {
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                guard await ComputerUseSetup.instance(for: .openAI).ensureInstalled() else {
                    throw OpenAIComputerUse.RuntimeError.incomplete
                }
                _ = await automationProbe?.value
                try await checkNativeAccess(ask: true, configuration: configuration)
                refresh()
            } catch {
                recordNativeFailure(error)
            }
        }
    }

    /// Explicit recovery for an existing helper with stale startup settings. The runtime checks
    /// that Sentient is idle and never force-kills or stops a different installed helper bundle.
    func restartComputerUse() {
        guard backend == .openAI, !requestingAutomation, !restartingNative else { return }
        requestingAutomation = true
        restartingNative = true
        permissionRequest = Task {
            defer { permissionRequest = nil; requestingAutomation = false; restartingNative = false; lastAutomationProbe = Date() }
            _ = await automationProbe?.value
            do {
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                await NativePermissionCheck.shared.close()
                try await OpenAIComputerUseRuntime.shared.restart(configuration: configuration)
                try await checkNativeAccess(ask: true, configuration: configuration)
            } catch { recordNativeFailure(error) }
        }
    }

    private func checkNativeAccess(ask: Bool, configuration supplied: OpenAIComputerUse.Configuration? = nil,
                                   stoppingConflictingHelpers: Bool = false, verifyCapabilities: Bool = false) async throws {
        let configuration: OpenAIComputerUse.Configuration
        if let supplied { configuration = supplied }
        else { configuration = try await OpenAIComputerUse.Configuration.resolveForSetup() }
        let helper = try await OpenAIComputerUseRuntime.shared.start(configuration: configuration,
            stoppingConflictingHelpers: ask || stoppingConflictingHelpers)
        await NativePermissionCheck.shared.refresh(configuration: configuration, helper: helper)
        nativeHelperConflict = false
        automation = await Permissions.nativeAutomationState(ask: ask)
        try Task.checkCancellation()
        if automation == .granted {
            // Only a user-started task or explicit setup can show the synthetic read-only
            // capability window. Passive refresh never captures anything or opens that window.
            if ask || verifyCapabilities {
                try await NativePermissionCheck.shared.check(configuration: configuration, helper: helper)
            }
            nativePermissionError = nil
            nativeRestartRequired = false
        } else {
            nativeRestartRequired = false
            nativePermissionError = automation == .unavailable ? "The macOS permission could not be checked. Try again." : nil
        }
    }

    private func recordNativeFailure(_ error: Error, passive: Bool = false) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        OpenAIComputerUseRuntime.shared.invalidate()
        let failure = error as? OpenAIComputerUse.RuntimeError
        if failure == .conflictingHelper && passive {
            nativeHelperConflict = true
            nativePermissionError = nil
            nativeRestartRequired = false
            return
        }
        nativeHelperConflict = false
        nativePermissionError = (error as? NativeComputerUseFailure)?.detail == .testWindowNotObserved
            ? "The check window could not be read. Keep it visible on your current desktop and try again."
            : error.localizedDescription
        nativeRestartRequired = failure == .restartRequired || failure == .backendUnavailable
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
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    var isPresenting: Bool { window != nil }

    /// Closing required setup is distinct from cancelling the owning task.
    nonisolated struct SetupCancelled: Error {}

    /// The request already owns the notch and the one-task lock while waiting here. Closing a
    /// blocking setup or pressing STOP releases it; no late permission result can revive it.
    func waitUntilReady() async throws {
        while setup.isInstalling { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
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
                self.dismissWindow()
            }
        }
    }

    /// Holds the requested action only while required setup is incomplete. Voice consent is
    /// independent and never opens this gate for a typed command.
    func intercept(_ action: @escaping @MainActor () -> Void) -> Bool {
        intercept(PendingAction(id: UUID(), proceed: action, cancel: {}))
    }

    private func intercept(_ intent: PendingAction) -> Bool {
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
        if backend == .openAI, nativeInstallationReady, sentientScreen, !allRequiredGranted,
           window == nil, !requestingAutomation {
            // Join a cold helper's local permission preflight before offering setup.
            refreshAutomation(force: true)
            if checkingAutomation {
                Log("ComputerUseGate: waiting for native readiness before presenting setup")
                afterNativeRefresh { gate in
                    if gate.canProceedWithoutSetup {
                        let action = gate.pending
                        gate.pending = nil
                        Log("ComputerUseGate: native readiness confirmed; resuming held action")
                        action?.proceed()
                    } else {
                        gate.presentPendingAction()
                    }
                }
                return true
            }
        }
        presentPendingAction()
        return true
    }

    private var canProceedWithoutSetup: Bool {
        guard allRequiredGranted else { return false }
        HealthCaution.latchComputerUse()
        return true
    }

    private func presentPendingAction() {
        let blocking = !allRequiredGranted
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
        if !localRequirementsReady { return "installation or required local grants missing" }
        if automation != .granted { return "automation \(automation)" }
        return checkingAutomation ? "native readiness check pending" : "native service unavailable"
    }

    /// Escape can cancel a held intent even before a window or typing field is visible.
    /// Visible setup keeps its existing close/Continue behavior.
    @discardableResult
    func cancelBeforePresentation() -> Bool {
        guard window == nil, pendingCheck != nil else { return false }
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
        refresh()
        guard micSpeech == .denied else { return false }
        cancelPendingCheck()
        showingVoiceRepair = true
        present()
        Log("ComputerUseGate: mic click hit a denied mic/speech — setup window up as the fix surface")
        return true
    }

    /// Refresh the selected runtime and grant rows; Automation is checked asynchronously.
    func refresh() {
        refreshGrants()
        if backend == .openAI { refreshAutomation() }
    }

    private func refreshGrants() {
        backend = .current
        setup.refresh()
        if backend == .openAI { NativePermissionCheck.shared.refresh() }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .authorized && speech == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
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
        guard backend == .openAI, setup.ready, !requestingAutomation, automationProbe == nil,
              force || (lastAutomationProbe.map({ Date().timeIntervalSince($0) >= 5 }) ?? true) else { return }
        checkingAutomation = true
        automationProbe = Task {
            defer { automationProbe = nil; checkingAutomation = false; lastAutomationProbe = Date() }
            do {
                try await checkNativeAccess(ask: false)
            } catch {
                recordNativeFailure(error, passive: true)
            }
        }
    }

    /// Wait for a scheduled preflight at explicit setup checkpoints, without blocking AppKit.
    func awaitAutomationRefresh() async { _ = await automationProbe?.value }

    /// Only the waiter is cancellable here, not the shared probe. Re-read grants after it settles
    /// without starting another check and turning the confirmed result back into a pending one.
    private func afterNativeRefresh(_ completion: @escaping @MainActor (ComputerUseGate) -> Void) {
        pendingCheck = Task { [weak self] in
            guard let self else { return }
            await self.awaitAutomationRefresh()
            guard !Task.isCancelled else { return }
            // A held user action may take over a foreign helper that a passive refresh refused.
            // Resolve that conflict before turning it into a blocking permission window.
            if self.backend == .openAI, self.setup.ready,
               self.nativeHelperConflict || self.nativePermissionError != nil || !self.helperPermissionState.isReady {
                do { try await self.checkNativeAccess(ask: false, stoppingConflictingHelpers: true,
                                                     verifyCapabilities: self.sentientScreen) }
                catch { self.recordNativeFailure(error) }
            }
            guard !Task.isCancelled else { return }
            self.pendingCheck = nil
            self.refreshGrants()
            completion(self)
        }
    }

    /// The window's main button — dismiss and fire the held action. Only ever fires once every
    /// required grant is green (the button is disabled until then); the re-probe + guard here make
    /// that a hard invariant, so a stale tap can never launch a feature that would just fail.
    func continueNow() {
        if showingVoiceRepair { dismissWindow(); return }
        guard window != nil, pendingCheck == nil else { return }
        refresh()
        afterNativeRefresh { gate in
            guard gate.allRequiredGranted else {
                Log("ComputerUseGate: Continue blocked (\(gate.blockingReason))")
                return
            }
            HealthCaution.latchComputerUse()
            let action = gate.pending
            gate.pending = nil
            let runtime = gate.backend
            Analytics.signal("PermissionGate.continued", parameters: ["all_granted": "true"])
            gate.dismissWindow()
            // CUA needs a fresh daemon after a permission change. Native tasks establish their
            // required connection themselves, after checking the selected helper and grants.
            if runtime == .cua {
                Task { await CuaDriverHost.shared.markGrantsChanged(); action?.proceed() }
            } else {
                action?.proceed()
            }
        }
    }

    private func cancelPendingCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
    }

    private func cancelPendingAction() {
        cancelPendingCheck()
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
