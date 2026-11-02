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
extension NativeHelperPermissionNote {
    static func fixture(_ lookup: @escaping () -> NSRunningApplication?) -> NativeHelperPermissionNote {
        NativeHelperPermissionNote(appURL: URL(fileURLWithPath: "/fixture/helper.app"), lookup: lookup)
    }
    var fixturePID: pid_t? { helperPID }
    func fixtureRefresh() { refreshHelper() }
    func fixtureClose() { close() }
    func fixtureShowStatus() { Self.visibility.setVisible(true, for: visibilityID) }
    func fixtureHideStatus() { hide() }
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
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let target = CGRect(x: 400, y: 220, width: 600, height: 540)
        let noteSize = CGSize(width: 280, height: 130)
        let note = NoteGeometry.noteFrame(target: target, available: screen, size: noteSize)
        precondition(note.minX == target.maxX && note.midY == target.minY + target.height * 0.15,
                     "Permissionless note aligns with browser section, not top of window")
        let moved = target.offsetBy(dx: 200, dy: 0)
        let left = NoteGeometry.noteFrame(target: moved, available: screen, size: noteSize)
        precondition(left.maxX == moved.minX && left.midY == note.midY,
                     "Left-side fallback preserves browser-row height")
        var running: NSRunningApplication?
        let follower = NativeHelperPermissionNote.fixture { running }
        precondition(follower.fixturePID == nil, "A not-yet-running helper does not end the guide")
        running = NSRunningApplication.current
        follower.fixtureRefresh()
        precondition(follower.fixturePID == running?.processIdentifier, "Late helper startup is followed")
        running = nil
        follower.fixtureRefresh()
        precondition(follower.fixturePID == nil, "Helper exit detaches the old window")
        running = NSRunningApplication.current
        follower.fixtureRefresh()
        precondition(follower.fixturePID == running?.processIdentifier, "A restarted helper is followed")
        follower.fixtureClose()
        follower.fixtureRefresh()
        precondition(follower.fixturePID == nil, "Closed guide cannot be revived by a queued callback")
        let first = NativeHelperPermissionNote.fixture { nil }
        let second = NativeHelperPermissionNote.fixture { nil }
        first.fixtureShowStatus(); second.fixtureShowStatus()
        precondition(NativeHelperPermissionNote.visibility.isVisible, "Visible helper note enables setup caption")
        first.fixtureClose()
        precondition(NativeHelperPermissionNote.visibility.isVisible, "Closing one request preserves another visible note")
        second.fixtureHideStatus()
        precondition(!NativeHelperPermissionNote.visibility.isVisible, "Hidden note clears the setup caption")
        second.fixtureShowStatus(); second.fixtureClose()
        precondition(!NativeHelperPermissionNote.visibility.isVisible, "Cancellation clears the setup caption")
        print("PASS 20 helper-note selection, visibility and caption lifecycle assertions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-helper-note-test-') as directory:
    root=Path(directory); source=root/'Tracker.swift'
    text=(APP/'Views/Permissions/NativeHelperPermissionNote.swift').read_text()
    start=text.index('    nonisolated static func noteFrame(')
    end=text.index('    private func alignBrowserRow',start)
    geometry='\nenum NoteGeometry {\n'+text[start:end]+'\n}\n'
    source.write_text((APP/'Views/Permissions/SettingsWindowTracker.swift').read_text()+text+'\nenum OpenAIComputerUse { static let bundleID = \"fixture.helper\" }\n'+geometry+TESTS)
    binary=root/'tests'
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
