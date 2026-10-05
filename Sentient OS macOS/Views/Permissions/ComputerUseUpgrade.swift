// Coordinates upgrade setup for the selected computer-use runtime before its first task.
// Both migrations hold the regular interface until installation and required grants are ready.
// Pending work survives relaunch, and reset prevents late installer callbacks reviving a window.
// Doc: Documentation - Permission Gate & Guide.md

import AppKit
import SwiftUI

@MainActor
@Observable
final class ComputerUseUpgrade {

    static let shared = ComputerUseUpgrade()
    private init() {}

    private static let cuaPendingKey = "computerUse.upgradePending"
    // Older builds allowed native setup to be skipped. Preserve that history as evidence of
    // unfinished migration, never as permission to bypass setup.
    private static let legacyNativeDeferredKey = "computerUse.nativeUpgradeDeferred"
    private static let nativePendingKey = "computerUse.nativeUpgradePending"
    private var migrationBackend = ComputerUseBackend.current
    private var pendingKey: String { migrationBackend == .openAI ? Self.nativePendingKey : Self.cuaPendingKey }
    var setup: ComputerUseSetup { .instance(for: migrationBackend) }

    #if DEBUG
    /// Forces the pitch without changing pending state. Installer and permission actions are real.
    private let isPreview = CommandLine.arguments.contains("--preview-computer-use-upgrade")
    #else
    private let isPreview = false
    #endif

    enum Phase {
        case pitch        // the announcement + CTA (and, after a failed attempt, the retry)
        case installing   // the selected runtime installer is running
        case grants       // runtime installed; required grants and Done
    }
    private(set) var phase: Phase = .pitch

    /// The ✗ line of a failed install attempt, shown under the CTA with the retry.
    private(set) var failureLine: String?

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []
    private var hiddenWindows: [NSWindow] = []
    private var openHome: (@MainActor () -> Void)?
    private var onSetupFinished: (@MainActor () -> Void)?
    private var needsHome = false
    private var installGeneration = UUID()
    private var windowSweepScheduled = false

    /// Independent of window visibility: closing the announcement never releases the interface.
    private(set) var isBlockingInterface = false

    /// True while the window is up — HealthCaution's driver-missing rung defers to it, so the
    /// home never shows the red "needs setting up again" banner behind this window's own fix.
    var isPresenting: Bool { window != nil }

    /// A pending marker from an earlier build cannot outweigh an already configured CUA setup.
    /// Keep genuinely incomplete migrations pending, including installations still missing grants.
    static func requiresMigration(onboarded: Bool, pending: Bool, legacyWasReady: Bool,
                                  hasCuaHistory: Bool, requiredVersionInstalled: Bool,
                                  permissionsReady: Bool = false) -> Bool {
        let unresolvedPending = pending && !(hasCuaHistory && permissionsReady)
        return onboarded && (unresolvedPending || (legacyWasReady && !hasCuaHistory && !requiredVersionInstalled))
    }

    static func requiresNativeMigration(onboarded: Bool, pending: Bool, previouslyUsed: Bool,
                                        nativeCompleted: Bool, ready: Bool) -> Bool {
        onboarded && !ready && (pending || (previouslyUsed && !nativeCompleted))
    }

    /// The actual helper installed by Sentient's old ComputerUseSetup. A readiness latch alone
    /// is shared with CUA and cannot prove that a fresh user ever had the legacy driver.
    static func hasLegacyPayload(in codexHome: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: codexHome.appendingPathComponent(
            "computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService").path)
    }

    func prepareForLaunch(onSetupFinished: @escaping @MainActor () -> Void) {
        guard !isBlockingInterface, !CodexRuntimeMigration.isPending else { return }
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppState.onboardingKey) else { return }
        migrationBackend = .current
        ComputerUseGate.shared.refresh()
        let ready = ComputerUseGate.shared.allRequiredGranted
        let pending = defaults.bool(forKey: pendingKey)
        let required: Bool
        if migrationBackend == .openAI {
            required = Self.requiresNativeMigration(onboarded: true, pending: pending || isPreview,
                previouslyUsed: defaults.bool(forKey: HealthCaution.computerUseEverReadyKey)
                    || CuaDriver.hasInstallationHistory
                    || defaults.bool(forKey: Self.legacyNativeDeferredKey),
                nativeCompleted: defaults.bool(forKey: HealthCaution.nativeComputerUseEverReadyKey),
                ready: ready && !isPreview)
        } else {
            required = Self.requiresMigration(onboarded: true, pending: pending || isPreview,
                legacyWasReady: defaults.bool(forKey: HealthCaution.computerUseEverReadyKey)
                    && Self.hasLegacyPayload(in: OpenAIComputerUse.codexHome),
                hasCuaHistory: CuaDriver.hasInstallationHistory,
                requiredVersionInstalled: CuaDriver.isInstalled, permissionsReady: ready && !isPreview)
        }
        if ready, !isPreview {
            defaults.removeObject(forKey: pendingKey)
            if migrationBackend == .openAI { defaults.removeObject(forKey: Self.legacyNativeDeferredKey) }
            HealthCaution.latchComputerUse()
        }
        guard required else { return }
        self.onSetupFinished = onSetupFinished
        isBlockingInterface = true
        if !isPreview { defaults.set(true, forKey: pendingKey) }
        phase = migrationBackend.isInstalled && !isPreview ? .grants : .pitch

        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.isBlockingInterface, let candidate = note.object as? NSWindow,
                          self.hiddenWindows.contains(where: { $0 === candidate }),
                          candidate.isVisible || candidate.isMiniaturized else { return }
                    self.hide(candidate)
                    self.hideRegisteredWindowsAfterOrdering()
                    // Hiding a regular window must not steal focus from a permission prompt,
                    // reopen a just-closed setup window, or undo the user's minimize action.
                }
            })
        }
        windowObservers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                              queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let closing = note.object as? NSWindow,
                      self.hiddenWindows.contains(where: { $0 === closing }) else { return }
                self.hiddenWindows.removeAll { $0 === closing }
            }
        })
        windowObservers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isMiniaturized != true else { return }
                self.maybePresent(activate: false)
            }
        })
    }

    /// The menu-bar label registers this even on a windowless launch. Scene registration is a
    /// second source; a late registration also fulfills a completion that had no home yet.
    func registerHomeOpener(_ action: @escaping @MainActor () -> Void) {
        openHome = action
        if needsHome {
            needsHome = false
            action()
        }
    }

    /// The scene guard calls this before its hosting window is shown. Only this app's registered
    /// scenes are hidden; macOS permission prompts and the setup's permission guide remain usable.
    func register(window: NSWindow, openHome: @escaping @MainActor () -> Void) {
        guard isBlockingInterface else { return }
        registerHomeOpener(openHome)
        let isNewWindow = !hiddenWindows.contains(where: { $0 === window })
        if isNewWindow { hiddenWindows.append(window) }
        hide(window)
        hideRegisteredWindowsAfterOrdering()
        if isNewWindow {
            Task { @MainActor [weak self] in self?.maybePresent() }
        }
    }

    private func hide(_ window: NSWindow) {
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if window.isVisible || window.isMiniaturized { window.orderOut(nil) }
    }

    /// AppKit can finish an order-front operation after delivering its key-window notification.
    /// Alpha hides it immediately; a coalesced next-turn sweep finishes ordering it out, without
    /// refocusing setup or recursively fighting the Window menu.
    private func hideRegisteredWindowsAfterOrdering() {
        guard !windowSweepScheduled else { return }
        windowSweepScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.windowSweepScheduled = false
            guard self.isBlockingInterface else { return }
            for window in self.hiddenWindows { self.hide(window) }
        }
    }

    /// Open/reopen only the setup window while the upgrade is pending.
    func maybePresent(activate: Bool = true) {
        guard isBlockingInterface else { return }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            if activate, !NSApp.isActive { NSApp.activate() }
            return
        }
        ComputerUseGate.shared.refresh()
        let hosting = NSHostingController(rootView: ComputerUseUpgradeView(model: self))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.identifier = NSUserInterfaceItemIdentifier("computer-use-upgrade")
        w.title = "Computer Use"
        w.toolbar = NSToolbar(identifier: "ComputerUseUpgrade")
        w.toolbarStyle = .unified
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        window = w
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed() }
        }
        // Lay the SwiftUI content out BEFORE centering: `center()` reads the window's current
        // frame, and against the pre-layout size the content then grows the window from that
        // origin — landing it visibly off-center (field-found on the first migration test).
        hosting.view.layoutSubtreeIfNeeded()
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        if activate, !NSApp.isActive { NSApp.activate() }
        Analytics.signal("ComputerUseUpgrade.shown")
        Log("ComputerUseUpgrade: setup window up; main interface hidden")
    }

    /// The CTA — run the shared setup engine and narrate it. `ensureInstalled` (not a bare setup
    /// call) so an install already in flight — a Sidekick fire's self-heal racing this window —
    /// is awaited rather than misread as a failure. Success flows into the grant rows; failure
    /// returns to the pitch with the ✗ line and the CTA as the retry.
    func install() {
        guard isBlockingInterface, phase == .pitch else { return }
        phase = .installing
        failureLine = nil
        let generation = installGeneration
        Task {
            let installed = await setup.ensureInstalled()
            // Factory Reset may have returned to onboarding while the shared download ran.
            guard isBlockingInterface, generation == installGeneration else { return }
            if installed {
                ComputerUseGate.shared.refresh()
                phase = .grants
                Analytics.signal("ComputerUseUpgrade.installed")
            } else {
                failureLine = setup.status
                phase = .pitch
            }
        }
    }

    /// Recheck readiness at the click; neither closing the window nor finishing the download
    /// alone can reveal the app while a required permission is still missing.
    func finish() {
        ComputerUseGate.shared.refresh()
        guard isBlockingInterface, phase == .grants, migrationBackend.isInstalled,
              ComputerUseGate.shared.allRequiredGranted else { return }
        Analytics.signal("ComputerUseUpgrade.finished",
                         parameters: ["all_granted": "true"])
        if !isPreview { HealthCaution.latchComputerUse() }
        completeSetup()
    }

    private func completeSetup() {
        if !isPreview {
            UserDefaults.standard.removeObject(forKey: pendingKey)
            if migrationBackend == .openAI { UserDefaults.standard.removeObject(forKey: Self.legacyNativeDeferredKey) }
        }
        releaseInterface()
        Log("ComputerUseUpgrade: setup complete; main interface revealed")
    }

    /// Factory Reset owns the onboarding rewind. Clear the migration too, including an in-flight
    /// window session, without cancelling the shared installer or marking optional grants offered.
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.cuaPendingKey)
        UserDefaults.standard.removeObject(forKey: Self.nativePendingKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyNativeDeferredKey)
        installGeneration = UUID()
        phase = .pitch
        failureLine = nil
        if isBlockingInterface { releaseInterface() }
    }

    private func releaseInterface() {
        isBlockingInterface = false
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        window?.close()

        let windows = hiddenWindows
        hiddenWindows.removeAll()
        for hidden in windows {
            hidden.alphaValue = 1
            if hidden.isMiniaturized { hidden.deminiaturize(nil) }
            hidden.orderFront(nil)
        }
        let finished = onSetupFinished
        onSetupFinished = nil
        finished?()
        if let home = windows.first(where: SentientOSApp.isHomeWindow) {
            home.makeKeyAndOrderFront(nil)
        } else {
            if let openHome {
                openHome()
            } else {
                needsHome = true
            }
        }
        NSApp.activate()
    }

    /// Native close and the completion buttons share the same presentation cleanup.
    private func windowClosed() {
        window = nil
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

// MARK: - The window's face

struct ComputerUseUpgradeView: View {
    let model: ComputerUseUpgrade

    private var gate: ComputerUseGate { ComputerUseGate.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingWhisper(model.phase == .grants ? "ONE LAST STEP" : "SENTIENT UPDATED")
                .frame(maxWidth: .infinity)

            Text(model.phase == .grants ? "Allow the permissions needed to control your computer"
                                        : "Computer use just got better.")
                .display(23)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

            if model.phase != .grants {
                Text("Prepare computer use for your selected AI engine.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            switch model.phase {
            case .pitch, .installing:
                installSection
            case .grants:
                SentientPermissionRows(gate: gate)
                    .padding(.top, 30)
                OnboardingNextButton(title: gate.allRequiredGranted ? "Done" : "Grant permissions to finish",
                                     enabled: gate.allRequiredGranted) {
                    model.finish()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
            }
        }
        .padding(.horizontal, 44)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: model.phase)
        .task {
            while !Task.isCancelled {
                gate.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            gate.refresh()   // the user may just have flipped a switch in System Settings
        }
    }

    /// The pitch CTA and, while the engine runs, the live narration under it.
    @ViewBuilder
    private var installSection: some View {
        OnboardingNextButton(title: ctaTitle,
                             enabled: model.phase == .pitch,
                             glow: model.phase == .pitch ? 0.4 : 0) {   // the screen's ONE glowing object
            model.install()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)

        Group {
            if model.phase == .installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(model.setup.status ?? "Starting…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let line = model.failureLine {
                Text(line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.setup.backend == .openAI ? "Downloaded from Sentient and verified on this Mac." : "A one-time 40 MB download, verified on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var ctaTitle: String {
        switch model.phase {
        case .installing: "Setting up…"
        default:          model.failureLine == nil ? "Set up the new computer use" : "Try again"
        }
    }
}

#if DEBUG
#Preview("Computer-use upgrade") {
    ComputerUseUpgradeView(model: ComputerUseUpgrade.shared)
        .preferredColorScheme(.dark)
}
#endif
