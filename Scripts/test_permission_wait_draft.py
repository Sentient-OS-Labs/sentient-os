#!/usr/bin/env python3
"""Real pending-permission file and run boundary methods with synthetic conversation/state.
No model, screen capture, actual app runtime, TCC or user preferences are used.
"""
from pathlib import Path
import os
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'Notch Magic/CommandRunModel.swift').read_text()

def member(signature):
 start=source.index(signature);end=source.index('{',start)+1;depth=1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]

# The actual invocation ordering must retire durable replay state before any screen/model work.
assert source.index('try owner.beginPermissionWait(') < source.index('try await ComputerUseGate.shared.waitUntilReady()') < source.index('try owner.finishPermissionWait()') < source.index('let shots = await ScreenCapture.grab()') < source.index('try await FrontierRun.runAgentCommand(')
assert 'func stop(cause:' in source and 'cancelPermissionWait()' in member('func stop(cause:')
SUPPORT=r'''
import Foundation
extension URL {static var sentientSupport:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["TEST_WAIT_ROOT"]!)}}
nonisolated enum SidekickConversationEvent {struct ReplyReference:Codable,Equatable {let messageID:String}}
@MainActor final class Conversation {var generation:UUID?=UUID();var draft="";var replyReference:SidekickConversationEvent.ReplyReference?}
@MainActor final class SafeAppRelaunch {static let shared=SafeAppRelaunch();var isApplicationTerminating=false}
@MainActor final class Run {
 var conversation=Conversation()
 var runID=UUID(),isRunning=true,isPreparing=true,isExternal=false
 var permissionWait:PermissionWaitDraft.Snapshot?
 var permissionWaitCleanupFailed=false
 var stops=0
 func stop() {stops+=1;cancelPermissionWait();isRunning=false}
'''
body='\n'.join(member(name) for name in ['private func beginPermissionWait(', 'private func finishPermissionWait(', 'private func cancelPermissionWait(', 'private func endPermissionWaitAfterFailure(', 'var canSavePermissionWaitForRelaunch:', 'func savePermissionWaitForRelaunch(']).replace('private func','func')
TESTS=r'''
@main enum Tests {
 @MainActor static func main() async throws {
  var count=0
  func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1}
  let run=Run(),reply=SidekickConversationEvent.ReplyReference(messageID:"synthetic-message")
  try run.beginPermissionWait(text:"synthetic request",reply:reply)
  let saved=PermissionWaitDraft.read()!
  check(saved.runID == run.runID && saved.generation == run.conversation.generation && saved.reply == reply,"Pending request records exact task and conversation identity")
  let file=URL.sentientSupport.appendingPathComponent("Sidekick/PermissionWaitDraft.json")
  let mode=(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber).intValue
  check(mode == 0o600,"Pending request file is private")
  check(PermissionWaitDraft.read()?.text == "synthetic request" && PermissionWaitDraft.read() != nil,"Reading on relaunch never consumes pending request")
  run.conversation.draft="newer unsent draft"
  check(!(await run.savePermissionWaitForRelaunch()) && run.stops == 0 && run.conversation.draft == "newer unsent draft","Existing composer is never overwritten")
  run.conversation.draft="";run.conversation.replyReference=reply
  check(!run.canSavePermissionWaitForRelaunch,"Reply-only composer is protected too")
  run.conversation.replyReference=nil;run.isPreparing=false
  check(!(await run.savePermissionWaitForRelaunch()) && run.stops == 0,"A run past permission wait cannot be cancelled for relaunch")
  run.isPreparing=true;let id=run.runID;run.runID=UUID()
  check(!run.canSavePermissionWaitForRelaunch,"A different task cannot inherit old retry authority")
  run.runID=id
  check(await run.savePermissionWaitForRelaunch(),"Exact pre-inference waiter can be saved and drained")
  check(run.conversation.draft == "synthetic request" && run.conversation.replyReference == reply && PermissionWaitDraft.read() == nil && run.stops == 1,"Explicit save restores draft then cancels only its own waiter")
  let ready=Run();try ready.beginPermissionWait(text:"before work",reply:nil)
  try ready.finishPermissionWait()
  check(PermissionWaitDraft.read() == nil && ready.permissionWait == nil,"Durable pending intent is deleted before capture or inference")
  try ready.beginPermissionWait(text:"cancel me",reply:nil);ready.stop()
  check(PermissionWaitDraft.read() == nil,"Explicit Stop clears pending restart state")
  let osRestart=Run();try osRestart.beginPermissionWait(text:"keep for OS restart",reply:reply)
  SafeAppRelaunch.shared.isApplicationTerminating=true;osRestart.endPermissionWaitAfterFailure()
  check(PermissionWaitDraft.read()?.text == "keep for OS restart","AppKit shutdown preserves the pre-inference request for Quit and Reopen")
  SafeAppRelaunch.shared.isApplicationTerminating=false;osRestart.endPermissionWaitAfterFailure()
  check(PermissionWaitDraft.read() == nil,"User dismissal or non-termination cancellation clears pending request")
  let stale=Run();try stale.beginPermissionWait(text:"old",reply:nil)
  let newer=PermissionWaitDraft.Snapshot(generation:UUID(),runID:UUID(),text:"newer",reply:nil)
  try PermissionWaitDraft.save(newer)
  do {try stale.finishPermissionWait();fatalError("A changed pending request permitted inference")}
  catch PermissionWaitDraft.Failure.changed {count+=1}
  check(PermissionWaitDraft.read()?.runID == newer.runID,"Another run's file is preserved when before-work retirement fails")
  stale.cancelPermissionWait()
  check(stale.permissionWaitCleanupFailed && PermissionWaitDraft.read()?.runID == newer.runID,"Late cancellation cannot retire another run's pending request")
  PermissionWaitDraft.clear()
  print("PASS \(count) permission-wait persistence and pre-inference ownership checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-permission-wait-') as directory:
 root=Path(directory)
 (root/'Test.swift').write_text(SUPPORT+body+'\n}\n'+TESTS)
 binary=root/'test'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Test.swift'),str(APP/'System/PermissionWaitDraft.swift'),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],env=dict(os.environ,TEST_WAIT_ROOT=str(root/'support')),check=True,timeout=15)
