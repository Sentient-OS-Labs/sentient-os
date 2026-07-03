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
//  Login Items, which is why `isEnabled` reads the live status rather than a cached bool.
//

import Foundation
import ServiceManagement

enum LoginItem {

    private static var service: SMAppService { .mainApp }

    /// Live status straight from the framework (the user can revoke in System Settings at any time).
    static var status: SMAppService.Status { service.status }

    /// True when the app is registered to launch at login.
    static var isEnabled: Bool { service.status == .enabled }

    /// Register the app as a login item. Idempotent; silent (no approval prompt). Returns success.
    @discardableResult
    static func enable() -> Bool {
        guard service.status != .enabled else { return true }
        do { try service.register(); Log("LoginItem: registered (status=\(service.status.rawValue))"); return true }
        catch { Log("LoginItem: register failed — \(error)"); return false }
    }

    /// Unregister the login item. Best-effort.
    static func disable() async {
        do { try await service.unregister(); Log("LoginItem: unregistered") }
        catch { Log("LoginItem: unregister failed — \(error)") }
    }
}
