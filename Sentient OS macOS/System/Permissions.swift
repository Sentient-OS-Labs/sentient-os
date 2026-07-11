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
import CoreGraphics // CGPreflight/RequestScreenCaptureAccess — Sentient's own Screen Recording grant
import Security   // SecCode/SecStaticCode → an app's Designated Requirement (the TCC csreq blob)
import SQLite3    // direct, parameterized write into the user's TCC.db (we already hold Full Disk Access)

enum Permissions {

    // MARK: - Computer use: Automation consent for Codex's helper
    //
    // To run computer use we spawn `codex`, so macOS makes *us* (Sentient OS) the TCC-responsible
    // app for everything it does — and codex talks to its bundled helper (`com.openai.sky.CUAService`,
    // ~/.codex/computer-use/Codex Computer Use.app) over Apple Events, which is gated by the
    // Automation grant "Sentient OS → Codex Computer Use". Terminal and Warp already hold it (that's
    // why a manual run works); a fresh Sentient doesn't, so the first call (`list_apps`) blocks.
    //
    // We CANNOT pre-create that grant ourselves: `AEDeterminePermissionToAutomateTarget` returns
    // procNotFound for this service even while it's running (it exposes no idle Apple Event endpoint),
    // so there's no prompt to show. The grant is instead created the same way Terminal/Warp got it —
    // by letting codex drive a REAL computer-use run, which surfaces the one-time consent prompt (now
    // that we declare NSAppleEventsUsageDescription). The dev Permissions panel runs a tiny benign
    // probe to trigger exactly that; thereafter every run sails through. See PermissionsView.

    // MARK: Granting the Automation entry directly (FDA-powered, device- & signer-agnostic)

    /// The Codex Computer Use helper — the Apple Events TARGET we grant ourselves the right to drive.
    static let computerUseHelperBundleID = "com.openai.sky.CUAService"

    enum GrantError: LocalizedError {
        case noFDA, helperNotFound, requirement(String), tcc(String)
        var errorDescription: String? {
            switch self {
            case .noFDA:              return "Full Disk Access is required to write the permission."
            case .helperNotFound:     return "Couldn't find the Codex Computer Use helper app on disk."
            case .requirement(let m): return "Couldn't read a code-signature requirement (\(m))."
            case .tcc(let m):         return "Couldn't write the TCC database (\(m))."
            }
        }
    }

    /// Resolve the installed Codex Computer Use helper (any copy — they share one signed identity).
    static func computerUseHelperURL() -> URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: computerUseHelperBundleID) { return u }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/computer-use/Codex Computer Use.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Grant THIS running app the Automation right to control the Codex Computer Use helper, by
    /// writing the `kTCCServiceAppleEvents` row straight into the user's TCC database. Both
    /// code-requirement blobs (ours + the helper's) are generated at runtime from the live signed
    /// bundles — so it's correct for ANY signer (your Developer-ID release, a dev cert, or an OSS
    /// self-build) and writes NOTHING device-specific (boot_uuid stays the schema default 'UNUSED').
    /// Requires Full Disk Access (the write key, which Sentient holds anyway). Idempotent
    /// (INSERT OR REPLACE), then reloads tccd. Returns a short receipt.
    @discardableResult
    static func grantComputerUseAutomation() throws -> String {
        guard hasFullDiskAccess() else { throw GrantError.noFDA }
        guard let helper = computerUseHelperURL() else { throw GrantError.helperNotFound }

        let csreq  = try selfRequirementData()              // our DR     → `csreq`
        let target = try requirementData(forAppAt: helper)  // helper's DR → `indirect_object_code_identity`
        let bundleID = Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"

        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (Full Disk Access?)"
            sqlite3_close(db); throw GrantError.tcc(m)
        }
        defer { sqlite3_close(db) }

        // Only the stable core columns; everything else takes its schema default (incl.
        // boot_uuid='UNUSED' → nothing device-specific). auth_value 2 = allowed, auth_reason 2 = user consent.
        let sql = """
        INSERT OR REPLACE INTO access
          (service, client, client_type, auth_value, auth_reason, auth_version,
           csreq, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags)
        VALUES ('kTCCServiceAppleEvents', ?, 0, 2, 2, 1, ?, 0, ?, ?, 0);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw GrantError.tcc(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLite copies the bytes at bind time
        sqlite3_bind_text(stmt, 1, bundleID, -1, TRANSIENT)
        _ = csreq.withUnsafeBytes  { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(csreq.count),  TRANSIENT) }
        sqlite3_bind_text(stmt, 3, computerUseHelperBundleID, -1, TRANSIENT)
        _ = target.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(target.count), TRANSIENT) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw GrantError.tcc(String(cString: sqlite3_errmsg(db)))
        }

        reloadTCCD()
        return "granted \(bundleID) → Codex Computer Use (csreq \(csreq.count)B · target \(target.count)B)"
    }

    /// Undo `grantComputerUseAutomation()` — Uninstall's sweep: DELETE our kTCCServiceAppleEvents
    /// row (scoped to our bundle id AND the Codex helper target, so no other app's Automation
    /// grants are ever touched) from the USER TCC database, then reload tccd. Best-effort: no FDA,
    /// no DB, or no row is a quiet no-op — an orphaned row is inert once the app is gone. The
    /// system-DB rows (Accessibility / Screen Recording) are SIP-protected and not ours to remove.
    static func revokeComputerUseAutomation() {
        guard hasFullDiskAccess() else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }

        let sql = """
        DELETE FROM access WHERE service='kTCCServiceAppleEvents'
          AND client=? AND client_type=0 AND indirect_object_identifier=?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, bundleID, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, computerUseHelperBundleID, -1, TRANSIENT)

        if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 {
            reloadTCCD()
            Log("Permissions: removed the Automation grant row (\(bundleID) → Codex Computer Use)")
        }
    }

    /// Quiet self-heal for the Automation grant (Sentient → Codex Computer Use over Apple Events):
    /// probe, and if it's missing while the prerequisites exist (FDA + the helper on disk), silently
    /// re-grant in the background — idempotent, no UI, just a log line. The user has no job here.
    /// Called from Settings → Health on open and from the computer-use gate before the first fire.
    static func selfHealComputerUseAutomation(context: String) {
        guard hasFullDiskAccess(), computerUseHelperURL() != nil else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"
        guard !isTCCGranted(service: "kTCCServiceAppleEvents", clientBundleID: bundleID) else { return }
        Task.detached {
            do {
                let receipt = try grantComputerUseAutomation()
                Log("\(context): automation self-heal — \(receipt)")
            } catch {
                Log("\(context): automation self-heal failed — \(error)")
            }
        }
    }

    // MARK: - Codex helper: Accessibility + Screen Recording — READ-ONLY status (can't be granted by us)
    //
    // Computer use spawns `codex`, which launches Codex's bundled helper app ("Codex Computer Use.app",
    // com.openai.sky.CUAService) as its own process — and THAT app is what moves the mouse / types
    // (Accessibility) and reads the screen (Screen Recording). ⚠️ Those two services are enforced from
    // the SYSTEM TCC database (/Library/Application Support/com.apple.TCC/TCC.db), which is owned by root
    // AND protected by SIP — nothing but Apple's own tccd can write it (not us, not even root). So unlike
    // the Automation grant (kTCCServiceAppleEvents, which lives in the *user* DB and IS writable with
    // FDA), we CANNOT grant these — the user grants them in System Settings, or macOS prompts the first
    // time computer use runs. We can only READ their status (FDA lets us read the system DB).

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

    // MARK: - Settings deep-links (we can't flip these toggles; the user does)

    @MainActor static func openMicrophoneSettings() { openPrivacy("Privacy_Microphone") }
    @MainActor static func openSpeechRecognitionSettings() { openPrivacy("Privacy_SpeechRecognition") }
    @MainActor static func openScreenRecordingSettings() { openPrivacy("Privacy_ScreenCapture") }
    @MainActor static func openAccessibilitySettings() { openPrivacy("Privacy_Accessibility") }
    @MainActor static func openAutomationSettings() { openPrivacy("Privacy_Automation") }

    private static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Serialize the RUNNING app's Designated Requirement — exactly what TCC stores as `csreq`.
    private static func selfRequirementData() throws -> Data {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw GrantError.requirement("SecCodeCopySelf") }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { throw GrantError.requirement("SecCodeCopyStaticCode") }
        return try requirementData(of: stat)
    }

    /// Serialize the Designated Requirement of an app bundle on disk.
    private static func requirementData(forAppAt url: URL) throws -> Data {
        var stat: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &stat) == errSecSuccess, let stat else {
            throw GrantError.requirement("SecStaticCodeCreateWithPath")
        }
        return try requirementData(of: stat)
    }

    private static func requirementData(of stat: SecStaticCode) throws -> Data {
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(stat, [], &req) == errSecSuccess, let req else {
            throw GrantError.requirement("SecCodeCopyDesignatedRequirement")
        }
        var data: CFData?
        guard SecRequirementCopyData(req, [], &data) == errSecSuccess, let data else {
            throw GrantError.requirement("SecRequirementCopyData")
        }
        return data as Data
    }

    /// Reload the per-user TCC daemon so the new row applies immediately (tccd caches on launch).
    private static func reloadTCCD() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["tccd"]
        try? p.run()
        p.waitUntilExit()
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
