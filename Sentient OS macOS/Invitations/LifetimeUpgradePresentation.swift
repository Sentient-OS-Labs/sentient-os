// Only an already-visible, idle Home may present the gift. No idle popup or automatic opener.
import SwiftUI
import AppKit

struct LifetimeUpgradePresentation: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var announcement = LifetimeUpgradeAnnouncement.shared
    @State private var presented: InviteLifetimeUpgrade?
    @Namespace private var ticket

    private var canPresent: Bool {
        controlActiveState == .key && appState.hasCompletedOnboarding && !appState.isUninstalling
            && MainNavigation.shared.page == .home
            && !ComputerUseUpgrade.shared.isBlockingInterface && appState.update.model.surface != .gate
            && !PipelineActivity.shared.isRunning && !DoubleTap.shared.isDrafting
            && !appState.commandCoordinator.run.isRunning && appState.commandCoordinator.phase == .hidden
    }

    func body(content: Content) -> some View {
        content
            .task(id: controlActiveState == .key) {
                guard controlActiveState == .key,
                      ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == nil else { return }
                await announcement.check()
            }
            .task(id: canPresent ? announcement.pending?.id : nil) {
                guard canPresent, let notice = announcement.pending else { return }
                while !Task.isCancelled && presented == nil {
                    // Give existing sheets (setup/sign-in/edit confirmation) priority.
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard canPresent, announcement.pending?.id == notice.id,
                          NSApp.isActive, let window = NSApp.keyWindow,
                          SentientOSApp.isHomeWindow(window), window.isVisible,
                          !window.isMiniaturized, window.attachedSheet == nil else { continue }
                    presented = notice
                }
            }
            .sheet(item: $presented) { notice in
                InviteCelebration(ticketNamespace: ticket, upgrade: true, continueTitle: "Back to Sentient") {
                    presented = nil
                }
                .frame(width: 820, height: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    if NSApp.isActive { announcement.markSeen(notice) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    announcement.markSeen(notice)
                }
            }
    }
}
