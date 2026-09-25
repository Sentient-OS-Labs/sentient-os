//
//  Permissions.swift
//  Sentient OS macOS
//
//  Full Disk Access (FDA) gate. The DB sources (WhatsApp / iMessage / Notes) read
//  TCC-protected databases that are simply unreadable without FDA — and there is NO API to
//  *request* it. So the flow is:
//    DETECT   — try reading a known FDA-gated file; a permission error ⇒ not granted.
//    DEEP-LINK — open the Privacy → Full Disk Access pane (we can't flip the switch ourselves).
//    RELAUNCH — FDA changes don't apply to an already-running process; re-exec the app.
//
//  Files (~/Downloads, Desktop, Documents) do NOT need this — they use the standard per-folder
//  TCC prompt. FDA is specifically the unlock for the database sources (Phase 3).
//
//  NOTE: the probe paths + Settings deep-link URLs may need re-testing on each new macOS.
//

import Foundation
import AppKit
import ApplicationServices // AXIsProcessTrusted — Sentient's own Accessibility grant (the cua driver's hands)
import CoreGraphics // CGPreflight/RequestScreenCaptureAccess — Sentient's own Screen Recording grant
import SQLite3    // Read-only TCC status checks (when Full Disk Access is available)
import Carbon

enum Permissions {

    /// OpenAI's native helper receives the Apple Events permission request.
    static let computerUseHelperBundleID = OpenAIComputerUse.bundleID

    /// Apple owns permission writes. Uninstall resets only Sentient's Apple Events grants using
    /// the supported system utility; normal launch and Factory Reset never revoke them.
    static func resetAutomationForUninstall() async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        _ = try? await CodexCLI.executeAsync(binary: "/usr/bin/tccutil",
            args: ["reset", "AppleEvents", bundleID], stdinText: nil, cwd: nil, timeout: 15)
    }

    nonisolated enum AutomationState: Equatable, Sendable {
        case granted, notAsked, denied, unavailable
    }

    /// Called only after starting the helper, on the user's Allow action. A missing process
    /// (-600) is unavailable, not an explicit denial. Never block AppKit's main run loop.
    static func nativeAutomationState(ask: Bool = false) async -> AutomationState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: OpenAIComputerUse.bundleID)
                let code = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
                let state: AutomationState
                switch code {
                case noErr: state = .granted
                case -1743: state = .denied
                case -1744: state = .notAsked
                default: state = .unavailable
                }
                continuation.resume(returning: state)
            }
        }
    }

    // MARK: - TCC status reads (FDA-powered; the grants themselves belong to the user)
    //
    // ⚠️ Accessibility and Screen Recording are enforced from the SYSTEM TCC database
    // (/Library/Application Support/com.apple.TCC/TCC.db), which is owned by root AND protected by
    // SIP — nothing but Apple's own tccd can write it (not us, not even root). The user grants them
    // in System Settings (or through the native prompt where one exists); we can only READ their
    // status, which FDA allows for both databases.

    /// The services enforced from the SYSTEM TCC.db (SIP-protected, read-only for us). Everything else
    /// lives in the per-user TCC.db.
    private static let systemTCCServices: Set<String> =
        ["kTCCServiceAccessibility", "kTCCServiceScreenCapture", "kTCCServiceSystemPolicyAllFiles",
         "kTCCServiceListenEvent", "kTCCServicePostEvent"]

    private static func tccDBPath(for service: String) -> String {
        systemTCCServices.contains(service)
            ? "/Library/Application Support/com.apple.TCC/TCC.db"
            : FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
    }

    /// Read whether a TCC grant is currently ALLOWED (auth_value == 2) for a client bundle id — from the
    /// correct database for the service (system DB for Accessibility/ScreenCapture, else the user DB).
    /// Requires Full Disk Access to read; any failure ⇒ false (treated as not-granted).
    static func isTCCGranted(service: String, clientBundleID: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(tccDBPath(for: service), &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT auth_value FROM access WHERE service=? AND client=? AND client_type=0 LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, service, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, clientBundleID, -1, TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 2
    }

    // MARK: - Sentient's own Screen Recording (Notch Magic captures the screen for computer-use context)

    /// True iff Sentient already holds Screen Recording. `CGPreflight…` never prompts.
    static func hasScreenRecording() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Ask for Screen Recording. On first ask this surfaces the system prompt and adds Sentient to the
    /// list; the grant only takes effect after an app restart. Returns the current (pre-restart) status.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Sentient's own Accessibility (the cua driver's hands)

    /// True iff Sentient already holds Accessibility. `AXIsProcessTrusted()` never prompts, and it
    /// answers for THIS process — which is exactly the right question here: cua-driver is spawned
    /// inside Sentient's responsibility chain, so macOS charges its clicks and AX reads to us.
    /// (Unlike Screen Recording, this one is live: a grant flipped in Settings is visible without a
    /// relaunch, because AX is checked per call rather than cached at capture-session setup.)
    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    /// Ask for Accessibility. The one-shot system prompt ("… would like to control this computer")
    /// with a Open System Settings button; macOS shows it once per app identity, so a user who has
    /// already dismissed it gets nothing and needs the Settings pane instead (the gate's Fix…).
    /// Returns the pre-grant status.
    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    // MARK: - Settings deep-links (we can't flip these toggles; the user does)

    @MainActor static func openMicrophoneSettings() { openPrivacy("Privacy_Microphone") }
    @MainActor static func openSpeechRecognitionSettings() { openPrivacy("Privacy_SpeechRecognition") }
    @MainActor static func openScreenRecordingSettings() { openPrivacy("Privacy_ScreenCapture") }
    @MainActor static func openAutomationSettings() { openPrivacy("Privacy_Automation") }
    @MainActor static func openAccessibilitySettings() { openPrivacy("Privacy_Accessibility") }

    private static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Canonical FDA-gated files. We can READ any of these *only* with Full Disk Access. We try
    /// several because any single one may be absent on a given Mac (no Messages history, no Safari
    /// bookmarks…): the first one that actually exists is our verdict.
    private static var fdaProbePaths: [(label: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ("imessage", "\(home)/Library/Messages/chat.db"),            // the classic FDA probe
            ("safari",   "\(home)/Library/Safari/Bookmarks.plist"),      // usually present
            ("tcc",      "\(home)/Library/Application Support/com.apple.TCC/TCC.db"),
        ]
    }

    /// The full result of the FDA probe (§7.22): whether it's granted, WHICH probe decided it, and
    /// the last errno. The errno + `none` combo is what tells true-denial (EPERM/EACCES) apart from
    /// Terminal-TCC-attribution / all-probes-missing (ENOENT / none) — the single highest-value
    /// empty-morning signal, which the plain Bool throws away.
    static func fdaProbeDetail() -> (granted: Bool, matched: String, errno: Int32) {
        var lastErrno: Int32 = 0
        for probe in fdaProbePaths {
            let fd = open(probe.path, O_RDONLY)
            if fd >= 0 { close(fd); return (true, probe.label, 0) }
            lastErrno = errno
            if errno == EPERM || errno == EACCES { return (false, probe.label, errno) }
            // else (e.g. ENOENT) — this probe isn't present; try the next.
        }
        return (false, "none", lastErrno)
    }

    /// True iff Full Disk Access is granted to *this* process (i.e. we can read a protected file).
    /// Nothing to probe ⇒ assume not granted (the grant flow is idempotent, so a false negative is
    /// harmless).
    static func hasFullDiskAccess() -> Bool { fdaProbeDetail().granted }

    /// Emit the FDA probe as a diagnostics event when it's NOT cleanly granted — the actionable
    /// empty-morning case (a 3am run that silently reads nothing from the DB sources). Structure only:
    /// no paths, just the probe label + errno. Call once at run/arm time, not per item.
    static func reportProbe() {
        let d = fdaProbeDetail()
        guard !d.granted else { return }   // clean grant is the healthy case — don't spam
        CrashReporting.captureEvent("fda.probe", level: .warning,
            tags: ["result": "denied", "which_probe": d.matched],
            extra: ["errno": String(d.errno)],
            fingerprint: ["fda", "probe", d.matched])
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
