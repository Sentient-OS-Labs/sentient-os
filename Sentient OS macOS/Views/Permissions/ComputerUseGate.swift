//
//  ComputerUseGate.swift
//  Sentient OS macOS
//
//  The first-use permission gate for everything that acts on the Mac. Every computer-use surface
//  (the home command bar, Sidekick's hotkey, a proactive card's fire) funnels through
//  `intercept(_:)`: while any REQUIRED action grant is missing — Sentient's own Accessibility (the
//  cua driver's hands) and Screen Recording (its eyes) — it stashes the pending action, raises the
//  one-time setup window (ComputerUseGateView), and fires the action when the user taps Continue.
//  The driver runs inside Sentient's responsibility chain, so macOS answers its checks with
//  Sentient's grants: the user grants twice, to the app they already trust, and no helper app ever
//  appears in System Settings. Microphone & Speech rides along as an OPTIONAL row (Sidekick's
//  voice): missing it never gates anything — hold-to-talk stays off while tap-to-type and typed
//  commands still work. The optional grant is offered exactly once (a persisted flag), and a voice
//  HOLD against a DENIED mic re-raises the window as a non-blocking fix surface
//  (presentVoiceFixIfDenied — a denied grant has no native prompt left to show). Closing the
//  window instead cancels the pending action. All required grants green and the optional offered
//  means it never appears at all. Status probes reuse Permissions/VoiceCapture.
//
//  Key methods: intercept(_:) · refresh() · continueNow()
//

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

    /// Sentient's mic + speech recognition — Sidekick's ears. OPTIONAL: without it, hold-to-talk
    /// stays off (the first hold flashes the mic notice); tap-to-type and typed commands are
    /// untouched. Detail preserved for the fix action.
    enum MicSpeechState { case granted, notAsked, denied }
    private(set) var micSpeech: MicSpeechState = .notAsked

    /// Sentient's own Screen Recording — the cua driver's EYES (per-window screenshots) and the
    /// screen-context snapshot at fire time, since the driver runs inside Sentient's TCC chain and
    /// captures windows as us.
    private(set) var sentientScreen = false

    /// Sentient's own Accessibility — the cua driver's HANDS: every AX read and every background
    /// click the driver makes is answered with Sentient's grant, because Sentient is the
    /// responsible app in the chain that spawned it.
    private(set) var sentientAccessibility = false

    /// The REQUIRED grants — what the gate holds actions for: Sentient's Accessibility (the
    /// driver's hands) and Screen Recording (its eyes). Microphone & Speech is optional — voice is
    /// one of several ways to ask, never the thing that acts.
    var allRequiredGranted: Bool { sentientAccessibility && sentientScreen }

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
        Log("ComputerUseGate: voice hold hit a denied mic/speech — setup window up as the fix surface")
        return true
    }

    /// Re-probe all three grants (cheap; the TCC read is one tiny indexed SELECT).
    func refresh() {
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
        Task { await CuaDriverHost.shared.markGrantsChanged() }
        let action = pending
        pending = nil
        Analytics.signal("PermissionGate.continued", parameters: ["all_granted": "true"])
        dismissWindow()
        action?()
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
            if presentedBlocking {
                Log("ComputerUseGate: setup window closed — held action dropped (required grant missing)")
            } else {
                Log("ComputerUseGate: optional-grants offer dismissed — firing the held command")
                action()
            }
        }
        PermissionGuide.shared.close()
    }
}
