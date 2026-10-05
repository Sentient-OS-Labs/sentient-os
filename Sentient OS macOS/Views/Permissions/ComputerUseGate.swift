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
    private(set) var helperAccessibility = false
    private(set) var helperScreen = false
    private(set) var automation: Permissions.AutomationState = .unavailable
    private(set) var requestingAutomation = false
    private(set) var checkingAutomation = false
    private(set) var nativePermissionError: String?
    private(set) var nativeRestartRequired = false
    private(set) var restartingNative = false
    var nativeRuntimeReady: Bool { OpenAIComputerUseRuntime.shared.isReady }
    @ObservationIgnored private var automationProbe: Task<Void, Never>?
    @ObservationIgnored private var lastAutomationProbe: Date?
    var setup: ComputerUseSetup { .instance(for: backend) }

    /// Synchronous grants and installation state. A service starting in the background is not
    /// evidence that these permissions need to be granted again.
    private var localRequirementsReady: Bool {
        guard sentientScreen else { return false }
        switch backend {
        case .cua:
            // Preserve CUA's existing first-use flow. Its task runner joins any background
            // installation before starting the daemon; the permission gate checks the grants.
            return sentientAccessibility
        case .openAI:
            return CodexSetup.shared.computerUseReady && setup.ready && backend.isInstalled
                && helperAccessibility && helperScreen
        }
    }

    var allRequiredGranted: Bool {
        localRequirementsReady && (backend == .cua || (automation == .granted && nativeRuntimeReady))
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
        Task {
            defer { requestingAutomation = false; lastAutomationProbe = Date() }
            do {
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                guard await ComputerUseSetup.instance(for: .openAI).ensureInstalled(nativeConfiguration: configuration) else {
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
        Task {
            defer { requestingAutomation = false; restartingNative = false; lastAutomationProbe = Date() }
            _ = await automationProbe?.value
            do {
                let configuration = try await OpenAIComputerUse.Configuration.resolveForSetup()
                try await OpenAIComputerUseRuntime.shared.restart(configuration: configuration)
                try await checkNativeAccess(ask: true, configuration: configuration)
            } catch { recordNativeFailure(error) }
        }
    }

    private func checkNativeAccess(ask: Bool, configuration supplied: OpenAIComputerUse.Configuration? = nil) async throws {
        let configuration: OpenAIComputerUse.Configuration
        if let supplied { configuration = supplied }
        else { configuration = try await OpenAIComputerUse.Configuration.resolveForSetup() }
        _ = try await OpenAIComputerUseRuntime.shared.start(configuration: configuration)
        automation = await Permissions.nativeAutomationState(ask: ask)
        if automation == .granted {
            try await OpenAIComputerUseRuntime.shared.check(configuration: configuration)
            nativePermissionError = nil
            nativeRestartRequired = false
        } else {
            nativeRestartRequired = false
            nativePermissionError = automation == .unavailable ? "The macOS permission could not be checked. Try again." : nil
        }
    }

    private func recordNativeFailure(_ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        OpenAIComputerUseRuntime.shared.invalidate()
        nativePermissionError = error.localizedDescription
        let failure = error as? OpenAIComputerUse.RuntimeError
        nativeRestartRequired = failure == .restartRequired || failure == .backendUnavailable
    }

    // MARK: The gate

    /// Persisted so Sentient's OPTIONAL grant (Microphone & Speech) is offered exactly once in the
    /// app's lifetime. The gate blocks only on REQUIRED grants, so without this a user who granted
    /// them and skipped voice would never be pitched it again. Cleared by FactoryReset so a rebuild
    /// re-offers it.
    static let micSpeechOfferedKey = "computerUse.micSpeechOffered"
    private static var micSpeechOffered: Bool {
        get { UserDefaults.standard.bool(forKey: micSpeechOfferedKey) }
        set { UserDefaults.standard.set(newValue, forKey: micSpeechOfferedKey) }
    }

    private var pending: (@MainActor () -> Void)?
    @ObservationIgnored private var pendingCheck: Task<Void, Never>?
    private var presentedBlocking = false   // window up because a REQUIRED grant is missing (vs. the optional offer)
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// Returns true when the gate holds the action, either for a quiet readiness check or a
    /// setup window; false when the caller may proceed. Setup appears in two cases:
    ///   • a REQUIRED grant is missing → BLOCKING: always re-shows (or re-focuses) and re-holds the
    ///     action until every required grant is green — so a feature can never fire half-granted no
    ///     matter how many times the window was dismissed (Continue is disabled, close drops it).
    ///   • all required are green but Sentient's OPTIONAL grant (Microphone & Speech) is missing
    ///     and hasn't been offered yet → NON-BLOCKING, once ever: Continue is enabled immediately
    ///     and closing still FIRES the held command, so an optional nudge never eats what the user
    ///     fired.
    func intercept(_ action: @escaping @MainActor () -> Void) -> Bool {
        // A newer user intent replaces the held one. Cancelling this waiter must not cancel the
        // shared native probe, which Settings or health may also be awaiting.
        cancelPendingCheck()
        pending = nil
        refresh()
        if canProceedWithoutSetup {
            dismissWindow()
            return false
        }
        pending = action
        if backend == .openAI, localRequirementsReady, !allRequiredGranted,
           window == nil, !requestingAutomation {
            // A cold helper can clear runtime readiness after an earlier successful permission
            // check. Join the current probe, or request one even inside the normal poll interval.
            refreshAutomation(force: true)
            if checkingAutomation {
                Log("ComputerUseGate: waiting for native readiness before presenting setup")
                afterNativeRefresh { gate in
                    if gate.canProceedWithoutSetup {
                        let action = gate.pending
                        gate.pending = nil
                        Log("ComputerUseGate: native readiness confirmed; resuming held action")
                        action?()
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
        return micSpeech == .granted || Self.micSpeechOffered
    }

    private func presentPendingAction() {
        let blocking = !allRequiredGranted
        // The row is shown → it's now been offered.
        if micSpeech != .granted { Self.micSpeechOffered = true }
        presentedBlocking = blocking
        let wasVisible = window?.isVisible ?? false
        present()
        if wasVisible {
            Log("ComputerUseGate: re-intercepted — setup window already up, action re-held")
        } else {
            Analytics.signal("PermissionGate.shown", parameters: ["blocking": String(blocking)])
            Log("ComputerUseGate: setup window up (\(blocking ? blockingReason : "optional voice offer"))")
        }
    }

    private var blockingReason: String {
        if !localRequirementsReady { return "installation or required local grants missing" }
        if automation != .granted { return "automation \(automation)" }
        return checkingAutomation ? "native readiness check pending" : "native service unavailable"
    }

    /// Hold a notch click or hotkey tap before opening the field. A successful quiet check or
    /// Continue resumes that same intent; it must not require another press to try again.
    @discardableResult
    func interceptBeforeStart(_ action: @escaping @MainActor () -> Void) -> Bool {
        intercept(action)
    }

    /// Escape can cancel a held intent even before a window or typing field is visible.
    /// Visible setup keeps its existing close/Continue behavior.
    @discardableResult
    func cancelBeforePresentation() -> Bool {
        guard window == nil, pendingCheck != nil else { return false }
        cancelPendingCheck()
        pending = nil
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
        presentedBlocking = !allRequiredGranted
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
        if backend == .openAI {
            helperAccessibility = Permissions.isTCCGranted(service: "kTCCServiceAccessibility", clientBundleID: OpenAIComputerUse.bundleID)
            helperScreen = Permissions.isTCCGranted(service: "kTCCServiceScreenCapture", clientBundleID: OpenAIComputerUse.bundleID)
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .authorized && speech == .authorized {
            micSpeech = .granted
        } else if mic == .denied || mic == .restricted || speech == .denied || speech == .restricted {
            micSpeech = .denied
        } else {
            micSpeech = .notAsked
        }
        // Preflight is the running process's view — it stays false until a relaunch even after the
        // user flips the switch. The TCC read (we hold FDA) is the LIVE truth, so the row can go
        // green the moment they grant; the tip still says a restart is needed for capture.
        sentientScreen = Permissions.hasScreenRecording()
            || Permissions.isTCCGranted(service: "kTCCServiceScreenCapture",
                                        clientBundleID: Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS")
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
                recordNativeFailure(error)
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
            self.pendingCheck = nil
            self.refreshGrants()
            completion(self)
        }
    }

    /// The window's main button — dismiss and fire the held action. Only ever fires once every
    /// required grant is green (the button is disabled until then); the re-probe + guard here make
    /// that a hard invariant, so a stale tap can never launch a feature that would just fail.
    func continueNow() {
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
            // CUA needs a fresh daemon after a permission change; native startup checks its
            // own live service again before every computer task.
            if runtime == .cua {
                Task { await CuaDriverHost.shared.markGrantsChanged(); action?() }
            } else {
                action?()
            }
        }
    }

    private func cancelPendingCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
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

    /// The red button / X. A BLOCKING gate drops the held action (never fired blind — a required
    /// grant is missing). The optional-grants offer is non-blocking, so dismissing it still fires
    /// the command the user actually asked for.
    private func windowClosed() {
        cancelPendingCheck()
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        // AppKit retains a closed window when isReleasedWhenClosed is false. Detach its hosted
        // view explicitly: otherwise SwiftUI's polling task continues while the window is shut.
        window?.contentViewController = nil
        window = nil
        if let action = pending {
            pending = nil
            refreshGrants()
            if presentedBlocking || !localRequirementsReady {
                Log("ComputerUseGate: blocking setup dismissed; held action dropped")
            } else if allRequiredGranted {
                Log("ComputerUseGate: optional-grants offer dismissed — firing the held command")
                action()
            } else {
                // Closing the optional offer must not eat a command just because its native
                // check is still running. A real failure drops it without reopening a window.
                pending = action
                refreshAutomation(force: true)
                afterNativeRefresh { gate in
                    let action = gate.pending
                    gate.pending = nil
                    guard gate.allRequiredGranted else {
                        Log("ComputerUseGate: dismissed offer dropped held action (\(gate.blockingReason))")
                        return
                    }
                    action?()
                }
            }
        }
        PermissionGuide.shared.close()
    }
}
