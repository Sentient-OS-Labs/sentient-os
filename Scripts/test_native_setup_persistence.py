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
  let setup=NativePermissionSetup(defaults:d)
  switch phase {
  case "legacy":
   d.removePersistentDomain(forName:suite)
   d.set(true, forKey:"computerUse.nativePermissionSetupCompleted")
   d.set("old", forKey:"computerUse.nativePermissionConfirmedProcess")
   precondition(!setup.canAttemptTask)
  case "interrupted":
   precondition(!setup.canAttemptTask,"Legacy clicks and partial setup cannot become readiness")
  case "native-success":
   precondition(!setup.canAttemptTask)
   setup.verified()
   precondition(setup.canAttemptTask)
  case "later-launch":
   precondition(setup.canAttemptTask,"Native success survives restart")
   _ = setup.permissionFailed()
   precondition(!setup.canAttemptTask)
  case "repair-interrupted":
   precondition(!setup.canAttemptTask && setup.recoveryNeeded)
   let old = setup.permissionFailed()
   setup.reset()
   setup.recovered(ifCurrent:old)
   precondition(!setup.canAttemptTask,"Late repair cannot undo reset")
   setup.verified()
  case "repair-finished":
   precondition(setup.canAttemptTask && !setup.recoveryNeeded)
   setup.reset()
  case "after-reset":
   precondition(!setup.canAttemptTask)
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
 for phase in ['legacy','interrupted','native-success','later-launch','repair-interrupted','repair-finished','after-reset']:
  subprocess.run([str(p/'test'),suite,phase],check=True)
