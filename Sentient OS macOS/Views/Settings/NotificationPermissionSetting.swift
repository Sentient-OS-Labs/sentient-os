// Shared notification permission control for Privacy and overnight settings.
import SwiftUI
import AppKit
import UserNotifications

struct NotificationPermissionSetting: View {
    @State private var notifStatus: UNAuthorizationStatus
    private let onStatusChange: ((UNAuthorizationStatus) -> Void)?

    init(status: UNAuthorizationStatus = .notDetermined,
         onStatusChange: ((UNAuthorizationStatus) -> Void)? = nil) {
        _notifStatus = State(initialValue: status)
        self.onStatusChange = onStatusChange
    }

    var body: some View {
        StatusLine(title: "Notifications (optional)",
                   health: notifHealth,
                   note: notifNote,
                   tip: "Lets Sentient send a morning note when new suggestions are ready. Optional; everything works without it.",
                   fixTitle: notifStatus == .notDetermined ? "Allow…" : "Fix…") {
            fixNotifications()
        }
        .task { await refreshNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotifications() }
        }
    }

    private func refreshNotifications() async {
        notifStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        onStatusChange?(notifStatus)
    }

    // MARK: Notifications (yellow when off, never red — the morning briefing sleeps, the app works)

    private var notifHealth: StatusLine.Health {
        switch notifStatus {
        case .authorized, .provisional: return .ok
        default:                        return .warn
        }
    }

    private var notifNote: String {
        switch notifStatus {
        case .authorized:    return "on"
        case .provisional:   return "quiet"   // the launch-banked provisional grant (no banners/sounds)
        case .notDetermined: return "not asked yet"
        default:             return "off"
        }
    }

    private func fixNotifications() {
        if notifStatus == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                await refreshNotifications()
            }
        } else {
            // Modern Settings pane first (Ventura+), legacy anchor as fallback — same pattern as
            // Permissions.openFullDiskAccessSettings.
            let modern = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            let legacy = "x-apple.systempreferences:com.apple.preference.notifications"
            if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
            if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
        }
    }

}
