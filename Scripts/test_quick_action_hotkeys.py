#!/usr/bin/env python3
"""Exercise production character mapping, Carbon registration and event dispatch without actions.
Registers the requested chords only for the lifetime of this disposable process. No capture or model runs.
"""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
FIXTURE=r'''
import AppKit
import Carbon.HIToolbox
func Log(_ value:String){}
@main enum Tests {
 static var checks=0
 static func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
 static func event(_ identifier:UInt32,_ kind:UInt32,signature:OSType=QuickActionHotkeys.signature){
  var event:EventRef?
  precondition(CreateEvent(nil,OSType(kEventClassKeyboard),kind,GetCurrentEventTime(),0,&event)==noErr)
  guard let event else{fatalError("event")};defer{ReleaseEvent(event)}
  var id=EventHotKeyID(signature:signature,id:identifier)
  precondition(SetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),MemoryLayout<EventHotKeyID>.size,&id)==noErr)
  _ = SendEventToEventTarget(event,GetApplicationEventTarget())
 }
 static func main() {
  _ = NSApplication.shared
  let command=UInt32(cmdKey)
  let us: (UInt16,UInt32)->String? = { code,mods in
   if code==43 && mods==UInt32(shiftKey){return "<"};if code==47 && mods==UInt32(shiftKey){return ">"}
   if code==43 && mods==0{return ","};if code==47 && mods==0{return "."};return nil
  }
  check(QuickActionShortcut.resolve(.summarize,translate:us)==.init(keyCode:43,modifiers:command),"US summarize is Command Comma without Shift")
  check(QuickActionShortcut.resolve(.proofread,translate:us)==.init(keyCode:47,modifiers:command),"US proofread is Command Period without Shift")
  let azerty: (UInt16,UInt32)->String? = { code,mods in
   if code==46 && mods==0{return ","}
   if code==43 && mods==UInt32(shiftKey){return "."};return nil
  }
  check(QuickActionShortcut.resolve(.summarize,translate:azerty)==.init(keyCode:46,modifiers:command),"AZERTY follows the comma key")
  check(QuickActionShortcut.resolve(.proofread,translate:azerty)==.init(keyCode:43,modifiers:command),"AZERTY period key needs only Command")
  check(QuickActionShortcut.resolve(.summarize,translate:{_,_ in nil})==nil,"unavailable layout does not silently substitute US keys")
  var sawCommand=false
  let symbol=QuickActionShortcut.resolve(.summarize){code,mods in
   if mods & command != 0{sawCommand=true};return code==50 && mods==UInt32(shiftKey) ? "," : nil
  }
  check(symbol == .init(keyCode:50,modifiers:command) && !sawCommand,"layout lookup excludes Command and registration never adds Shift")
  check(QuickActionShortcut.resolve(.proofread,translate:{code,mods in code==50 && mods==UInt32(optionKey) ? "." : nil})==nil,"Option-only symbols do not invent a punctuation key")
  check(QuickActionShortcut.summarize.label=="⌘," && QuickActionShortcut.proofread.label=="⌘.","requested labels")
  check(QuickActionShortcut.summarize.spokenLabel=="Command comma" && QuickActionShortcut.proofread.spokenLabel=="Command period","accessible shortcut names")
  let chords=QuickActionShortcut.currentChords()
  check(chords.count==2,"current keyboard resolves both symbols")
  check(chords.values.allSatisfy{$0.modifiers==command},"native layout registers Command alone")
  check(chords[.summarize] != chords[.proofread],"actions never share a chord")
  let shortcuts=QuickActionHotkeys();var calls:[QuickActionShortcut]=[]
  shortcuts.onAction={calls.append($0)};shortcuts.setEnabled(true);shortcuts.installForTesting()
  defer{shortcuts.stop()}
  check(shortcuts.registeredActions==Set(QuickActionShortcut.allCases),"native global registration succeeds")
  let ids=shortcuts.identifiersForTesting
  let summary=ids.first{$0.value == .summarize}!.key, proofread=ids.first{$0.value == .proofread}!.key
  event(summary,UInt32(kEventHotKeyPressed));event(summary,UInt32(kEventHotKeyPressed))
  check(calls == [.summarize],"held/repeated press fires only once")
  event(summary,UInt32(kEventHotKeyReleased));event(summary,UInt32(kEventHotKeyPressed))
  event(proofread,UInt32(kEventHotKeyPressed));event(proofread,UInt32(kEventHotKeyReleased))
  check(calls == [.summarize,.summarize,.proofread],"Carbon dispatch routes both actions")
  event(summary,UInt32(kEventHotKeyPressed),signature:0)
  check(calls.count==3,"unrelated Carbon signatures ignored")
  let conflict=QuickActionHotkeys();conflict.setEnabled(true);conflict.installForTesting()
  check(conflict.registeredActions.isEmpty && conflict.problems.count==2,"exclusive conflicts are reported without stealing a registration")
  conflict.stop()
  shortcuts.setEnabled(false)
  check(shortcuts.registeredActions.isEmpty && !shortcuts.receive(identifier:summary,isPressed:true),"recording/suspension releases and ignores shortcuts")
  shortcuts.setEnabled(true)
  check(!shortcuts.identifiersForTesting.keys.contains(summary),"new registration IDs fence stale layout events")
  event(summary,UInt32(kEventHotKeyPressed));check(calls.count==3,"old queued event cannot start a new action")
  let workspace=NSWorkspace.shared.notificationCenter
  workspace.post(name:NSWorkspace.willSleepNotification,object:nil)
  check(shortcuts.registeredActions.isEmpty,"sleep releases both global chords")
  workspace.post(name:NSWorkspace.sessionDidResignActiveNotification,object:nil)
  workspace.post(name:NSWorkspace.didWakeNotification,object:nil)
  check(shortcuts.registeredActions.isEmpty,"wake does not activate shortcuts in an inactive session")
  workspace.post(name:NSWorkspace.sessionDidBecomeActiveNotification,object:nil)
  check(shortcuts.registeredActions.count==2,"active session restores the requested chords")
  shortcuts.stop();conflict.setEnabled(true);conflict.installForTesting()
  check(conflict.registeredActions.count==2,"stopping releases shortcuts for the next owner")
  conflict.stop()
  print("PASS: \(checks) quick-action mapping, registration and dispatch checks")
  for action in QuickActionShortcut.allCases {let chord=chords[action]!;print("\(action.rawValue): keyCode=\(chord.keyCode) modifiers=\(chord.modifiers)")}
 }
}
'''.replace(')==.init',') == .init')
with tempfile.TemporaryDirectory(prefix='sentient-quick-hotkeys-') as temporary:
    directory=Path(temporary);fixture=directory/'Tests.swift';fixture.write_text(FIXTURE)
    binary=directory/'tests'
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-DDEBUG','-parse-as-library',
        str(ROOT/'Sentient OS macOS/System/Shortcuts/QuickActionShortcut.swift'),
        str(ROOT/'Sentient OS macOS/System/Shortcuts/QuickActionHotkeys.swift'),str(fixture),'-o',str(binary)],check=True,timeout=60)
    subprocess.run([str(binary)],check=True,timeout=20)
