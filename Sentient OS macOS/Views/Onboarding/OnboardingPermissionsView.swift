// Required background setup immediately before first analysis. Merely opening this screen
// checks status; only the user's Enable buttons register macOS services.
import SwiftUI
import AppKit

struct OvernightSetupRequirements: View {
    let onReadinessChange: (Bool) -> Void
    @State private var wakeSetup = OvernightWakeSetup()
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    @State private var loginBusy = false
    @State private var checking = false
    @State private var loginProblem = false
    @State private var loginRevision = 0
    @State private var loginGuideID: UUID?
    @State private var wakeGuideID: UUID?
    @State private var visible = false
    @State private var wakeTask: Task<Void, Never>?
    @State private var loginTask: Task<Void, Never>?
    private var ready: Bool { wakeSetup.ready && loginOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            requirement(title: "Overnight wake", icon: "moon.stars",
                        detail: "Wake your Mac for scheduled updates.",
                        ready: wakeSetup.ready, busy: wakeSetup.busy,
                        actionTitle: wakeSetup.health == .requiresApproval ? "Approve" : "Set up") {
                wakeTask = Task { @MainActor in
                    await wakeSetup.setUp()
                    guard !Task.isCancelled, visible else { return }
                    if PermissionGuide.shared.job?.pane == .overnightWake {
                        wakeGuideID = PermissionGuide.shared.job?.id
                    }
                }
            }
            if wakeSetup.health == .requiresApproval {
                guidance("In System Settings, allow Sentient OS to run in the background. macOS may ask you to authenticate.")
            } else if wakeSetup.health == .unavailable && !wakeSetup.busy {
                guidance("The wake service couldn’t connect. Try Set up again. If needed, move Sentient to Applications and reopen it.")
            }
            requirement(title: "Launch at login", icon: "power",
                        detail: "Keep Sentient ready in your menu bar when you log in.",
                        ready: loginOn, busy: loginBusy,
                        actionTitle: loginNeedsApproval ? "Approve" : "Turn on") {
                guard !loginBusy else { return }
                loginBusy = true; loginProblem = false; loginRevision += 1
                loginTask = Task { @MainActor in
                    defer { loginBusy = false }
                    #if DEBUG
                    if let fixture = OvernightWakeSetup.sourceFixtureReadiness {
                        loginOn = fixture; loginNeedsApproval = false
                        return
                    }
                    #endif
                    _ = await LoginItem.enable()
                    guard !Task.isCancelled, visible else { return }
                    loginOn = LoginItem.isEnabled
                    loginNeedsApproval = LoginItem.needsApproval
                    loginProblem = !loginOn && !loginNeedsApproval
                    if loginNeedsApproval {
                        PermissionGuide.shared.guide(.loginItems, dragging: nil)
                        loginGuideID = PermissionGuide.shared.job?.id
                    }
                }
            }
            if loginNeedsApproval {
                guidance("Turn on Sentient OS in System Settings → General → Login Items.")
            } else if loginProblem {
                guidance("Launch at login couldn’t be enabled. Try again, or enable Sentient OS in Login Items.")
            }
            Text("Keep Sentient in your menu bar. Overnight updates work best with your Mac plugged in.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.Ink.body)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .onAppear { visible = true }
        .onChange(of: ready, initial: true) { _, value in onReadinessChange(value) }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onDisappear {
            visible = false
            wakeTask?.cancel(); loginTask?.cancel()
            if let loginGuideID, PermissionGuide.shared.job?.id == loginGuideID { PermissionGuide.shared.close() }
            if let wakeGuideID, PermissionGuide.shared.job?.id == wakeGuideID { PermissionGuide.shared.close() }
        }
    }

    private func requirement(title: String, icon: String, detail: String, ready: Bool, busy: Bool,
                             actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19, weight: .light))
                .foregroundStyle(.white.opacity(0.8)).frame(width: 38, height: 42)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if ready {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.Ink.green)
            } else if busy {
                ProgressView().controlSize(.small).frame(width: 70)
            } else {
                SettingsPillButton(title: actionTitle, action: action)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09), lineWidth: 1))
    }

    private func guidance(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.Ink.body)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
    }

    private func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        #if DEBUG
        if let fixture = OvernightWakeSetup.sourceFixtureReadiness {
            loginOn = fixture; loginNeedsApproval = false
            await wakeSetup.refresh()
            return
        }
        #endif
        let revision = loginRevision
        if !loginBusy {
            let enabled = await LoginItem.refresh()
            guard !Task.isCancelled else { return }
            if revision == loginRevision && !loginBusy {
                loginOn = enabled; loginNeedsApproval = LoginItem.needsApproval
                if enabled { loginProblem = false }
            }
        }
        await wakeSetup.refresh()
        if loginOn, let loginGuideID, PermissionGuide.shared.job?.id == loginGuideID {
            PermissionGuide.shared.close(); self.loginGuideID = nil
        }
    }
}
