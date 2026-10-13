//
//  OvernightWakeRow.swift
//  Sentient OS macOS · Views/Settings/
//
//  Shared native helper setup for onboarding and Permissions & Health. refresh checks actual
//  readiness; setUp requests registration; monitor follows approval while the row is visible.
//  Doc: Documentation - Settings.md
//

import SwiftUI
import Observation

@MainActor @Observable
final class OvernightWakeSetup {
    private(set) var health: WakeHelperClient.DaemonHealth = .notSetUp
    private(set) var busy = false
    private var checking = false
    private var revision = 0
    var ready: Bool { health == .ready }

    func refresh() async {
        guard !busy, !checking else { return }
        checking = true
        let startedAt = revision
        let result = await WakeHelperClient.shared.healthProbe()
        checking = false
        if !busy, startedAt == revision { updateHealth(result) }
    }

    func setUp() async {
        guard !busy else { return }
        revision += 1
        busy = true
        updateHealth(await WakeHelperClient.shared.setUp())
        busy = false
    }

    private func updateHealth(_ result: WakeHelperClient.DaemonHealth) {
        health = result
        if ready, PermissionGuide.shared.job?.pane == .overnightWake {
            PermissionGuide.shared.close()
        }
    }

    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}

struct OvernightWakeRow: View {
    let setup: OvernightWakeSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            StatusLine(title: "Overnight wake",
                       health: setup.ready ? .ok : (setup.busy || setup.health == .requiresApproval ? .warn : .bad),
                       note: note,
                       tip: "Lets Sentient wake your Mac for overnight processing while it is plugged in and Sentient is open in your menu bar. Approve Sentient in System Settings to enable it. macOS may ask you to authenticate.",
                       fixTitle: setup.health == .requiresApproval ? "Approve…" : "Set Up…") {
                Task { await setup.setUp() }
            }
            .disabled(setup.busy)
            if setup.health == .unavailable && !setup.busy {
                SettingsProse("The wake helper couldn't start. Try Set Up again. If this continues, move Sentient to Applications and reopen it, or reinstall the app.")
                    .padding(.bottom, 6)
            }
        }
        .task { await setup.monitor() }
    }

    private var note: String {
        if setup.busy { return "setting up…" }
        switch setup.health {
        case .ready: return "ready"
        case .requiresApproval: return "approve in system settings"
        case .notSetUp: return "not set up"
        case .unavailable: return "needs attention"
        }
    }
}
