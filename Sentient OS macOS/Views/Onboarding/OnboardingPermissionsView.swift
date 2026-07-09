//
//  OnboardingPermissionsView.swift
//  Sentient OS macOS
//
//  Onboarding's permissions step: Sentient's three core grants as the same StatusLine rows
//  Settings → Health uses, with the same fix actions. The rows unlock SEQUENTIALLY (each greyed
//  until the previous one is granted) and Full Disk Access is deliberately LAST: FDA is the one
//  grant that forces an app relaunch, and putting it at the end means the relaunch restarts the
//  background codex install as late as possible — so it's done before the user reaches the codex
//  login step. Continue stays disabled until all three are green; the persisted onboarding step
//  brings the user straight back here after the FDA relaunch. Statuses re-probe when the app
//  foregrounds (returning from System Settings).
//

import SwiftUI
import AppKit

struct OnboardingPermissionsView: View {
    let onContinue: () -> Void

    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var daemon: DaemonState = .notSetUp
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval

    private enum DaemonState { case ready, installing, notSetUp }

    private var allGreen: Bool { fdaGranted && daemon == .ready && loginOn }

    // Sequential unlock: each row stays greyed until the previous one is granted (a row that's
    // already green never dims). FDA sits last on purpose — see the top-of-file comment.
    private var loginUnlocked: Bool { daemon == .ready || loginOn }
    private var fdaUnlocked: Bool { (daemon == .ready && loginOn) || fdaGranted }

    /// Grey + inert until unlocked.
    private func gated<V: View>(_ unlocked: Bool, _ row: V) -> some View {
        row.opacity(unlocked ? 1 : 0.35)
            .disabled(!unlocked)
            .animation(.easeInOut(duration: 0.3), value: unlocked)
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            OnboardingWhisper("PERMISSIONS")

            Text("Sentient needs a few permissions to read your life on this Mac.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 2) {
                SettingsGroup(label: "On-device Intelligence") {
                    VStack(alignment: .leading, spacing: 2) {
                        StatusLine(title: "Overnight wake",
                                   health: daemon == .ready ? .ok : .bad,
                                   note: daemonNote,
                                   tip: "A tiny system helper that wakes your Mac at 3 AM so Sentient's on-device intelligence can work while you sleep. It only runs while your Mac is plugged in and Sentient is open in your menu bar. Installed once with your password.",
                                   fixTitle: "Set Up…") {
                            fixDaemon()
                        }
                        gated(loginUnlocked,
                              StatusLine(title: "Launch at login",
                                         health: loginOn ? .ok : .warn,
                                         note: loginOn ? "on" : (loginNeedsApproval ? "approve in system settings" : "off"),
                                         tip: "Starts Sentient quietly in your menu bar when you log in, so the overnight run can happen and your Sentient can stay alive.",
                                         fixTitle: loginNeedsApproval ? "Approve…" : "Turn On") {
                            LoginItem.enableOrRequestApproval()
                            refresh()
                            // macOS wants the switch flipped by hand → escort the user to it.
                            if LoginItem.needsApproval {
                                PermissionGuide.shared.guide(.loginItems, dragging: nil)
                            }
                        })
                        gated(fdaUnlocked,
                              StatusLine(title: "Full Disk Access",
                                         health: fdaGranted ? .ok : .bad,
                                         note: fdaGranted ? "granted" : "not granted",
                                         tip: "Lets Sentient's on-device LLM read your files & folders, and the databases WhatsApp, iMessage, and Notes keep on this Mac. Everything is read right here on your Mac; your data never leaves it.",
                                         fixTitle: "Grant…") {
                            // The floating guide carries Sentient itself as the drag card — no
                            // hunting through the "+" file picker.
                            PermissionGuide.shared.guide(.fullDiskAccess, dragging: Bundle.main.bundleURL)
                        })
                        if fdaUnlocked && !fdaGranted {
                            HStack(spacing: 6) {
                                SettingsProse("Flip Sentient's switch in the list, then:")
                                Button { Permissions.relaunch() } label: {
                                    Text("Relaunch Sentient")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.Ink.bright)
                                        .underline(true, color: Theme.Ink.deepMuted)
                                }
                                .buttonStyle(.plain)
                                SettingsProse("You'll come right back here.")
                            }
                            .padding(.bottom, 6)
                        }
                    }
                }
            }
            .frame(maxWidth: 560)

            OnboardingNextButton(title: "Continue", enabled: allGreen, action: onContinue)

            Spacer()

            OnboardingTrustFooter()
        }
        .padding(40)
        .onAppear {
            refresh()
            // Ask for notifications silently, with no UI of its own — the native macOS prompt is
            // the only thing the user sees. No-op if already answered (see Notify.ask()).
            Task { await Notify.ask() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()   // the user may just have flipped a switch in System Settings
        }
    }

    // MARK: Overnight wake daemon (same pattern as Settings → Health)

    private var daemonNote: String {
        switch daemon {
        case .ready:      return "ready"
        case .installing: return "installing…"
        case .notSetUp:   return "not set up"
        }
    }

    private func fixDaemon() {
        guard daemon == .notSetUp else { return }
        daemon = .installing
        Task {
            _ = await WakeHelperInstaller.installAsync()
            daemon = WakeHelperInstaller.isInstalledAndCurrent() ? .ready : .notSetUp
        }
    }

    private func refresh() {
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
        if daemon != .installing {
            daemon = WakeHelperInstaller.isInstalledAndCurrent() ? .ready : .notSetUp
        }
    }
}

#Preview("Onboarding — permissions") {
    ZStack {
        Theme.bg.ignoresSafeArea()
        OnboardingPermissionsView(onContinue: {})
    }
    .frame(width: 1180, height: 880)
    .preferredColorScheme(.dark)
}
