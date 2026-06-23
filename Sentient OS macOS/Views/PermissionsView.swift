//
//  PermissionsView.swift
//  Sentient OS macOS
//
//  Dev-tools PERMISSIONS panel (a sheet behind DEV TOOLS → PERMISSIONS). A home for the macOS
//  privacy grants that have NO in-place toggle until the app makes the system ask.
//
//  Hero: the Automation grant to drive Codex's computer-use helper (Sentient → com.openai.sky
//  .CUAService). macOS won't reliably surface a consent prompt for that target, so the button calls
//  Permissions.grantComputerUseAutomation(), which writes the grant straight into the user's TCC
//  database using the Full Disk Access Sentient already holds (both code-requirement blobs are
//  generated at runtime, so it's correct for any signer and device). Full Disk Access status rides along.
//

import SwiftUI

struct PermissionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cuStatus: String?
    @State private var fdaGranted = false

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
                    computerUsePane
                    fdaPane
                }
                .padding(24)
            }
        }
        .frame(width: 580, height: 500)
        .background(Theme.bg)
        .onAppear { fdaGranted = Permissions.hasFullDiskAccess() }
    }

    // MARK: Computer Use — the Automation grant for Codex's helper

    private var computerUsePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(Theme.accent)
                Text("Computer Use — control “Codex Computer Use”")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
            }

            Text("Computer use spawns codex, which drives Codex's bundled helper over Apple Events — so Sentient needs the Automation right to control “Codex Computer Use”. macOS won't reliably surface a prompt for it, so (using the Full Disk Access Sentient already holds) this writes the grant straight into the TCC database. Both code-signature blobs are generated from the live apps, so it's correct for any build/signer and writes nothing device-specific. One click → granted.")
                .font(.caption2).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: grant) {
                    Label("Grant computer-use control", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(Theme.accent)

                Button("Open Automation Settings") { Permissions.openAutomationSettings() }
                    .buttonStyle(.bordered).tint(.white)
            }

            if let cuStatus {
                Text(cuStatus)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(cuStatus.hasPrefix("✓") ? .green : cuStatus.hasPrefix("✗") ? .red : Theme.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }

    /// Write the Automation grant (Sentient → Codex Computer Use) straight into the user's TCC
    /// database via Full Disk Access — the device- & signer-agnostic path. Synchronous + fast;
    /// no codex run, no prompt. After it, a computer-use command works (no relaunch needed).
    private func grant() {
        do {
            let receipt = try Permissions.grantComputerUseAutomation()
            cuStatus = "✓ \(receipt) — now run a computer-use command."
        } catch {
            cuStatus = "✗ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }

    // MARK: Full Disk Access (status + deep-link; same flow as the More pane)

    private var fdaPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: fdaGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(fdaGranted ? Theme.verdictColor(.survivor) : .orange)
                Text("Full Disk Access")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                Text(fdaGranted ? "GRANTED" : "NEEDED").font(.caption2.weight(.bold))
                    .foregroundStyle(fdaGranted ? Theme.verdictColor(.survivor) : .orange)
            }
            Text("Lets the WhatsApp · iMessage · Apple Notes sources read their protected databases. Changing it needs an app restart.")
                .font(.caption2).foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(.bordered).tint(Theme.accent)
                Button("Restart app") { Permissions.relaunch() }
                    .buttonStyle(.bordered).tint(.white)
                Spacer()
                Button("Re-check") { fdaGranted = Permissions.hasFullDiskAccess() }
                    .buttonStyle(.borderless).controlSize(.small).tint(Theme.accent)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glassCard()
    }
}

#Preview("Permissions") {
    PermissionsView().preferredColorScheme(.dark)
}
