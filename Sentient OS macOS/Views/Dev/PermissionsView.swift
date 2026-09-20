//
//  PermissionsView.swift
//  Sentient OS macOS
//
//  Dev-tools PERMISSIONS panel (a sheet behind DEV TOOLS → PERMISSIONS). A home for every macOS
//  privacy grant Sentient asks for — all Sentient's OWN (the cua driver acts inside Sentient's
//  TCC chain, so there is no helper app with grants of its own):
//
//  Full Disk Access (read the DB sources) · Microphone+Speech (hold right-⌘ to speak) ·
//  Accessibility (the driver's hands — background clicks and typing) · Screen Recording (the
//  driver's eyes + the fire-time screen snapshot) · the overnight wake daemon (root, for the
//  3am wake).
//
//  Accessibility and Screen Recording live in the SIP-protected SYSTEM TCC db — no app can write
//  those, so their panes ask via the native prompt where one exists and deep-link to Settings
//  otherwise. Mic uses the normal request API; the daemon uses SMAppService. Every pane also has
//  a re-check.
//

import SwiftUI
import ServiceManagement   // SMAppService.Status — the wake daemon's registration state

struct PermissionsView: View {
    @Environment(\.dismiss) private var dismiss

    // Sentient's own grants
    @State private var fdaGranted = false
    @State private var micGranted = false
    @State private var srGranted = false          // Sentient's Screen Recording — the driver's eyes
    @State private var axGranted = false          // Sentient's Accessibility — the driver's hands
    @State private var daemonReady = false
    @State private var daemonStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PERMISSIONS").font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.faint)
                Spacer()
                Button("Done") { dismiss() }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    sectionHeader("SENTIENT")
                    fdaPane
                    micPane
                    accessibilityPane
                    screenRecordingPane
                    wakeDaemonPane
                }
                .padding(24)
            }
        }
        .frame(width: 580, height: 560)
        .background(Theme.bg)
        .onAppear(perform: refreshAll)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.caption2.weight(.bold)).tracking(2).foregroundStyle(Theme.secondary)
            Spacer()
        }
    }

    /// Re-read every live status. Cheap; called on appear and after each grant/re-check.
    private func refreshAll() {
        fdaGranted = Permissions.hasFullDiskAccess()
        micGranted = VoiceCapture.isAuthorized
        srGranted = Permissions.hasScreenRecording()
        axGranted = Permissions.hasAccessibility()
        daemonReady = WakeHelperClient.shared.isReady
    }

    // MARK: - Shared pane chrome

    /// Icon + title + GRANTED/NEEDED badge, a description, a row of action buttons, and an optional
    /// monospace receipt line. Used by every pane except the bespoke Automation one (long copy + revoke).
    @ViewBuilder
    private func pane(icon: String, iconColor: Color, title: String, granted: Bool,
                      description: String, receipt: String? = nil,
                      @ViewBuilder actions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(iconColor)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(granted ? "GRANTED" : "NEEDED").font(.caption2.weight(.bold))
                    .foregroundStyle(granted ? Theme.verdictColor(.survivor) : .orange)
            }
            Text(description).font(.caption2).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) { actions() }
            if let receipt { receiptLine(receipt) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    private func receiptLine(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(text.hasPrefix("✓") ? Theme.Ink.green : text.hasPrefix("✗") ? .red : Theme.secondary)
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: - SENTIENT panes

    private var fdaPane: some View {
        pane(icon: fdaGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
             iconColor: fdaGranted ? Theme.verdictColor(.survivor) : .orange,
             title: "Full Disk Access", granted: fdaGranted,
             description: "Lets the WhatsApp · iMessage · Apple Notes sources read their protected databases. Changing it needs an app restart.") {
            Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                .buttonStyle(.bordered).tint(Theme.accent)
            Button("Restart app") { Permissions.relaunch() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private var micPane: some View {
        pane(icon: "mic.fill", iconColor: micGranted ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Microphone & Speech", granted: micGranted,
             description: "Lets you click the mic in the notch and speak the task you want done — Sentient transcribes it on-device.") {
            Button("Grant microphone…") {
                Task {
                    // First ask surfaces the system prompt; if it's already denied/restricted there's no
                    // prompt to show, so fall back to Settings rather than silently doing nothing.
                    let ok = await VoiceCapture.requestPermissions()
                    if !ok { Permissions.openMicrophoneSettings() }
                    refreshAll()
                }
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Microphone Settings") { Permissions.openMicrophoneSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private var screenRecordingPane: some View {
        pane(icon: "rectangle.dashed.badge.record", iconColor: srGranted ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Screen Recording", granted: srGranted,
             description: "The cua driver's eyes (per-window screenshots), plus the fire-time capture so computer use knows what you're looking at. Granted to Sentient itself. Takes effect after an app restart.") {
            Button("Grant screen recording…") { _ = Permissions.requestScreenRecording(); refreshAll() }
                .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Screen Recording Settings") { Permissions.openScreenRecordingSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Restart app") { Permissions.relaunch() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    /// Accessibility — the cua driver's hands. The driver is Sentient's own child, so this is
    /// Sentient's grant: the native prompt where macOS still offers one, the Settings pane after.
    private var accessibilityPane: some View {
        pane(icon: "cursorarrow.rays", iconColor: axGranted ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Accessibility", granted: axGranted,
             description: "Lets the cua driver read a window's element tree and click and type inside it in the background. Granted to Sentient itself — the driver runs inside Sentient's TCC chain. Live: no restart needed.") {
            Button("Grant accessibility…") { _ = Permissions.requestAccessibility(); refreshAll() }
                .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private var wakeDaemonPane: some View {
        pane(icon: "moon.zzz.fill", iconColor: daemonReady ? Theme.verdictColor(.survivor) : Theme.accent,
             title: "Overnight wake daemon (root)", granted: daemonReady,
             description: "Sentient's 3am wake needs a tiny root helper to hold the Mac awake (lid shut) while it processes. macOS asks you to approve it once under Login Items — an approval toggle, not a typed password.",
             receipt: daemonStatus) {
            Button("Install / register daemon") {
                let st = WakeHelperClient.shared.register()
                daemonStatus = "status: \(st.rawValue) (\(daemonStatusName(st)))"
                if st == .requiresApproval { WakeHelperClient.shared.openLoginItemsSettings() }
                refreshAll()
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            Button("Open Login Items") { WakeHelperClient.shared.openLoginItemsSettings() }
                .buttonStyle(.bordered).tint(.white)
            Spacer()
            Button("Re-check") { refreshAll() }
                .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
        }
    }

    private func daemonStatusName(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled:          return "enabled"
        case .requiresApproval: return "needs approval in Login Items"
        case .notRegistered:    return "not registered"
        case .notFound:         return "not found (unsigned build?)"
        @unknown default:       return "unknown"
        }
    }

}

#Preview("Permissions") {
    PermissionsView().preferredColorScheme(.dark)
}
