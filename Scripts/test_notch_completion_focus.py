#!/usr/bin/env python3
"""Exercise real completion routing and Home-focus acknowledgement without a provider."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Sentient OS macOS/Notch Magic/CommandCoordinator.swift').read_text()
def block(marker):
 a=s.index(marker); b=s.index('{',a)+1; depth=1
 while depth: depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
phase=block('enum NotchPhase: Equatable')
finish=block('    private func runFinished(').replace('private func','func',1)
focus=block('    var homeWindowFocused =')
fixture=r'''
import AppKit
func Log(_ text:String) {}
enum CommandRunModel { enum Outcome: Equatable { case success, failed, stopped } }
// PHASE
struct Message { enum Kind { case update, answer }; struct Event { var messageKind: Kind }; var event: Event }
final class Run { var isClearingChat=false; var completionHasAnswer=false }
final class Voice { var isActive=false }
final class Coordinator {
 let run=Run(),composerDictation=Voice()
 var phase=NotchPhase.running
 var notchMessage: Message?, messageReplyFocused=false
 func dismissMessagePreview(){notchMessage=nil;phase = .hidden}
 var returningFromRecovery=false
 var deferredSubmission:(String,Int,Int)?
 var hides=0, pendingAnswer=false
 func routeAttention(){if pendingAnswer {phase = .message}}
 func submit(_ text:String,mode:Int,source:Int) {}
 func clearReadBack() {}
 func setPhase(_ p:NotchPhase){phase=p}
 func scheduleHide(after seconds:Double){hides+=1}
 // FOCUS
 // FINISH
}
@main struct Test {
 static func main(){
  var checks=0
  func check(_ ok:Bool,_ label:String){precondition(ok,label);checks+=1}
  for outcome in [CommandRunModel.Outcome.success,.stopped,.failed] {
   let home=Coordinator();home.homeWindowFocused=true;home.runFinished(outcome)
   check(home.phase == .hidden && home.hides==0,"Home completion is consumed, not hidden temporarily")
   home.homeWindowFocused=false
   check(home.phase == .hidden,"next focus change cannot resurrect Done")
   let outside=Coordinator();outside.runFinished(outcome)
   check(outside.phase == .finishing(outcome) && outside.hides==1,"background completion still appears")
   outside.homeWindowFocused=true;outside.homeWindowFocused=false
   check(outside.phase == .hidden,"reading Home acknowledges a completion permanently")
  }
  let answered=Coordinator();answered.run.completionHasAnswer=true;answered.pendingAnswer=true
  answered.runFinished(.success)
  check(answered.phase == .message && answered.hides==0,"committed answer wins even if notification arrived late")
  let dismissed=Coordinator();dismissed.run.completionHasAnswer=true
  dismissed.runFinished(.success)
  check(dismissed.phase == .hidden && dismissed.hides==0,"read/dismissed answer cannot produce a second completion toast")
  let progress=Coordinator();progress.phase = .message;progress.notchMessage = Message(event: .init(messageKind: .update))
  progress.runFinished(.success)
  check(progress.phase == .finishing(.success), "progress-only message does not suppress the final acknowledgement")
  let editing=Coordinator();editing.phase = .message;editing.notchMessage = Message(event: .init(messageKind: .update));editing.messageReplyFocused=true
  editing.runFinished(.success)
  check(editing.phase == .message, "completion preserves a reply being edited")
  let recording=Coordinator();recording.composerDictation.isActive=true;recording.runFinished(.success)
  check(recording.phase == .hidden && recording.hides==0,"old task cannot add Done to Home dictation")
  for phase in [NotchPhase.listening,.transcribing,.typing,.message] {
   let input=Coordinator();input.phase=phase;input.runFinished(.success)
   check(input.phase == phase && input.hides==0,"late completion cannot replace newer input/response")
  }
  print("PASS: \(checks) completion and focus-handoff checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-completion-focus-') as d:
 p=Path(d);swift=p/'test.swift';swift.write_text(fixture.replace('// PHASE',phase).replace('// FOCUS',focus).replace('// FINISH',finish))
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(swift),'-o',str(p/'test')],check=True,timeout=45)
 subprocess.run([str(p/'test')],check=True,timeout=10)
