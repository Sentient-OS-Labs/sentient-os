#!/usr/bin/env python3
"""Run production hover, click and entry-availability logic with a pending question."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1];app=root/'Sentient OS macOS/Notch Magic'
def member(s,needle):
 a=s.index(needle);b=s.index('{',a)+1;d=1
 while d:d+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b].replace('private func','func',1).replace('private var','var',1)
controller=(app/'NotchWindowController.swift').read_text();coordinator=(app/'CommandCoordinator.swift').read_text()
fixture=r'''
import AppKit
func Log(_ text:String){}
enum Phase {case hidden,typing,message,recovery,running}
enum NotchAnchor {case builtInNotch,mainDisplay,display(CGDirectDisplayID)}
final class Recovery {
 var isPending=true,isVisible=false,reopened=0
 func reopen()->Bool {guard isPending else{return false};reopened+=1;isVisible=true;return true}
}
final class Run {var isClearingChat=false,isRunning=true;let recovery=Recovery()}
enum ScreenCapture {static func summaryDisplay()->UInt32?{1}}
enum SummaryAccessibility {static func target()->Int?{1}}
final class ComputerUseGate {static let shared=ComputerUseGate();func refresh(){}}
final class DoubleTap { static let shared = DoubleTap(); var isDrafting = false }
final class Coordinator {
 let run=Run();var phase=Phase.hidden,notchAnchor=NotchAnchor.mainDisplay
 var onboardingReplyLessonActive=false
 var notchFocusRequest=0,onboardingDemoArmed=false,notchButtonAvailable=true
 var summaryDisplayID:UInt32?,summaryTarget:Int?,hovering=false
 func setNotchHovering(_ value:Bool,anchor:NotchAnchor){hovering=value;notchAnchor=anchor}
 func beginNotchDemo(door:String){}
 func interceptForOnboarding()->Bool{false}
 func prepareProofreadSelection(preservingHomeDraft:UUID?){}
 func setPhase(_ value:Phase){phase=value}
 // CLICK
}
struct Screen {var displayID:CGDirectDisplayID=1}
final class Host {func layoutSubtreeIfNeeded(){}}
enum NSHapticFeedbackManager {
 enum Pattern {case alignment};enum Time {case now}
 struct Performer {func perform(_ pattern:Pattern,performanceTime:Time){}}
 static let defaultPerformer=Performer()
}
final class Controller {
 let coordinator=Coordinator();var panel:Int?=1,host:Host?=Host()
 var notchClickEnabled=true,hovering=false,sizeToken=0,hoverDisplayID:CGDirectDisplayID?
 var pointerAnchor:NotchAnchor{.display(hoverDisplayID ?? 1)}
 var metricsDisplayID:CGDirectDisplayID?=1
 func allowsRestingBar(on displayID:CGDirectDisplayID?)->Bool{displayID == 1}
 static func builtInNotchScreen()->Screen?{Screen()}
 func placeCanvas(){};func reveal(){};func syncEntryHandles(){};func startMouseTracking(){}
 // HOVER
 // ENTRIES
}
@main struct Tests {
 static func main(){
  var checks=0
  func check(_ ok:Bool,_ label:String){precondition(ok,label);checks+=1}
  let c=Controller()
  check(c.entriesAvailable,"pending question remains clickable while run owns its lock")
  for _ in 0..<50 {
   c.beginHover(on:1)
   check(!c.coordinator.run.recovery.isVisible && c.coordinator.run.recovery.reopened==0,"hover cannot reopen dismissed question")
   check(c.hovering && c.coordinator.hovering,"small hover affordance still responds")
   c.hovering=false
  }
  c.coordinator.openNotchInput(anchor:.display(1),door:"notch click")
  check(c.coordinator.run.recovery.isVisible && c.coordinator.run.recovery.reopened==1,"explicit click reopens question once")
  c.coordinator.run.recovery.isVisible=false;c.beginHover(on:1)
  check(!c.coordinator.run.recovery.isVisible && c.coordinator.run.recovery.reopened==1,"dismiss remains respected after a prior reopen")
  c.coordinator.run.recovery.isPending=false
  check(!c.entriesAvailable,"ordinary running task does not advertise idle input")
  c.coordinator.run.isRunning=false
  check(c.entriesAvailable,"idle input remains available")
  print("PASS: \(checks) dismissed-question hover and click checks")
 }
}
'''
fixture=fixture.replace('// HOVER',member(controller,'    private func beginHover(')).replace('// ENTRIES',member(controller,'    private var entriesAvailable:')).replace('// CLICK',member(coordinator,'    private func openNotchInput('))
with tempfile.TemporaryDirectory(prefix='sentient-question-hover-') as d:
 p=Path(d);src=p/'test.swift';src.write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(src),'-o',str(p/'test')],check=True,timeout=45)
 subprocess.run([str(p/'test')],check=True,timeout=10)
