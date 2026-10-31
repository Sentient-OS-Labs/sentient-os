#!/usr/bin/env python3
"""Replay macOS-driven restarts against actual setup receipts in an isolated defaults suite.
No app launch, real permissions, helper, model, user data, or system-service changes.
"""
from pathlib import Path
import subprocess,tempfile,uuid
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
fixture=r'''
import Foundation
@MainActor enum HealthCaution {static let nativeComputerUseEverReadyKey="fixture.verified"}
@main struct Main {
 @MainActor static func main() {
  let suite=CommandLine.arguments[1],phase=CommandLine.arguments[2]
  let d=UserDefaults(suiteName:suite)!
  let setup=NativePermissionSetup(defaults:d,processID:phase)
  switch phase {
  case "grant-helper":
   d.removePersistentDomain(forName:suite)
   setup.requestRestart();setup.beganGrant(.accessibility);setup.didDrop(.accessibility)
   setup.requestRestart();setup.beganGrant(.screenRecording);setup.didDrop(.screenRecording)
   precondition(setup.needsRestart && !setup.canAttemptTask)
  case "macos-reopened":
   precondition(setup.dropped == [.accessibility,.screenRecording],"Lost completed drag receipts")
   precondition(setup.hasRestarted && setup.canAttemptTask,"OS restart must count without our restart button")
   precondition(setup.stepIsApplied(.accessibility) && setup.stepIsApplied(.screenRecording))
   setup.preparedAfterRestart()
   setup.requestRestart() // Remaining Sentient Screen Recording step, then a second OS restart.
   precondition(setup.stepIsApplied(.accessibility) && setup.stepIsApplied(.screenRecording),"Helper steps must remain done")
  case "second-reopen":
   precondition(setup.canAttemptTask && setup.hasVisited(.accessibility) && setup.hasVisited(.screenRecording))
   setup.preparedAfterRestart()
  case "later-launch":
   precondition(setup.canAttemptTask && !setup.needsRestart,"Normal relaunch must retain completed setup")
   _=setup.permissionFailed()
   precondition(!setup.canAttemptTask && !setup.stepIsApplied(.screenRecording),"Actual denial must override setup history")
   setup.reset();d.removeObject(forKey:HealthCaution.nativeComputerUseEverReadyKey)
  case "after-reset":
   precondition(!setup.canAttemptTask && setup.needsRestart && setup.dropped.isEmpty,"Reset must remove progress receipts")
   precondition(!setup.hasVisited(.accessibility) && !setup.hasVisited(.screenRecording))
   d.removePersistentDomain(forName:suite)
  default:fatalError("phase")
  }
  print("PASS setup persistence: \(phase)")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-native-setup-restart-') as tmp:
 p=Path(tmp);(p/'Main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',str(p/'Main.swift'),
  str(APP/'Views/Permissions/NativePermissionSetup.swift'),'-o',str(p/'test')],check=True)
 suite='sentient.native-setup-fixture.'+str(uuid.uuid4())
 for phase in ['grant-helper','macos-reopened','second-reopen','later-launch','after-reset']:
  subprocess.run([str(p/'test'),suite,phase],check=True)
