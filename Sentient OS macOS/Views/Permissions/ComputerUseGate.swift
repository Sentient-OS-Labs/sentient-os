//
//  ComputerUseGate.swift
//  Sentient OS macOS
//
//  The first-use permission gate for everything that acts on the Mac. Every computer-use surface
//  (the home command bar, Sidekick's hotkey, a proactive card's fire) funnels through
//  `intercept(_:)`: while any REQUIRED action grant is missing — Sentient's own Microphone &
//  Speech, plus the Codex Computer Use helper's Accessibility and Screen Recording — it stashes
//  the pending action, raises the one-time setup window (ComputerUseGateView), and fires the
//  action when the user taps Continue. Sentient's own Screen Recording rides along as an
//  OPTIONAL row (screen context for Sidekick; missing it never gates anything — no grant means
//  commands simply run text-only). Closing the window instead cancels the pending action. Shown
//  at most once per app session; all required grants green means it never appears at all. Status
//  probes reuse Permissions/VoiceCapture (the helper's grants are system-TCC, read via our FDA).
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

    /// Sentient's mic + speech recognition — Sidekick's ears. Detail preserved for the fix action.
    enum MicSpeechState { case granted, notAsked, denied }
    private(set) var micSpeech: MicSpeechState = .notAsked

    /// Sentient's own Screen Recording — the screen context snapshot. OPTIONAL: without it,
    /// Sidekick runs text-only; it never gates an action.
    private(set) var sentientScreen = false

    /// The Codex Computer Use helper's presence + its two system-TCC grants (its hands and eyes).
    private(set) var helperOnDisk = false
    private(set) var helperAccessibility = false
    private(set) var helperScreen = false

    /// The REQUIRED grants — what the gate holds actions for. Sentient's Screen Recording is
    /// deliberately absent (optional row, shown but never blocking).
    var allRequiredGranted: Bool {
        micSpeech == .granted && helperAccessibility && helperScreen
    }

    // MARK: The gate

    private var pending: (@MainActor () -> Void)?
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// The one entry point. Returns true when the action was intercepted (the setup window is up
    /// and the action is stashed — fired by Continue once every required grant is green, dropped
    /// by close). Returns false ONLY when everything required is already granted, so the caller
    /// may proceed. While any required grant is missing the gate ALWAYS takes over — re-showing
    /// (or re-focusing an already-open window) and re-holding the action on every attempt, so a
    /// feature can never fire half-granted no matter how many times the window was dismissed.
    func intercept(_ action: @escaping @MainActor () -> Void) -> Bool {
        refresh()
        guard !allRequiredGranted else { return false }
        let wasVisible = window?.isVisible ?? false
        pending = action
        present()
        if wasVisible {
            Log("ComputerUseGate: re-intercepted — setup window already up, action re-held")
        } else {
            Analytics.signal("PermissionGate.shown")
            Log("ComputerUseGate: intercepted computer-use action — setup window up (required grants missing)")
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

    /// Re-probe all four grants (cheap; the TCC reads are two tiny indexed SELECTs).
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
        helperOnDisk = Permissions.computerUseHelperURL() != nil
        helperAccessibility = Permissions.isTCCGranted(
            service: "kTCCServiceAccessibility",
            clientBundleID: Permissions.computerUseHelperBundleID)
        helperScreen = Permissions.isTCCGranted(
            service: "kTCCServiceScreenCapture",
            clientBundleID: Permissions.computerUseHelperBundleID)
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
        let action = pending
        pending = nil
        Analytics.signal("PermissionGate.continued", parameters: ["all_granted": "true"])
        dismissWindow()
        action?()
    }

    // MARK: Window lifecycle (AppKit-owned — it must be able to appear over OTHER apps, since
    // Sidekick fires from anywhere; a SwiftUI Window scene can't be raised from the coordinator)

    private func present() {
        // The executor also needs the Automation grant (Sentient → the helper over Apple Events);
        // it's user-invisible and FDA-writable, so heal it here — before the first fire.
        Permissions.selfHealComputerUseAutomation(context: "ComputerUseGate")
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

    /// The red button / X — a held action the user didn't Continue is dropped, not fired blind.
    private func windowClosed() {
        if pending != nil {
            pending = nil
            Log("ComputerUseGate: setup window closed — held action dropped")
        }
        PermissionGuide.shared.close()
    }
}
