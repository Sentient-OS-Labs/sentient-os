//
//  DockPolicy.swift
//  Sentient OS macOS
//
//  The Dock icon belongs to the main window, on Home, Settings, or Knowledge. It drops when
//  that window closes — auxiliary guides (Connect AIs) float without a Dock tile,
//  like a menu-bar app's panels, with the menu bar item as the ever-present anchor. Flips
//  NSApp between .regular (home is up) and .accessory (it isn't), driven by NSWindow
//  open/close notifications. `start()` once from AppState; `reevaluate()` does the check.
//  Pending computer-use setup keeps the Dock entry available even while the home is hidden.
//

import AppKit

@MainActor
final class DockPolicy {

    private var observers: [NSObjectProtocol] = []

    /// Begin watching windows once. The app delegate applies the initial policy after launch;
    /// subsequent main-window open/close events keep the Dock in sync.
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
        // Keep a Dock entry while setup is pending, even when its window was closed/minimized.
        let target: NSApplication.ActivationPolicy = homeIsUp || ComputerUseUpgrade.shared.isBlockingInterface
            ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
    }
}
