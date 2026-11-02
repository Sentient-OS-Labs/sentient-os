#!/usr/bin/env python3
"""Check permission grouping with synthetic capability states; no macOS grants or app launch."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
TEST = r'''
import Foundation
@main struct Checks {
    static func state(protected: Bool = true, readable: Bool = true, screen: Bool = true,
                      installed: Bool = true, verified: Bool = true, problem: Bool = false,
                      overnight: Bool = true, wake: Bool = true, voice: Bool = true,
                      notifications: Bool = true) -> PermissionsOverview {
        .init(hasProtectedSources: protected, protectedSourcesReadable: readable, screenGranted: screen,
              helperInstalled: installed, helperVerified: verified, helperProblem: problem,
              overnightRequested: overnight, wakeReady: wake, voiceGranted: voice,
              notificationsGranted: notifications)
    }
    static func main() {
        let ready = state()
        precondition(ready.visible.isEmpty && ready.optional.isEmpty && ready.granted.count == 6)
        let optional = state(voice: false, notifications: false)
        precondition(optional.visible.isEmpty && optional.optional == [.voice, .notifications])
        precondition(!PermissionsOverview.shouldOpenTroubleshooting(connectionProblem: false,
            sourceProblem: false, helperProblem: false, runtimeMissing: false))
        let unknown = state(verified: false)
        precondition(unknown.visible == [.computerUse] && !unknown.granted.contains(.computerUse))
        precondition(unknown.states[.computerUse] == .unverified)
        let revoked = state(screen: false, verified: true, problem: true)
        precondition(revoked.visible == [.screenRecording, .computerUse])
        precondition(!revoked.granted.contains(.screenRecording) && !revoked.granted.contains(.computerUse))
        let unused = state(protected: false, readable: false, overnight: false, wake: false)
        precondition(unused.visible.isEmpty && !unused.granted.contains(.fullDisk)
            && !unused.granted.contains(.overnightWake))
        precondition(state(readable: false, wake: false).visible == [.fullDisk, .overnightWake])
        let missingRuntime = state(installed: false, verified: false)
        precondition(!missingRuntime.visible.contains(.computerUse)
            && !missingRuntime.granted.contains(.computerUse))
        for reason in 0..<4 {
            precondition(PermissionsOverview.shouldOpenTroubleshooting(connectionProblem: reason == 0,
                sourceProblem: reason == 1, helperProblem: reason == 2, runtimeMissing: reason == 3))
        }
        print("PASS: ready, optional, unverified, revoked, unused, missing-runtime, and problem-expansion cases")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='permissions-overview-') as directory:
    path = Path(directory)
    (path/'Checks.swift').write_text(TEST)
    subprocess.run(['xcrun','swiftc','-parse-as-library',
        str(ROOT/'Sentient OS macOS/Views/Settings/PermissionsOverview.swift'),str(path/'Checks.swift'),
        '-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
