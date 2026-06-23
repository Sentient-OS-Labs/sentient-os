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
//  This is the dev/testing path; production will swap it for SMAppService.daemon (a one-click
//  System Settings approval, no password). Same daemon, same plist — only the install UX differs.
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
    static func isInstalledAndCurrent() -> Bool {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String]
        else { return false }
        return args.first == currentBinary
    }

    /// Install (or refresh) the daemon via one admin prompt. Blocking — call off the main actor.
    static func installAsync() async -> Bool {
        await Task.detached { install() }.value
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
