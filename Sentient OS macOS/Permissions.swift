//
//  Permissions.swift
//  Sentient OS macOS
//
//  Full Disk Access (FDA) gate (Arch §7.1). The DB sources (WhatsApp / iMessage / Notes) read
//  TCC-protected databases that are simply unreadable without FDA — and there is NO API to
//  *request* it. So the flow is:
//    DETECT   — try reading a known FDA-gated file; a permission error ⇒ not granted.
//    DEEP-LINK — open the Privacy → Full Disk Access pane (we can't flip the switch ourselves).
//    RELAUNCH — FDA changes don't apply to an already-running process; re-exec the app.
//
//  Files (~/Downloads, Desktop, Documents) do NOT need this — they use the standard per-folder
//  TCC prompt. FDA is specifically the unlock for the database sources (Phase 3).
//
//  NOTE: the probe paths + Settings URLs are per Arch §7.1 and flagged there for per-OS testing.
//

import Foundation
import AppKit

enum Permissions {

    /// Canonical FDA-gated files. We can READ any of these *only* with Full Disk Access. We try
    /// several because any single one may be absent on a given Mac (no Messages history, no Safari
    /// bookmarks…): the first one that actually exists is our verdict.
    private static var fdaProbePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Messages/chat.db",            // iMessage DB — the classic FDA probe
            "\(home)/Library/Safari/Bookmarks.plist",      // Safari — usually present
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    /// True iff Full Disk Access is granted to *this* process (i.e. we can read a protected file).
    /// Logic: open each probe read-only — success ⇒ granted; a clear EPERM/EACCES ⇒ denied;
    /// ENOENT (file genuinely absent) ⇒ try the next. Nothing to probe ⇒ assume not granted
    /// (the grant flow is idempotent, so a false negative is harmless).
    static func hasFullDiskAccess() -> Bool {
        for path in fdaProbePaths {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return true }
            if errno == EPERM || errno == EACCES { return false }
            // else (e.g. ENOENT) — this probe isn't present; try the next.
        }
        return false
    }

    /// Open System Settings → Privacy & Security → Full Disk Access. We cannot toggle the switch
    /// programmatically; the user flips it, then restarts.
    @MainActor
    static func openFullDiskAccessSettings() {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
    }

    /// Re-exec the app — an FDA grant only takes effect in a fresh process. Launches a new
    /// instance via `open -n`, then terminates this one.
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
