//
//  LoginItem.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  Launch-at-login for the MAIN app, via SMAppService.mainApp. Load-bearing for the overnight
//  scheduler: the scheduler lives INSIDE the running app (OvernightScheduler), so if Sentient isn't
//  open at 3am nothing wakes. Registering the app as a login item is how it's alive to host the run.
//
//  Pure logic — enable / disable / read status. No UI (a dev toggle in DevToolsView drives it today;
//  onboarding wires the real toggle later). enable() is silent (no password/approval); macOS may show
//  a one-time "item added" notification and the user can revoke it in System Settings > General >
//  Login Items. Call refresh() for a bounded asynchronous status check before acting on readiness.
//

import Foundation
import ServiceManagement

enum LoginItem {

    private static let registration = ServiceRegistration(kind: .loginItem)

    /// Last observed status; refresh asynchronously when checking readiness or opening settings.
    static var status: SMAppService.Status { registration.cachedStatus ?? .notFound }

    /// True when the app is registered to launch at login.
    static var isEnabled: Bool { status == .enabled }

    /// True when macOS registered the item but demands the user's OK in System Settings — the
    /// answer it gives once the user has manually disabled the item there; the app can never
    /// silently re-enable past it.
    static var needsApproval: Bool { status == .requiresApproval }

    @discardableResult static func refresh() async -> Bool {
        await registration.refresh() == .enabled
    }

    /// Register the app as a login item. Idempotent; silent (no approval prompt). Returns success.
    @discardableResult
    static func enable() async -> Bool {
        let result = await registration.perform(.register)
        if let error = result.error, !needsApproval {
            Diagnostics.report(.serviceFailed, phase: .setup, reason: "login_item_register", error: error)
            Log("LoginItem: register failed — \(ErrorLabel(error))")
        }
        return isEnabled
    }

    /// The UI "Turn On" action: register, and when macOS answers .requiresApproval (the user
    /// disabled the item in System Settings once), deep-link them there to flip it back on —
    /// that's the only way past it. Both onboarding and Settings → Health call THIS.
    static func enableOrRequestApproval() async {
        await enable()
        if needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Unregister the login item. Best-effort.
    static func disable() async {
        let result = await registration.perform(.unregister)
        if let error = result.error {
            Diagnostics.report(.serviceFailed, phase: .remove, reason: "login_item_unregister", error: error)
            Log("LoginItem: unregister failed — \(ErrorLabel(error))")
        }
    }
}
