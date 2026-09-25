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
    static let micSpeechTip = "Optional but recommended.\nLets Sidekick hear you."

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
    @ObservationIgnored private var automationProbe: Task<Void, Never>?
    @ObservationIgnored private var lastAutomationProbe: Date?
    var setup: ComputerUseSetup { .instance(for: backend) }

    var allRequiredGranted: Bool {
        guard sentientScreen else { return false }
        switch backend {
        case .cua:
            // Preserve CUA's existing first-use flow. Its task runner joins any background
            // installation before starting the daemon; the permission gate checks the grants.
            return sentientAccessibility
        case .openAI:
            return setup.ready && backend.isInstalled && helperAccessibility && helperScreen && automation == .granted
        }
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
            defer { requestingAutomation = false }
            do {
                guard await ComputerUseSetup.instance(for: .openAI).ensureInstalled() else {
                    throw OpenAIComputerUse.RuntimeError.incomplete
                }
                _ = await automationProbe?.value
                try await OpenAIComputerUse.launchForPermissionRequest()
                automation = await Permissions.nativeAutomationState(ask: true)
                lastAutomationProbe = Date()
                if automation == .unavailable {
                    nativePermissionError = "The macOS permission could not be checked. Try again."
                }
                refresh()
            } catch {
                nativePermissionError = error.localizedDescription
            }
        }
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
    private var presentedBlocking = false   // window up because a REQUIRED grant is missing (vs. the optional offer)
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// The one entry point. Returns true when the gate took over (window up, action stashed) and
    /// the caller must abort; false when the caller may just proceed. It takes over in two cases:
    ///   • a REQUIRED grant is missing → BLOCKING: always re-shows (or re-focuses) and re-holds the
    ///     action until every required grant is green — so a feature can never fire half-granted no
    ///     matter how many times the window was dismissed (Continue is disabled, close drops it).
    ///   • all required are green but Sentient's OPTIONAL grant (Microphone & Speech) is missing
    ///     and hasn't been offered yet → NON-BLOCKING, once ever: Continue is enabled immediately
    ///     and closing still FIRES the held command, so an optional nudge never eats what the user
    ///     fired.
    func intercept(_ action: @escaping @MainActor () -> Void) -> Bool {
        refresh()
        let blocking = !allRequiredGranted
        if !blocking {
            // Seen working — arm the home's regression banner (HealthCaution rung ③).
            HealthCaution.latchComputerUse()
            // Nothing required is missing — the only reason to appear is the one-time optional offer.
            guard micSpeech != .granted, !Self.micSpeechOffered else { return false }
        }
        // The row is shown → it's now been offered.
        if micSpeech != .granted { Self.micSpeechOffered = true }
        presentedBlocking = blocking
        let wasVisible = window?.isVisible ?? false
        pending = action
        present()
        if wasVisible {
            Log("ComputerUseGate: re-intercepted — setup window already up, action re-held")
        } else {
            Analytics.signal("PermissionGate.shown", parameters: ["blocking": String(blocking)])
            Log("ComputerUseGate: intercepted computer-use action — setup window up (\(blocking ? "required grants missing" : "optional-grants offer"))")
        }
        return true
    }

    /// Gate a surface that must not even OPEN while a required grant is missing — the Sidekick
    /// hotkey PRESS, which has no command to hold yet. Without this the notch drops open to listen
    /// and only meets the gate at submit(), after a whole listen-and-transcribe dance. Same
    /// show/re-show behavior as `intercept`; there's simply nothing to fire on Continue, so the
    /// user re-presses to talk once everything's granted. Returns true when the gate took over and
    /// the caller must abort (don't open the notch).
    @discardableResult
    func interceptBeforeStart() -> Bool {
        intercept({})
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
        presentedBlocking = false   // pending stays untouched — a held offer command still fires on close
        present()
        Log("ComputerUseGate: mic click hit a denied mic/speech — setup window up as the fix surface")
        return true
    }

    /// Refresh the selected runtime and grant rows; Automation is checked asynchronously.
    func refresh() {
        backend = .current
        setup.refresh()
        if backend == .openAI {
            helperAccessibility = Permissions.isTCCGranted(service: "kTCCServiceAccessibility", clientBundleID: OpenAIComputerUse.bundleID)
            helperScreen = Permissions.isTCCGranted(service: "kTCCServiceScreenCapture", clientBundleID: OpenAIComputerUse.bundleID)
            refreshAutomation()
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
    private func refreshAutomation() {
        guard backend == .openAI, setup.ready, !requestingAutomation, automationProbe == nil,
              lastAutomationProbe.map({ Date().timeIntervalSince($0) >= 5 }) ?? true else { return }
        checkingAutomation = true
        automationProbe = Task {
            defer { automationProbe = nil; checkingAutomation = false; lastAutomationProbe = Date() }
            do {
                try await OpenAIComputerUse.launchForPermissionRequest()
                automation = await Permissions.nativeAutomationState()
                if automation == .granted { nativePermissionError = nil }
            } catch {
                automation = .unavailable
            }
        }
    }

    /// Wait for a scheduled preflight at explicit setup checkpoints, without blocking AppKit.
    func awaitAutomationRefresh() async { _ = await automationProbe?.value }

    /// The window's main button — dismiss and fire the held action. Only ever fires once every
    /// required grant is green (the button is disabled until then); the re-probe + guard here make
    /// that a hard invariant, so a stale tap can never launch a feature that would just fail.
    func continueNow() {
        refresh()
        guard allRequiredGranted else {
            Log("ComputerUseGate: Continue blocked — a required grant is still missing")
            return
        }
        HealthCaution.latchComputerUse()   // the gate's moment of truth — regressions may now banner
        // A grant may have landed while a cua daemon was already running, and TCC answers are cached
        // per process — so the next command must get a fresh one or it would act half-blind.
        let action = pending
        pending = nil
        Analytics.signal("PermissionGate.continued", parameters: ["all_granted": "true"])
        dismissWindow()
        let runtime = backend
        Task {
            if runtime == .cua { await CuaDriverHost.shared.markGrantsChanged() }
            action?()
        }
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
                Task { @MainActor [weak self] in self?.windowClosed() }
            }
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate()
    }

    private func dismissWindow() {
        PermissionGuide.shared.close()   // take any drag panel down with the gate
        window?.close()                  // willClose → windowClosed(), which finds pending already nil on Continue
    }

    /// The red button / X. A BLOCKING gate drops the held action (never fired blind — a required
    /// grant is missing). The optional-grants offer is non-blocking, so dismissing it still fires
    /// the command the user actually asked for.
    private func windowClosed() {
        if let action = pending {
            pending = nil
            refresh()
            if presentedBlocking || !allRequiredGranted {
                Log("ComputerUseGate: setup window closed — held action dropped (required grant missing)")
            } else {
                Log("ComputerUseGate: optional-grants offer dismissed — firing the held command")
                action()
            }
        }
        PermissionGuide.shared.close()
    }
}
