//
//  OnboardingPermissionsView.swift
//  Sentient OS macOS
//
//  Onboarding's permissions step: Sentient's three core grants as the same StatusLine rows
//  Settings → Health uses, with the same fix actions. The rows unlock SEQUENTIALLY (each greyed
//  until the previous one is granted) and Full Disk Access is deliberately LAST: FDA is the one
//  grant that forces an app relaunch, so it lands only once the other grants are banked. The
//  frontier-model step (codex login included) comes BEFORE this screen — the relaunch never
//  disturbs it, since auth.json and the engine choice persist on disk. Continue stays disabled
//  until all three are green; the persisted onboarding step brings the user straight back here
//  after the FDA relaunch. Statuses re-probe when the app foregrounds (returning from System
//  Settings).
//

import SwiftUI
import AppKit

struct OnboardingPermissionsView: View {
    let onContinue: () -> Void

    @State private var fdaGranted = Permissions.hasFullDiskAccess()
    @State private var wakeSetup = OvernightWakeSetup()
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval

    private var allGreen: Bool { fdaGranted && wakeSetup.ready && loginOn }

    // Sequential unlock: each row stays greyed until the previous one is granted (a row that's
    // already green never dims). FDA sits last on purpose — see the top-of-file comment.
    private var loginUnlocked: Bool { wakeSetup.ready || loginOn }
    private var fdaUnlocked: Bool { (wakeSetup.ready && loginOn) || fdaGranted }

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
                        OvernightWakeRow(setup: wakeSetup)
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
                                         tip: PrivacyCopy.fullDiskAccess,
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

    private func refresh() {
        fdaGranted = Permissions.hasFullDiskAccess()
        loginOn = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
        Task { await wakeSetup.refresh() }
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
