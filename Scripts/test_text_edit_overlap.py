#!/usr/bin/env python3
"""Exercise Double Tap's real paste-settlement guard with a private clipboard and inert events."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'Sentient OS macOS/Double Tap/DoubleTap.swift').read_text()
paste=source[source.index('private enum ReplyPaste {'):].replace('private enum ReplyPaste','enum ReplyPaste',1).replace('NSPasteboard.general','Fixture.board')
start=source.index('var isDrafting: Bool {');end=source.index('}',start)+1
fixture=r'''
import AppKit
import Foundation
enum Fixture {static let board=NSPasteboard(name:NSPasteboard.Name("sentient-text-edit-test-"+UUID().uuidString));static var posts=0}
struct CGEventSource {enum State{case combinedSessionState};init(stateID:State){}}
final class CGEvent {enum Flags{case maskCommand};enum Tap{case cghidEventTap};var flags=Flags.maskCommand
 init?(keyboardEventSource:CGEventSource,virtualKey:CGKeyCode,keyDown:Bool){}
 func post(tap:Tap){Fixture.posts+=1}}
enum Diagnostics {enum Event{case doubleTapFailed};enum Phase{case paste};static func report(_ event:Event,phase:Phase,reason:String,source:String){}}
enum CrashReporting {static func diagnosticBreadcrumb(_ value:String,data:[String:String]){}}
func Log(_ value:String){}
final class Owner {var task:Task<Void,Never>?
 // OWNER
}
// PASTE
@main enum Tests {
 static func main() async {
  let board=Fixture.board;defer{board.releaseGlobally()};let owner=Owner()
  board.clearContents();board.setString("original",forType:.string)
  var completed=false
  let started=ContinuousClock.now
  owner.task=Task {let ok=await ReplyPaste.insert("draft");precondition(ok);completed=true}
  try? await Task.sleep(for:.milliseconds(20))
  precondition(owner.isDrafting && !completed && Fixture.posts==2)
  owner.task?.cancel()
  board.clearContents();board.setString("new user copy",forType:.string)
  await owner.task?.value;owner.task=nil
  precondition(started.duration(to:.now) >= .milliseconds(450))
  precondition(board.string(forType:.string)=="new user copy" && !owner.isDrafting && completed)
  let ok=await ReplyPaste.insert("second draft");precondition(ok)
  precondition(board.string(forType:.string)=="new user copy")
  print("PASS: posted paste remains busy through cleanup and respects intervening clipboard changes")
 }
}
'''.replace('// OWNER',source[start:end]).replace('// PASTE',paste)
with tempfile.TemporaryDirectory(prefix='sentient-text-edit-') as temporary:
 p=Path(temporary);(p/'Test.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(p/'Test.swift'),'-o',str(p/'test')],check=True,timeout=60)
 subprocess.run([str(p/'test')],check=True,timeout=10)
