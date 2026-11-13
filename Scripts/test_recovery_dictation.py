#!/usr/bin/env python3
"""Exercise recovery reply voice actions with real draft/timing models and a fake microphone."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];app=root/'Sentient OS macOS/Notch Magic'
source=(app/'SidekickRecoveryView.swift').read_text()
def method(name):
 a=source.index('    private func '+name);b=source.index('{',a)+1;d=1
 while d: d+=(source[b]=='{')-(source[b]=='}');b+=1
 return source[a:b].replace('private func','func',1)
fixture=r'''
import Foundation
@MainActor final class VoiceCapture {
 var onTranscript:((String)->Void)?,onFailure:((Error)->Void)?,onLevel:((Float)->Void)?
 var pending:CheckedContinuation<String,Error>?
 func start()async throws{}
 func stopCapturing(){}
 func stopAndTranscribe()async throws->String{try await withCheckedThrowingContinuation{pending=$0}}
 func cancel(){pending?.resume(throwing:CancellationError());pending=nil}
 func finish(_ text:String){pending?.resume(returning:text);pending=nil}
}
@MainActor final class Press {func cancel(){}}
@MainActor final class Harness {
 let recovery:SidekickRecovery
 let voice:ComposerDictation
 let voicePress=Press()
 var content:SidekickRecoveryContent
 var canSend:Bool {voice.isActive || !recovery.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
 init(_ recovery:SidekickRecovery,_ content:SidekickRecoveryContent,_ mic:VoiceCapture){self.recovery=recovery;self.content=content;voice=ComposerDictation(capture:mic)}
 // METHODS
}
@main struct Tests {
 @MainActor static func main()async throws {
  var checks=0
  func check(_ ok:Bool,_ name:String){precondition(ok,name);checks+=1}
  func settle()async{try? await Task.sleep(for:.milliseconds(30))}
  for isQuestion in [true,false] {
   let content:SidekickRecoveryContent = isQuestion ? .clarification(try SidekickQuestion(error:nil,question:"Which version?",answers:["Short","Long"])) : .failure(id:UUID(),error:"Could not finish")
   let recovery=SidekickRecovery();var sent:[String]=[]
   recovery.present(content){if case .answered(let answer)=$0{sent.append(answer.text)}}
   recovery.draft="Please"
   let mic=VoiceCapture()
   let view=Harness(recovery,content,mic)
   view.beginVoice();await settle()
   check(view.voice.isActive && !view.voice.hasTranscript,"mic starts without replacing the question/error")
   mic.onTranscript?("use the short version")
   check(recovery.draft=="Please use the short version","transcript edits recovery guidance")
   view.toggleMicrophone();await settle();mic.finish("use the short version.");await settle()
   check(!view.voice.isActive && sent.isEmpty && recovery.isPending,"stop keeps an editable draft")
   view.send()
   check(sent==["Please use the short version."],"Send resolves existing recovery exactly once")
   view.cancelVoice()
   recovery.present(content){if case .answered(let answer)=$0{sent.append(answer.text)}}
   view.beginVoice();await settle();mic.onTranscript?("Use the long version")
   view.send();await settle();mic.finish("Use the long version, please.");await settle()
   check(sent.last == "Use the long version, please." && sent.count == 2,
         "send while recording includes final words exactly once")
  }
  let recovery=SidekickRecovery(), mic=VoiceCapture()
  let old=SidekickRecoveryContent.failure(id:UUID(),error:"Retry")
  recovery.present(old){_ in};let view=Harness(recovery,old,mic)
  view.beginVoice();await settle();mic.onTranscript?("Keep these words")
  view.send();await settle()
  let replacement=SidekickRecoveryContent.failure(id:UUID(),error:"Different question")
  recovery.present(replacement){_ in}
  mic.finish("late old answer");await settle()
  check(recovery.content?.id==replacement.id,"late send cannot answer a replacement question")
  check(recovery.draft != "late old answer","late transcript cannot replace newer guidance")
  view.cancelVoice()
  let live=SidekickRecoveryContent.failure(id:UUID(),error:"Still recording")
  recovery.present(live){_ in};view.content=live;view.beginVoice();await settle()
  try await Task.sleep(for:.milliseconds(8200))
  check(recovery.isVisible && recovery.isPending,"recording holds the recovery timeout without keyboard focus")
  view.cancelVoice();recovery.cancel()
  print("PASS: \(checks) question/error dictation checks")
 }
}
'''
fixture=fixture.replace('// METHODS','\n'.join(method(n) for n in ['beginVoice()', 'toggleMicrophone()', 'cancelVoice()', 'send()']))
with tempfile.TemporaryDirectory(prefix='sentient-recovery-voice-') as d:
 p=Path(d);src=p/'Tests.swift';src.write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(app/'SidekickRecovery.swift'),str(app/'ComposerDictation.swift'),str(src),'-o',str(p/'tests')],check=True,timeout=45)
 subprocess.run([str(p/'tests')],check=True,timeout=20)
