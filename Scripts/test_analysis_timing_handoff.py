#!/usr/bin/env python3
"""Run the production timing-handoff owner against inert KVO/notification window objects.
No AppKit window, GUI action, app launch, preferences, analysis or permission is involved.
"""
from pathlib import Path
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'Views/Onboarding/OnboardingReadyView.swift').read_text()
start=source.index('@MainActor @Observable\nfinal class AnalysisTimingHandoff')
end=source.index('\n/// Mounted in the parent content',start)
controller=source[start:end]
fixture=r'''
import Foundation
import Observation
enum ProcessingCoordinator{enum Timing{case now,overnight}}
final class NSWindow:NSObject {
    @objc dynamic var attachedSheet:NSWindow?
    static let didEndSheetNotification=Notification.Name("fixture.didEndSheet")
    static let willCloseNotification=Notification.Name("fixture.willClose")
}
// CONTROLLER
@main struct Test {
    @MainActor static func main()async {
        var checks=0
        func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS "+label)}
        func drain()async{for _ in 0..<25{await Task.yield()}}
        let handoff=AnalysisTimingHandoff()
        let owner=NSWindow(),sheet=NSWindow()
        var callbacks:[ProcessingCoordinator.Timing]=[]
        var detachedAtCallback:[Bool]=[]
        func received(_ value:ProcessingCoordinator.Timing){callbacks.append(value);detachedAtCallback.append(owner.attachedSheet==nil)}
        check(!handoff.choose(.now,onStart:received),"unattached owner cannot queue a timing action")
        handoff.attach(to:owner);owner.attachedSheet=sheet
        check(handoff.choose(.now,onStart:received),"explicit timing queues one result")
        check(!handoff.choose(.overnight,onStart:received),"repeated Continue cannot replace a pending result")
        handoff.sheetDidDismiss();await drain()
        check(callbacks.isEmpty && handoff.isPending,"SwiftUI dismissal alone cannot run while native sheet remains attached")
        NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:owner)
        await drain()
        check(callbacks.isEmpty,"even an early native notification cannot bypass attachedSheet truth")
        owner.attachedSheet=nil
        await drain()
        check(callbacks==[.now] && detachedAtCallback==[true] && !handoff.isPending,"native KVO detachment completes pending timing exactly once")
        handoff.sheetDidDismiss()
        NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:owner)
        await drain()
        check(callbacks.count==1,"late duplicate dismissal events do not repeat the result")

        owner.attachedSheet=sheet
        check(handoff.choose(.overnight,onStart:received),"new timing has its own handoff lifecycle")
        owner.attachedSheet=nil
        NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:owner)
        await drain()
        check(callbacks.count==1,"native detachment arriving first waits for SwiftUI dismissal")
        handoff.sheetDidDismiss();await drain()
        check(callbacks==[.now,.overnight] && detachedAtCallback.allSatisfy{$0},"either event order delivers after actual detachment")

        owner.attachedSheet=sheet
        _=handoff.choose(.now,onStart:received)
        handoff.sheetDidDismiss()
        NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:owner)
        owner.attachedSheet=nil
        NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:owner)
        await drain()
        check(callbacks.count==2 && !handoff.isPending,"native owner close cancels queued and late events")

        owner.attachedSheet=sheet
        _=handoff.choose(.now,onStart:received)
        handoff.cancel() // onDisappear or Home-admission reset
        handoff.sheetDidDismiss();owner.attachedSheet=nil
        await drain()
        check(callbacks.count==2,"view closure or reset cancels pending timing")

        owner.attachedSheet=sheet
        _=handoff.choose(.now,onStart:received)
        handoff.attach(to:nil)
        owner.attachedSheet=nil
        handoff.sheetDidDismiss();await drain()
        check(callbacks.count==2 && !handoff.isPending,"native owner detachment invalidates retained callback")
        handoff.attach(to:owner)
        _=handoff.choose(.now,onStart:received)
        handoff.sheetDidDismiss();await drain()
        check(callbacks.count==3,"reopened owner permits a fresh explicit timing action")
        handoff.attach(to:nil)
        print("Analysis timing handoff: \(checks) checks passed")
    }
}
'''.replace('// CONTROLLER',controller)
with tempfile.TemporaryDirectory(prefix='sentient-sheet-handoff-')as directory:
    path=Path(directory);(path/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True,timeout=20)
