//
//  WakeHelperInstaller.swift
//  Sentient OS macOS  ·  Scheduling/
//
//  Self-install for the root wake helper — so the user never touches Terminal. When the scheduler
//  needs the helper and it isn't installed (or points at a stale binary), the app installs the
//  LaunchDaemon itself behind ONE native "enter your password" dialog (osascript admin): root
//  decodes the plist straight into /Library/LaunchDaemons (from a base64 blob in the command — no
//  swappable temp file) → chown/chmod → launchctl bootstrap.
//
//  ⚠️ SECURITY — verified launch (guards against local root escalation): the daemon does NOT point
//  straight at the app binary. A drag-installed app lives in a USER-writable bundle, so pointing a
//  root LaunchDaemon at it would let any same-user process overwrite the binary and get their code
//  run as root at the next wake/boot. Instead ProgramArguments runs, as root:
//      /bin/sh -c "codesign --verify -R='<app DR>' '<app>' && exec '<binary>' --wake-helper"
//  codesign (a root-owned system tool the attacker can't touch) verifies the bundle is our genuine,
//  untampered, correctly-signed code BEFORE exec'ing it; any tamper or foreign signature exits
//  non-zero and `&&` blocks the exec — nothing runs as root. `exec` then REPLACES the shell with the
//  real app binary, so the running daemon IS our app and the XPC "signed like me" gate is unchanged.
//  The requirement is the app's OWN designated requirement, captured at install (signer-agnostic,
//  like the XPC gate) — it survives same-team Sparkle updates but rejects any other signer.
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

    /// This app's running executable — what the daemon ultimately exec's (with --wake-helper).
    private static var currentBinary: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    /// This app's bundle (the `.app`) — what `codesign --verify` checks at launch.
    private static var bundlePath: String { Bundle.main.bundleURL.path }

    /// True when the daemon plist exists AND is the CURRENT verified-launch form for this exact
    /// binary + signature. Fails (→ reinstall) for: a plist missing AssociatedBundleIdentifiers
    /// (pre-2026-07-11), an OLD plain-binary plist (pre-verified-launch), a moved app (binary path
    /// changed), or a re-signed build (designated requirement changed) — so a stale check can never
    /// leave the daemon unable to pass its own codesign gate. World-readable, so no privileges to
    /// check. ⚠️ This answers "are the files right", not "is it alive" — the System Settings
    /// background toggle disables the daemon WITHOUT touching the plist; anything asking "will the
    /// 3am machinery actually work?" must use `WakeHelperClient.isReachable()` instead.
    static func isInstalledAndCurrent() -> Bool {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              plist["AssociatedBundleIdentifiers"] != nil,
              args.first == "/bin/sh", let script = args.last, script.contains(currentBinary)
        else { return false }
        // If we can read our current requirement, it must be the one baked into the launcher (a
        // re-signed build changes it → reinstall). If we can't, don't tear down a working install.
        if let requirement = WakeHelper.selfDesignatedRequirement() { return script.contains(requirement) }
        return true
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
        // The requirement the daemon will verify at launch: the app's OWN designated requirement,
        // captured now. Falls back to the static identifier+anchor rule only if the system can't
        // produce the DR (effectively never for a normally-launched signed app).
        let requirement = WakeHelper.selfDesignatedRequirement() ?? WakeHelperConfig.clientRequirement
        guard let data = plistData(binary: currentBinary, bundle: bundlePath, requirement: requirement) else { return false }

        // Privileged: ROOT writes the plist directly by decoding this base64 (embedded in the
        // app-authored, in-memory command) — no user-writable temp file that a same-user process
        // could swap between our write and root's read, which would otherwise let an attacker install
        // a plist WITHOUT the codesign gate and defeat the whole fix. base64's alphabet has no
        // shell-special characters, so single-quoting it is safe. Then set ownership/perms, (re)load.
        let dest = plistPath
        let sh = "echo '\(data.base64EncodedString())' | /usr/bin/base64 -d > '\(dest)'"
            + " && /usr/sbin/chown root:wheel '\(dest)'"
            + " && /bin/chmod 644 '\(dest)'"
            + " && (/bin/launchctl bootout system '\(dest)' 2>/dev/null; /bin/launchctl bootstrap system '\(dest)')"
        return runAdmin(sh)
    }

    /// The root-run launch command: verify the bundle's signature, then exec the real helper. Only
    /// runs `exec` if `codesign --verify` exits 0 (genuine, untampered, matching signer) — see the
    /// file header. `exec` replaces this shell with the app binary, so the daemon that checks in for
    /// the Mach service IS our binary. All three interpolated values are app-controlled; POSIX
    /// single-quoting (`shq`) keeps the app's own space-bearing path and the quote-bearing
    /// requirement intact for `/bin/sh -c`.
    private static func launchScript(binary: String, bundle: String, requirement: String) -> String {
        "/usr/bin/codesign --verify " + shq("-R=" + requirement) + " " + shq(bundle)
            + " && exec " + shq(binary) + " " + shq(WakeHelperConfig.helperFlag)
    }

    /// POSIX single-quote a value for safe embedding in the `/bin/sh -c` script.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The daemon plist as XML data. Built with PropertyListSerialization (not string templating) so
    /// the quote/bracket-heavy launch script is escaped correctly no matter what.
    private static func plistData(binary: String, bundle: String, requirement: String) -> Data? {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", launchScript(binary: binary, bundle: bundle, requirement: requirement)],
            "MachServices": [label: true],
            "RunAtLoad": true,
            "KeepAlive": false,
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "jesai.Sentient-OS-macOS"],
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
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
