//
//  WakeHelperInstaller.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  Self-install for the root wake helper — so the user never touches Terminal. When the scheduler
//  needs the helper and it isn't installed (or points at a stale binary), the app installs the
//  LaunchDaemon itself behind ONE native "enter your password" dialog (osascript admin):
//    write the plist (with THIS app's current binary path) to a temp file → privileged cp into
//    /Library/LaunchDaemons → chown/chmod → launchctl bootstrap.
//
//  [DECIDED 2026-07-04] This IS the production path. The SMAppService.daemon migration (Login
//  Items toggle) was considered and rejected: this works, it's measured on real hardware, and one
//  native password dialog beats sending users into System Settings. (WakeHelperClient keeps its
//  SMAppService plumbing for the dev cockpit, but nothing user-facing routes there.)
//

import Foundation

enum WakeHelperInstaller {

    private static var label: String { WakeHelperConfig.machServiceName }   // plist Label == Mach service name
    private static var plistPath: String { "/Library/LaunchDaemons/\(label).plist" }

    /// This app's running executable — what the daemon must launch (with --wake-helper).
    private static var currentBinary: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    /// True when the daemon plist exists AND points at this exact binary (a moved/rebuilt-to-a-new
    /// path app fails this, so we reinstall). World-readable, so no privileges needed to check.
    /// The plist FORMAT must be current too: one without AssociatedBundleIdentifiers (added
    /// 2026-07-11) predates the "display as Sentient OS in Login Items" fix and reads stale, so
    /// the next setup pass refreshes it. ⚠️ This answers "are the files right", not "is it
    /// alive" — the System Settings background toggle disables the daemon WITHOUT touching the
    /// plist; anything asking "will the 3am machinery actually work?" must use
    /// `WakeHelperClient.isReachable()` instead.
    static func isInstalledAndCurrent() -> Bool {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              plist["AssociatedBundleIdentifiers"] != nil
        else { return false }
        return args.first == currentBinary
    }

    /// Install (or refresh) the daemon via one admin prompt. Blocking — call off the main actor.
    static func installAsync() async -> Bool {
        await Task.detached { install() }.value
    }

    /// True when the daemon plist exists on disk AT ALL — stale or current. `isInstalledAndCurrent()`
    /// additionally checks the binary path; for uninstall a stale plist still must die.
    static func isInstalled() -> Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// Tear the helper down — the installer's mirror image, behind the same ONE admin prompt:
    /// restore normal sleep, cancel the armed wake (read from the helper's persisted spec, which
    /// must happen BEFORE its dir is removed), bootout + delete the daemon, and sweep the
    /// root-owned support/log files. Clauses are `;`-separated best-effort so a single failure
    /// never blocks the rest (the daemon self-heals disablesleep + the armed wake anyway); the
    /// wake is cancelled by its exact spec, never `cancelall`, so other apps' wakes survive.
    /// No plist on disk = true with no prompt; false = the user declined the password dialog.
    static func uninstallAsync() async -> Bool {
        guard isInstalled() else { return true }
        return await Task.detached { runAdmin(uninstallScript) }.value
    }

    private static var uninstallScript: String {
        "/usr/bin/pmset -a disablesleep 0"
            + "; spec=$(/bin/cat '/Library/Application Support/SentientOS/armed-wake' 2>/dev/null)"
            + "; [ -n \"$spec\" ] && /usr/bin/pmset schedule cancel wake \"$spec\""
            + "; /bin/launchctl bootout system '\(plistPath)' 2>/dev/null"
            + "; /bin/rm -f '\(plistPath)'"
            + "; /bin/rm -rf '/Library/Application Support/SentientOS'"
            + "; /bin/rm -f '/Library/Logs/SentientOS-wakehelper.log'"
    }

    private static func install() -> Bool {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("sentient-wakehelper.plist")
        guard (try? plistXML(binary: currentBinary).write(toFile: tmp, atomically: true, encoding: .utf8)) != nil
        else { return false }

        // Privileged: copy into place, set ownership/perms, (re)load. Full paths for the minimal shell.
        let dest = plistPath
        let sh = "/bin/cp '\(tmp)' '\(dest)'"
            + " && /usr/sbin/chown root:wheel '\(dest)'"
            + " && /bin/chmod 644 '\(dest)'"
            + " && (/bin/launchctl bootout system '\(dest)' 2>/dev/null; /bin/launchctl bootstrap system '\(dest)')"
        return runAdmin(sh)
    }

    private static func plistXML(binary: String) -> String {
        let bin = binary
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(bin)</string><string>\(WakeHelperConfig.helperFlag)</string></array>
          <key>MachServices</key><dict><key>\(label)</key><true/></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
          <key>AssociatedBundleIdentifiers</key><array><string>\(Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS")</string></array>
        </dict></plist>
        """
    }

    /// Runs a shell command as root via the native auth dialog. Returns true on success (false if the
    /// user cancels or it errors).
    private static func runAdmin(_ shell: String) -> Bool {
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(esc)\" with administrator privileges"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}
