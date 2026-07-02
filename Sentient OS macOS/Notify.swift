//
//  Notify.swift
//  Sentient OS macOS
//
//  One small wrapper over UNUserNotificationCenter (Part II §D). Quiet by design — the
//  day's-end job notifies only when the vault actually changed; no-op runs never make noise.
//  Permission is requested lazily on first use for now; the real ask moves into onboarding's
//  notification step. (Scheduled reminders return with proactive intelligence — git 67d8078
//  has the schedule/cancel implementation.)
//

import Foundation
import UserNotifications

enum Notify {

    /// Headless self-tests can't answer the system permission dialog — requestAuthorization
    /// would hang the harness forever (measured: an early day's-end run wedged here). Notify is a
    /// silent no-op under SENTIENT_SELFTEST.
    private static var suppressed: Bool {
        ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] != nil
    }

    /// Ask once per launch, lazily (dev behavior; onboarding owns the real moment later).
    private static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Fire a notification immediately.
    static func now(title: String, body: String) async {
        guard !suppressed else { return }
        await requestPermissionIfNeeded()
        let center = UNUserNotificationCenter.current()

        // §7.23: a denied/undetermined permission means proactive reminders silently never fire —
        // surface it (auth status only; NEVER the title/body).
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            Log("Notify: not authorized (status \(status.rawValue)) — reminder suppressed")
            CrashReporting.captureEvent("notify.not_authorized", level: .warning,
                tags: ["auth_status": String(status.rawValue)],
                fingerprint: ["notify", "not_authorized"])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            Log("Notify: add failed — \(error)")
            CrashReporting.captureEvent("notify.add_failed", level: .warning,
                tags: ["error": String(describing: type(of: error))],
                fingerprint: ["notify", "add_failed"])
        }
    }
}
