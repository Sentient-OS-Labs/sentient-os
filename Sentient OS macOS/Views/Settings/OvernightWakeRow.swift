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

    #if DEBUG
    private static var sourceFixtureRoot: URL?
    private(set) static var sourceFixtureRefreshes = 0
    private(set) static var sourceFixtureSetups = 0

    /// Only the owned, nonce-validated source UI lab may replace wake-helper I/O. Invalid
    /// source-lab invocations also fail closed below; they cannot fall through to a real helper.
    static func enableSourceFixture(root: URL) -> Bool {
        let env = ProcessInfo.processInfo.environment
        let owned = root.standardizedFileURL
        guard env["SENTIENT_SELFTEST"] == "sidekickapp", env["LAB_SIDEKICK_STAGE"] == "ui-personal-sources",
              let configured = env["LAB_SIDEKICK_ROOT"], owned == URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL,
              owned == owned.resolvingSymlinksInPath(), owned.lastPathComponent.hasPrefix("sentient-sidekick-app-"),
              let marker = try? String(contentsOf: owned.appendingPathComponent(".sidekick-app-fixture"), encoding: .utf8), marker == "1\n",
              let owner = try? FileManager.default.attributesOfItem(atPath: owned.path)[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let data = try? Data(contentsOf: owned.appendingPathComponent("fixture.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["schema"] as? Int == 1, let nonce = manifest["nonce"] as? String,
              UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
              manifest["suite"] as? String == "ai.sentient.sidekick-app." + nonce,
              UserDefaults.standard.string(forKey: "lab.fixture.nonce") == nonce else { return false }
        sourceFixtureRoot = owned
        sourceFixtureRefreshes = 0; sourceFixtureSetups = 0
        return true
    }
    private static var isSourceFixtureProcess: Bool {
        ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] == "sidekickapp"
            && ProcessInfo.processInfo.environment["LAB_SIDEKICK_STAGE"] == "ui-personal-sources"
    }
    #endif

    func refresh() async {
        #if DEBUG
        if Self.isSourceFixtureProcess {
            guard Self.sourceFixtureRoot != nil else { return }
            Self.sourceFixtureRefreshes += 1
            health = .notSetUp
            return
        }
        #endif
        guard !busy, !checking else { return }
        checking = true
        let startedAt = revision
        let result = await WakeHelperClient.shared.healthProbe()
        checking = false
        if !busy, startedAt == revision { updateHealth(result) }
    }

    func setUp() async {
        #if DEBUG
        if Self.isSourceFixtureProcess {
            guard Self.sourceFixtureRoot != nil else { return }
            Self.sourceFixtureSetups += 1
            health = .notSetUp
            return
        }
        #endif
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
