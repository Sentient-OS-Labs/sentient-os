#!/usr/bin/env python3
"""Real VoiceCapture authorization/release races with inert microphone engine, no TCC changes."""
from pathlib import Path
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS/Notch Magic'
SWIFT=r'''
import Foundation
final class ScribeRealtimeEngine {
 static var starts=0,stops=0,cancels=0
 var onTranscript:((String)->Void)?,onLevel:((Float)->Void)?,onReady:(()->Void)?,onFailure:((Error)->Void)?
 var transcript="fixture"
 func start() throws {Self.starts+=1}
 func stopCapturing(){Self.stops+=1}
 func finish()async throws->String{"fixture"}
 func cancel(){Self.cancels+=1}
}
@main struct Tests {
 static func main()async throws {
  var checks=0
  func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
  var permission:CheckedContinuation<Bool,Never>?
  let voice=VoiceCapture(authorize:{await withCheckedContinuation {permission=$0}},explain:{true})
  let pending=Task {try await voice.start()}
  try await Task.sleep(for:.milliseconds(20))
  voice.stopCapturing()
  permission?.resume(returning:true);permission=nil
  do{try await pending.value;fatalError("late start")}catch is CancellationError{checks+=1}
  check(ScribeRealtimeEngine.starts==0,"release during permission cannot open mic late")
  let old=Task {try await voice.start()}
  try await Task.sleep(for:.milliseconds(20));let oldPermission=permission
  voice.cancel()
  let fresh=Task {try await voice.start()}
  try await Task.sleep(for:.milliseconds(20));let newPermission=permission
  oldPermission?.resume(returning:true)
  do{try await old.value;fatalError("old generation")}catch is CancellationError{checks+=1}
  check(ScribeRealtimeEngine.starts==0,"stale generation cannot start next session")
  newPermission?.resume(returning:true);try await fresh.value
  check(ScribeRealtimeEngine.starts==1,"fresh authorization starts exactly one mic")
  voice.stopCapturing()
  check(ScribeRealtimeEngine.stops==1,"mic shutdown is synchronous")
  let final=try await voice.stopAndTranscribe()
  check(final=="fixture","final transcript returns normally")
  var permissionAsked=false
  let declined=VoiceCapture(authorize:{permissionAsked=true;return true},explain:{false})
  do{try await declined.start();fatalError("declined consent")}catch is CancellationError{checks+=1}
  check(!permissionAsked && ScribeRealtimeEngine.starts==1,"declined cloud explanation never requests mic")
  let denied=VoiceCapture(authorize:{false},explain:{true})
  do{try await denied.start();fatalError("denied")}catch VoiceError.notAuthorized{checks+=1}
  check(ScribeRealtimeEngine.starts==1,"denied permission never captures")
  print("PASS: \(checks) actual VoiceCapture permission/release checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-dictation-permissions-') as directory:
 path=Path(directory);fixture=path/'test.swift';fixture.write_text(SWIFT);binary=path/'test'
 subprocess.run(['xcrun','swiftc','-D','DEBUG','-swift-version','5','-default-isolation','MainActor',
    '-parse-as-library',str(APP/'VoiceCapture.swift'),str(fixture),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],check=True,timeout=20)
