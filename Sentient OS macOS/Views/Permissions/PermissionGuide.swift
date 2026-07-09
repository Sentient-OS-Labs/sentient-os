//
//  PermissionGuide.swift
//  Sentient OS macOS
//
//  The floating System-Settings companion for grants Sentient can't prompt for. `guide(...)` opens
//  the right Privacy pane AND raises a small OLED-black panel that flies to the Settings window and
//  follows it (SettingsWindowTracker). Two modes: DRAG (the panel carries an .app card the user
//  drags straight into the permission list — Sentient itself for Full Disk Access, OpenAI's Codex
//  Computer Use helper for its Accessibility/Screen Recording) and INSTRUCTION (toggle lists with
//  no drag target — "flip the switch": Sentient's own Screen Recording, Login Items approval).
//  One shared instance, one active panel; closing Settings auto-dismisses.
//
//  Key methods: guide(_:dragging:) · close()
//  Flow mechanics adapted from PermissionFlow (github.com/jaywcjlove/PermissionFlow, MIT).
//

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class PermissionGuide {

    static let shared = PermissionGuide()
    private init() {}

    /// The System Settings destinations the guide knows how to escort the user into.
    enum Pane {
        case fullDiskAccess
        case accessibility
        case screenRecording
        case loginItems

        /// The list's name, for the panel copy.
        var title: String {
            switch self {
            case .fullDiskAccess:  return "Full Disk Access"
            case .accessibility:   return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .loginItems:      return "Login Items"
            }
        }

        /// Open the matching System Settings page (deep-links live in Permissions/SMAppService).
        fileprivate func openSettings() {
            switch self {
            case .fullDiskAccess:  Permissions.openFullDiskAccessSettings()
            case .accessibility:   Permissions.openAccessibilitySettings()
            case .screenRecording: Permissions.openScreenRecordingSettings()
            case .loginItems:      SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    /// What the panel is currently guiding (nil = no panel up). `appURL` nil = instruction mode.
    struct Job {
        let pane: Pane
        let appURL: URL?
    }

    private(set) var job: Job?
    /// Drives the header arrow animation while the app card is mid-drag.
    private(set) var isDraggingApp = false
    /// Shows the "reopen Settings" affordance when Settings slipped behind something.
    private(set) var isSettingsFrontmost = false

    private let tracker = SettingsWindowTracker()
    private var panel: PermissionDragPanel?
    private var pendingLaunchSourceFrame: CGRect?
    private var frontmostObserver: NSObjectProtocol?

    /// The panel's one-line instruction, mode-aware.
    var instruction: AttributedString {
        guard let job else { return AttributedString("") }
        let appName = job.appURL.map { FileManager.default.displayName(atPath: $0.path) } ?? "Sentient OS"
        let markdown: String
        if job.appURL != nil {
            markdown = "Drag **\(appName)** into the list, then flip its switch on."
        } else if job.pane == .loginItems {
            markdown = "Flip **Sentient OS** on under \"Allow in the Background\"."
        } else {
            markdown = "Flip **Sentient OS** on in the list."
        }
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    /// Open the pane in System Settings and raise the floating companion panel. The launch
    /// animation flies from the current mouse location (the button the user just pressed).
    func guide(_ pane: Pane, dragging appURL: URL?) {
        close()
        job = Job(pane: pane, appURL: appURL)
        let mouse = NSEvent.mouseLocation
        pendingLaunchSourceFrame = CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
        pane.openSettings()

        let panel = PermissionDragPanel(guide: self)
        self.panel = panel
        if let sourceFrame = pendingLaunchSourceFrame {
            panel.show(at: sourceFrame)
        }

        updateFrontmostState()
        observeFrontmostApplication()
        tracker.onFrameChange = { [weak self] frame in
            Task { @MainActor [weak self] in self?.settingsFrameChanged(frame) }
        }
        tracker.onTrackingEnded = { [weak self] in
            Task { @MainActor [weak self] in self?.close() }   // Settings quit → panel goes too
        }
        tracker.startTracking()
        Log("PermissionGuide: guiding \(pane.title) (\(appURL == nil ? "instruction" : "drag"))")
    }

    /// Dismiss the panel and stop tracking. Safe to call when nothing is up.
    func close() {
        tracker.stopTracking()
        panel?.close()
        panel = nil
        job = nil
        pendingLaunchSourceFrame = nil
        isDraggingApp = false
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
            self.frontmostObserver = nil
        }
    }

    /// The panel's gear — bring the (possibly buried) Settings pane back to front.
    func reopenSettings() {
        job?.pane.openSettings()
        panel?.orderFrontRegardless()
    }

    /// The drag source reports drag begin/end; the panel goes mouse-transparent so System
    /// Settings underneath can receive the drop.
    func setDragging(_ dragging: Bool) {
        isDraggingApp = dragging
        panel?.setDraggingPassthrough(dragging)
    }

    /// Keep System Settings visually frontmost whenever the panel is poked (it's non-activating).
    func keepSettingsVisible() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.activate()
        panel?.orderFrontRegardless()
    }

    private func settingsFrameChanged(_ frame: CGRect) {
        guard let panel else { return }
        if let sourceFrame = pendingLaunchSourceFrame {
            panel.present(from: sourceFrame, to: frame)
            pendingLaunchSourceFrame = nil
        } else {
            panel.snap(to: frame)
        }
    }

    private func observeFrontmostApplication() {
        guard frontmostObserver == nil else { return }
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateFrontmostState() }
        }
    }

    private func updateFrontmostState() {
        isSettingsFrontmost =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
    }
}
