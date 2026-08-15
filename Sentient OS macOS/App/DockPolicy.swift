//
//  DockPolicy.swift
//  Sentient OS macOS
//
//  The Dock icon belongs to the HOME window: it shows while home is up and drops when home
//  closes — auxiliary windows (Settings, Knowledge, Connect AIs) float without a Dock tile,
//  like a menu-bar app's panels, with the menu bar item as the ever-present anchor. Flips
//  NSApp between .regular (home is up) and .accessory (it isn't), driven by NSWindow
//  open/close notifications. `start()` once from AppState; `reevaluate()` does the check.
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
        // The home window appeared/focused → the Dock icon comes back; it closed → the icon drops.
        watch(NSWindow.didBecomeKeyNotification, closing: false)
        watch(NSWindow.willCloseNotification, closing: true)
    }

    /// Show the Dock icon iff the home window is up. `closing` is the window in the middle of a
    /// willClose — still listed in NSApp.windows, so it's excluded from the check.
    func reevaluate(closing: NSWindow? = nil) {
        let homeIsUp = NSApp.windows.contains { window in
            window !== closing
                && SentientOSApp.isHomeWindow(window)
                && (window.isVisible || window.isMiniaturized)
        }
        let target: NSApplication.ActivationPolicy = homeIsUp ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
    }
}
