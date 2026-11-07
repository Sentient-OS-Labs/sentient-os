#!/usr/bin/env python3
"""Production hold recognizer with deterministic pointer/time inputs, no global input synthesis."""
from pathlib import Path
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS/Notch Magic'
SWIFT=r'''
import AppKit
@main struct Tests {
 static func main(){
  var checks=0,taps=0,holds=0,releases=0
  var point=NSPoint(x:100,y:900),buttons=1,time=0.0,admit=true
  let gesture=NotchPressGesture(location:{point},buttons:{buttons},uptime:{time})
  func begin(){buttons=1;point=NSPoint(x:100,y:900);gesture.begin(tap:{taps+=1},hold:{holds+=1;return admit},release:{releases+=1})}
  func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
  begin();time=0.1;gesture.releaseForTesting()
  check(taps==1 && holds==0 && releases==0,"short click opens typing only")
  begin();time+=0.249;gesture.tickForTesting()
  check(holds==0,"no premature capture")
  time+=0.002;gesture.tickForTesting()
  check(holds==1,"threshold starts one capture")
  point=NSPoint(x:1000,y:400);gesture.tickForTesting()
  check(releases==0 && gesture.isTracking,"moving outside after hold retains gesture")
  gesture.releaseForTesting();gesture.releaseForTesting()
  check(releases==1 && !gesture.isTracking,"release anywhere finalizes exactly once")
  begin();time+=0.3;gesture.tickForTesting();buttons=0;gesture.tickForTesting()
  check(releases==2 && !gesture.isTracking,"lost mouse-up reconciles from physical button state")
  begin();point.x+=20;gesture.tickForTesting();time+=0.3;gesture.tickForTesting();gesture.releaseForTesting()
  check(holds==2 && taps==1,"drag away before qualification cancels click and hold")
  begin();gesture.cancel();time+=1;gesture.tickForTesting();gesture.releaseForTesting()
  check(releases==2 && holds==2,"explicit teardown prevents late hold or release")
  admit=false;begin();time+=0.3;gesture.tickForTesting();gesture.releaseForTesting()
  check(releases==2 && taps==1,"rejected hold cannot turn into a tap or submission")
  begin();buttons=0;gesture.tickForTesting()
  check(taps==2 && !gesture.isTracking,"missing short mouse-up still delivers the click")
  admit=true;buttons=1;point=NSPoint(x:100,y:900)
  gesture.begin(tap:{taps+=1},hold:{holds+=1;return true},release:{releases+=1},cancelOnEarlyDrag:false)
  point=NSPoint(x:1000,y:400);time+=0.3;gesture.tickForTesting();buttons=0;gesture.tickForTesting()
  check(releases==3 && !gesture.isTracking,"mic already recording keeps release-to-send after early pointer drift")
  var edits=0
  func beginEditableHold(){buttons=1;point=NSPoint(x:100,y:900);gesture.begin(tap:{},hold:{true},release:{releases+=1},releaseAway:{edits+=1})}
  beginEditableHold();time+=0.3;gesture.tickForTesting();point.x+=80;gesture.releaseForTesting()
  check(edits==1 && releases==3,"release away stops into a draft without submitting")
  beginEditableHold();time+=0.3;gesture.tickForTesting();point.x+=8;buttons=0;gesture.tickForTesting()
  check(edits==1 && releases==4,"small drift and missing mouse-up still send once")
  beginEditableHold();time+=0.3;gesture.tickForTesting();point.x+=80;gesture.tickForTesting();point.x-=80;gesture.releaseForTesting()
  check(edits==1 && releases==5,"returning to the hold target before release sends")
  print("PASS: \(checks) production notch gesture checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-dictation-gesture-') as directory:
 path=Path(directory);fixture=path/'test.swift';fixture.write_text(SWIFT);binary=path/'test'
 subprocess.run(['xcrun','swiftc','-D','DEBUG','-swift-version','5','-default-isolation','MainActor','-parse-as-library',
                 str(APP/'NotchPressGesture.swift'),str(fixture),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],check=True,timeout=20)
