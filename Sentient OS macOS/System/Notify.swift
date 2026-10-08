//
//  Notify.swift
//  Sentient OS macOS
//
//  One small wrapper over UNUserNotificationCenter. Notify.now() is LIVE for the "Sentient just
//  updated." note (UpdateNotice.checkAtLaunch); the proactive-reminder tier still to come rides
//  the same call (git 67d8078 has an old schedule/cancel implementation to mine). The permission
//  ask is live too: onboarding's permissions screen fires Notify.ask() the moment it appears, so
//  the native prompt happens once, with no extra UI; now() also asks lazily as a backstop.
//

import Foundation
import UserNotifications

@MainActor
enum Notify {
    enum Destination: String, Sendable { case knowledgeSources }
    private static let delegate = NotificationDelegate()
    private static var openKnowledgeSources: (() -> Void)?
    private static var pendingKnowledgeSources = false

    static func installRouting() {
        guard !suppressed else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func setKnowledgeSourcesHandler(_ handler: @escaping () -> Void) {
        openKnowledgeSources = handler
        if pendingKnowledgeSources { pendingKnowledgeSources = false; handler() }
    }

    fileprivate static func openSources() {
        if let openKnowledgeSources { openKnowledgeSources() }
        else { pendingKnowledgeSources = true }
    }

    static func connectorsUnavailable(_ slugs: Set<String>) async {
        guard !Task.isCancelled else { return }
        // The in-app warning is independent of macOS notification permission.
        let cautions = ConnectorCaution.record(slugs)
        for caution in cautions {
            guard !Task.isCancelled else { return }
            await now(title: "Connector needs attention",
                body: caution.message,
                destination: .knowledgeSources)
        }
    }


    /// Headless self-tests can't answer the system permission dialog — requestAuthorization
    /// would hang the harness forever (measured: an early day's-end run wedged here). Notify is a
    /// silent no-op under SENTIENT_SELFTEST.
    private static var suppressed: Bool {
        ProcessInfo.processInfo.environment["SENTIENT_SELFTEST"] != nil
    }

    /// Ask macOS for notification permission — the native "Sentient would like to send you
    /// notifications" prompt. A no-op unless the status is still `.notDetermined` (a prior
    /// allow/deny is final; only System Settings can change it), so it's safe to call on every
    /// appearance. Onboarding's permissions screen fires this the moment it appears — no button,
    /// no extra UI. Silent under SENTIENT_SELFTEST (the harness can't answer the dialog).
    static func ask() async {
        guard !suppressed else { return }
        await requestPermissionIfNeeded()
    }

    private static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Fire a notification immediately.
    static func now(title: String, body: String, destination: Destination? = nil) async {
        guard !suppressed else { return }
        await requestPermissionIfNeeded()
        let center = UNUserNotificationCenter.current()

        // §7.23: a denied/undetermined permission means proactive reminders silently never fire —
        // surface it (auth status only; NEVER the title/body).
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            Log("Notify: not permitted (status \(status.rawValue)) — reminder suppressed")
            // A declined permission is the user's choice, not an app defect — product telemetry
            // (how many run with reminders off), so TelemetryDeck, never Sentry (2026-07-12).
            Analytics.signal("Notify.notAuthorized", parameters: ["status": String(status.rawValue)])
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let destination { content.userInfo["destination"] = destination.rawValue }
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } catch {
            Log("Notify: add failed — \(ErrorLabel(error))")
            CrashReporting.captureEvent("notify.add_failed", level: .warning,
                tags: ["error": String(describing: type(of: error))],
                fingerprint: ["notify", "add_failed"])
        }
    }
}

/// Retained by Notify because UNUserNotificationCenter keeps only a weak delegate.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.userInfo["destination"] as? String == "knowledgeSources" else { return }
        await Notify.openSources()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.content.userInfo["destination"] as? String == "knowledgeSources"
            ? [.banner, .sound] : []
    }
}
