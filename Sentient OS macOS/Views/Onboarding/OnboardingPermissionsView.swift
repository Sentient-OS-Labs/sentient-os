// Overnight access is requested only after the user chooses overnight analysis. Source
// access belongs to the source picker; voice and notifications remain independent opt-ins.
import SwiftUI
import AppKit

struct OvernightSetupRequirements: View {
    let onReadinessChange: (Bool) -> Void
    @State private var wakeSetup = OvernightWakeSetup()
    @State private var loginOn = LoginItem.isEnabled
    @State private var loginNeedsApproval = LoginItem.needsApproval
    private var ready: Bool { wakeSetup.ready && loginOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(label: "For overnight analysis") {
                OvernightWakeRow(setup: wakeSetup)
                StatusLine(title: "Launch at login", health: loginOn ? .ok : .warn,
                           note: loginOn ? "on" : (loginNeedsApproval ? "approval needed" : "off"),
                           tip: "Keeps Sentient available in your menu bar after you log in.",
                           fixTitle: loginNeedsApproval ? "Approve…" : "Turn on") {
                    LoginItem.enableOrRequestApproval()
                    refresh()
                    if LoginItem.needsApproval { PermissionGuide.shared.guide(.loginItems, dragging: nil) }
                }
            }
            if !ready {
                Text("You can choose Run now to analyze without overnight setup.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refresh(); onReadinessChange(ready) }
        .onChange(of: ready) { _, value in onReadinessChange(value) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() {
        loginOn = LoginItem.isEnabled
        loginNeedsApproval = LoginItem.needsApproval
        Task { await wakeSetup.refresh() }
    }
}
