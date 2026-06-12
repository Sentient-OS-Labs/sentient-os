//
//  Notify.swift
//  Sentient OS macOS
//
//  One small wrapper over UNUserNotificationCenter (Part II §D). Quiet by design — the
//  callers (day's-end job, proactive reminders) notify only when something actually happened;
//  no-op runs never make noise. Permission is requested lazily on first use for now; the
//  real ask moves into onboarding's notification step.
//
//  Key methods: now(title:body:) · schedule(at:title:body:) -> id · cancel(id:).
//

import Foundation
import UserNotifications

enum Notify {

    /// Headless self-tests can't answer the system permission dialog — requestAuthorization
    /// would hang the harness forever (measured: the daysend run wedged here). Notify is a
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Schedule a notification for a future date; returns the request id (for cancel).
    /// A past date fires immediately — better a late nudge than a silent drop.
    @discardableResult
    static func schedule(at date: Date, title: String, body: String) async -> String {
        let id = UUID().uuidString
        guard !suppressed else { return id }
        await requestPermissionIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let interval = date.timeIntervalSinceNow
        let trigger = interval > 1
            ? UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            : nil   // past-dated → deliver now
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return id
    }

    static func cancel(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
