// InviteBanner.swift
// The once-only invitation offer in the home's banner slot. Waits for an active,
// idle home, verifies the code, then retires after 20 seconds or dismissal.
// Doc: Views/Documentation - Views - Home, Processing & Shared UI.md

import SwiftUI
import AppKit

struct InviteBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var program = InviteProgram.shared
    @State private var code: String?
    @State private var nextAttempt = Date.distantPast

    var body: some View {
        // Keep a container mounted while empty so its eligibility task can start.
        ZStack {
            if canPresent, let code, program.snapshot?.canShare == true {
                InviteBannerView(code: code) { self.code = nil }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.25), value: code)
        .task(id: canPresent) { await presentWhenReady() }
        .onDisappear { code = nil }
    }

    private var canPresent: Bool {
        controlActiveState == .key && appState.hasCompletedOnboarding && !appState.isUninstalling
            && !ComputerUseUpgrade.shared.isBlockingInterface && appState.update.model.surface != .gate
            && !PipelineActivity.shared.isRunning && !DoubleTap.shared.isDrafting
            && !appState.commandCoordinator.run.isRunning && appState.commandCoordinator.phase == .hidden
    }

    private var homeIsVisible: Bool {
        guard NSApp.isActive, let window = NSApp.keyWindow else { return false }
        return SentientOSApp.isHomeWindow(window) && window.isVisible && !window.isMiniaturized
            && window.attachedSheet == nil
    }

    private func presentWhenReady() async {
        guard canPresent else { code = nil; return }
        while !Task.isCancelled && !program.bannerShown {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard homeIsVisible, UpdateNotice.pending == nil, program.eligible,
                  !program.isBusy, Date() >= nextAttempt else { continue }
            nextAttempt = Date().addingTimeInterval(60)
            let refreshed = await program.refresh(quietly: true)
            guard !Task.isCancelled else { return }
            guard refreshed, canPresent, homeIsVisible, UpdateNotice.pending == nil,
                  !program.bannerShown, let snapshot = program.snapshot,
                  snapshot.canShare, let verifiedCode = snapshot.code else { continue }
            code = verifiedCode
            program.markBannerShown()
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            code = nil
        }
    }
}
