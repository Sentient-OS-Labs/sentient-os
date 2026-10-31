#!/usr/bin/env python3
"""Test production window selection for the helper note without opening windows or changing grants."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
TESTS = r'''
extension SettingsWindowTracker {
    func fixtureFrame(_ windows: [[String:Any]], pid: pid_t) -> CGRect? { selectedFrame(for:pid,windows:windows) }
    func fixturePublish(_ frame: CGRect?) { publishWindowServerFrame(frame) }
}
@main struct Tests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let pid:pid_t = 123
        func window(_ layer: Int, owner:pid_t = 123, width:Double = 600, height:Double = 540, alpha:Double = 1) -> [String:Any] {
            [kCGWindowOwnerPID as String:owner,kCGWindowLayer as String:layer,kCGWindowAlpha as String:alpha,
             kCGWindowBounds as String:["X":456.0,"Y":136.0,"Width":width,"Height":height]]
        }
        let helper = SettingsWindowTracker(usesAccessibility:false,windowLevels:[NSWindow.Level.floating.rawValue],onlyWhenApplicationActive:true)
        let dragger = SettingsWindowTracker(usesAccessibility:false)
        let main = window(3), dragOverlay = window(0,width:900,height:950)
        precondition(helper.fixtureFrame([main,dragOverlay],pid:pid)?.size == CGSize(width:600,height:540),"Main setup panel wins over larger drag overlay")
        precondition(helper.fixtureFrame([dragOverlay],pid:pid) == nil,"Never attaches to the drag overlay")
        precondition(dragger.fixtureFrame([main,dragOverlay],pid:pid)?.size == CGSize(width:900,height:950),"Existing System Settings dragger still uses normal windows")
        precondition(helper.fixtureFrame([window(3,owner:124)],pid:pid) == nil,"Cannot attach to another app")
        precondition(helper.fixtureFrame([window(3,width:90,height:160)],pid:pid) == nil,"Stage Manager thumbnail cannot become an attachment target")
        precondition(helper.fixtureFrame([window(3,alpha:0)],pid:pid) == nil,"Invisible window cannot become an attachment target")
        var frames = 0, hidden = 0
        helper.onFrameChange = { _ in frames += 1 }; helper.onWindowMissing = { hidden += 1 }
        let frame = helper.fixtureFrame([main],pid:pid)!
        helper.fixturePublish(frame); helper.fixturePublish(frame)
        precondition(frames == 1,"Unchanged geometry does not emit duplicate updates")
        helper.fixturePublish(nil)
        precondition(hidden == 1 && helper.currentFrame == nil,"Missing/inactive target clears attachment")
        helper.fixturePublish(frame)
        precondition(frames == 2,"Returning to the unchanged setup window reshowes note")
        print("PASS 9 helper-note selection and visibility assertions; System Settings drag behavior preserved")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-helper-note-test-') as directory:
    root=Path(directory); source=root/'Tracker.swift'
    source.write_text((APP/'Views/Permissions/SettingsWindowTracker.swift').read_text()+TESTS)
    binary=root/'tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
