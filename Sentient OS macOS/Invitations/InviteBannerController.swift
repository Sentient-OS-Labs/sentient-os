// InviteBannerController.swift
// A once-only, nonactivating offer near the top of the current display after real use.
// start(appState:) waits for an idle moment; dismiss() leaves the code available in Settings.

import AppKit
import SwiftUI

@MainActor
final class InviteBannerController {
    private var panel: NSPanel?
    private var watch: Task<Void, Never>?
    private var visibleUntil: Date?
    private var nextAttempt = Date.distantPast
    private var sessionActive = true
    private var observers: [NSObjectProtocol] = []

    func start(appState: AppState) {
        guard watch == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionActive = false; self?.dismiss() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionActive = true }
        })
        watch = Task { [weak self, weak appState] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, let appState else { return }
                await self.tick(appState)
                if InviteProgram.shared.bannerShown && self.panel == nil { return }
            }
        }
    }

    private func canPresent(_ appState: AppState) -> Bool {
        sessionActive && appState.hasCompletedOnboarding && !appState.isUninstalling
            && !ComputerUseUpgrade.shared.isBlockingInterface && appState.update.model.surface != .gate
            && !PipelineActivity.shared.isRunning && !DoubleTap.shared.isDrafting
            && !appState.commandCoordinator.run.isRunning && appState.commandCoordinator.phase == .hidden
    }

    private func tick(_ appState: AppState) async {
        if let visibleUntil {
            if Date() >= visibleUntil || !canPresent(appState) || InviteProgram.shared.snapshot?.canShare == false { dismiss() }
            return
        }
        let program = InviteProgram.shared
        guard program.eligible, !program.bannerShown, !program.isBusy, canPresent(appState), Date() >= nextAttempt else { return }
        nextAttempt = Date().addingTimeInterval(60)
        guard await program.refresh(quietly: true), canPresent(appState), !program.bannerShown,
              let snapshot = program.snapshot, snapshot.canShare, let code = snapshot.code else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let width = min(380, screen.visibleFrame.width - 32)
        let frame = NSRect(x: screen.visibleFrame.maxX - width - 16,
                           y: screen.visibleFrame.maxY - 136, width: width, height: 120)
        let panel = InvitePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InviteBannerView(code: code) { [weak self] in self?.dismiss() })
        // The native panel owns its size. Intrinsic hosting would expand the flexible
        // SwiftUI content to the screen's available height.
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(frame.size)
        self.panel = panel
        panel.orderFrontRegardless()
        visibleUntil = Date().addingTimeInterval(20)
        program.markBannerShown()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        visibleUntil = nil
    }
}

private final class InvitePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
