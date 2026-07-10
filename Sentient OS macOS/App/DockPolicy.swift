//
//  DockPolicy.swift
//  Sentient OS macOS
//
//  Hides the Dock icon when every real Sentient window is closed — the menu bar item is the
//  app's ever-present home, so an empty Dock tile is just clutter. Flips NSApp between
//  .regular (a window is up) and .accessory (none are), driven by NSWindow open/close
//  notifications. `start()` once from AppState; `reevaluate()` does the counting.
//

import AppKit

@MainActor
final class DockPolicy {

    private var observers: [NSObjectProtocol] = []

    /// Begin watching windows. Call once (AppState.init). We deliberately DON'T evaluate eagerly:
    /// the app launches .regular (no LSUIElement), the home/onboarding window opens and keeps us
    /// there, and we only ever drop to .accessory on a real close — so there's no launch flicker.
    func start() {
        let nc = NotificationCenter.default
        func watch(_ name: Notification.Name, closing: Bool) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.reevaluate(closing: closing ? note.object as? NSWindow : nil)
                }
            })
        }
        // A window appeared/focused → the Dock icon comes back; the last one closed → it drops.
        watch(NSWindow.didBecomeKeyNotification, closing: false)
        watch(NSWindow.willCloseNotification, closing: true)
    }

    /// Show the Dock icon iff at least one real Sentient window is up. `closing` is the window in
    /// the middle of a willClose — still listed in NSApp.windows, so it's excluded from the count.
    func reevaluate(closing: NSWindow? = nil) {
        let hasRealWindow = NSApp.windows.contains { window in
            window !== closing
                && !(window is NSPanel)                    // the notch + permission-drag panels are always-on furniture
                && window.canBecomeMain                    // skips the status-item / menu-bar helper windows
                && (window.isVisible || window.isMiniaturized)
        }
        let target: NSApplication.ActivationPolicy = hasRealWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
    }
}
