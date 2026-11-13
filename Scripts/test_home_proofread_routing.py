#!/usr/bin/env python3
"""Run real Home-source preparation against native window IDs and selection ranges."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];app=root/'Sentient OS macOS'
def method(s, marker):
 a=s.index(marker);b=s.index('{',a)+1;depth=1
 while depth:
  depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]
coordinator=(app/'Notch Magic/CommandCoordinator.swift').read_text()
prepare='\n'.join(method(coordinator, signature).replace('private func','func',1) for signature in [
 '    private func prepareProofreadSelection(', '    private func prepareHomeProofreadDraft(',
 '    private func hasPreparedHomeDraft('])
home=method((app/'App/Sentient_OS_macOSApp.swift').read_text(),'    static func isHomeWindow(')
fixture=r'''
import AppKit
struct Workspace { var processIdentifier = getpid() }
struct NSWorkspace { static let shared = NSWorkspace(); var frontmostApplication: Workspace? { Workspace() } }
enum SentientOSApp { static let homeWindowID="home"; // HOME
}
final class Conversation { var draft="tell me a joek"; var generation:UUID?=UUID(); var isVisible=false }
final class Recovery { var isPending=false }
final class Run { let conversation=Conversation(),recovery=Recovery();var isClearingChat=false,isRunning=false }
final class Dictation { var isActive=false }
final class Proofread {
 var preparedDraftToken:UUID?
 var captured:String?,replace:((String)->Bool)?,externalCaptures=0
 func prepareDraft(text:String,replace:@escaping (String)->Bool){captured=text;self.replace=replace;preparedDraftToken=UUID()}
 func prepareSelection(){externalCaptures+=1}
}
final class App { var keyWindow:NSWindow? }
final class Coordinator {
 let run=Run(),proofread=Proofread(),composerDictation=Dictation(),NSApp=App()
 var notchDraft="separate notch prompt"
 // PREPARE
}
@main struct Test {
 static func main() {
  _ = NSApplication.shared
  var checks=0
  func check(_ value:Bool,_ name:String){precondition(value,name);checks+=1}
  for historyVisible in [false, true] {
  for id in ["home","home-AppWindow-1"] {
   let c=Coordinator()
   c.run.conversation.isVisible = historyVisible
   let w=NSWindow(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:false)
   w.isReleasedWhenClosed=false;w.identifier = .init(id);c.NSApp.keyWindow=w
   c.prepareProofreadSelection()
   check(c.proofread.captured=="tell me a joek" && c.proofread.externalCaptures==0,"native Home ID routes directly")
   check(c.proofread.replace?("Tell me a joke.")==true && c.run.conversation.draft=="Tell me a joke.","Home draft receives correction")
   check(c.notchDraft=="separate notch prompt","Home correction cannot overwrite notch draft")
   c.prepareProofreadSelection();c.run.conversation.draft="my newer text"
   check(c.proofread.replace?("late result")==false && c.run.conversation.draft=="my newer text","late correction preserves newer input")
   let editor=NSTextView();editor.string=c.run.conversation.draft
   w.contentView=editor;w.makeFirstResponder(editor)
   editor.setSelectedRange(NSRange(location:3,length:5))
   c.prepareProofreadSelection()
   check(c.proofread.captured=="newer","Home selection is captured before notch focus")
   let handoffToken = c.proofread.preparedDraftToken
   c.NSApp.keyWindow = nil; editor.setSelectedRange(NSRange(location: 0, length: 0))
   c.prepareProofreadSelection(preservingHomeDraft: handoffToken)
   check(c.proofread.captured == "newer" && c.proofread.externalCaptures == 0,
         "focus loss and deselection cannot replace the captured Home selection")
   c.NSApp.keyWindow = w
   check(c.proofread.replace?("corrected")==true && c.run.conversation.draft=="my corrected text","selected correction preserves surrounding text")
   w.identifier = .init("settings")
   c.prepareProofreadSelection();check(c.proofread.externalCaptures==1,"other Sentient editors do not accidentally replace Home")
   c.proofread.preparedDraftToken = UUID()
   c.prepareProofreadSelection(preservingHomeDraft: handoffToken)
   check(c.proofread.externalCaptures == 2, "an old press cannot reuse a replacement snapshot")
   w.close()
  }
  }
  print("PASS: \(checks) native Home routing and draft ownership checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-home-proofread-') as d:
 p=Path(d);src=p/'test.swift';src.write_text(fixture.replace('// HOME',home).replace('// PREPARE',prepare))
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(src),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=15)
