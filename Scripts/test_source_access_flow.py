#!/usr/bin/env python3
"""Exercise source-access action handlers with inert permission, restart and source peers."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Sentient OS macOS/Views/KnowledgeSourcesPicker.swift').read_text()
source = source[source.index('private struct SourceAccessSheet: View {'):]
def method(name):
    start = source.index('    private func ' + name + '(')
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ', 1)

fixture = r'''
import Foundation
@MainActor enum ProtectedLocalSource {
    case whatsapp, imessage
    static var allowed=false
    static var reads:[Self:Int]=[:]
    var isReadable:Bool { Self.reads[self,default:0]+=1;return Self.allowed }
}
@MainActor final class PermissionGuide {
    static let shared=PermissionGuide()
    enum Pane {case fullDiskAccess}
    struct Job {let id=UUID()}
    var job:Job?;var opens=0;var closes=0
    func guide(_ pane:Pane,dragging url:URL?) {
        precondition(url==Bundle.main.bundleURL,"Guide must carry Sentient itself, not WhatsApp")
        opens+=1;job=Job()
    }
    func close() {closes+=1;job=nil}
}
@MainActor final class SafeAppRelaunch {
    static let shared=SafeAppRelaunch()
    var isPreparing=false
}
@MainActor final class Flow {
    let source=ProtectedLocalSource.whatsapp
    var openedSettings=false;var checked=false;var readable=false;var finishing=false
    var guideID:UUID?;var completed=0
    func onReady() {completed+=1}
    // HANDLERS
}
@main struct Tests {
    @MainActor static func main() {
        var checks=0
        func check(_ value:Bool,_ message:String) {precondition(value,message);checks+=1}
        let flow=Flow(),guide=PermissionGuide.shared
        check(guide.opens==0 && ProtectedLocalSource.reads.isEmpty,"Showing explanation requests no system grant or read")
        flow.continueSetup()
        check(guide.opens==1 && flow.openedSettings && ProtectedLocalSource.reads.isEmpty,
              "Enable explicitly opens the FDA drag guide without selecting or reading sources")
        flow.continueSetup()
        check(flow.checked && !flow.finishing && flow.completed==0,"Unavailable source never advances")
        ProtectedLocalSource.allowed=true;flow.refreshAccess()
        check(flow.readable && !flow.checked && flow.completed==0 && guide.job==nil,
              "Returning from Settings reflects access but does not select chats automatically")
        ProtectedLocalSource.allowed=false;flow.continueSetup()
        check(!flow.readable && flow.completed==0,"Continue rechecks access instead of trusting a stale ready badge")
        ProtectedLocalSource.allowed=true;flow.continueSetup();let reads=ProtectedLocalSource.reads
        flow.continueSetup()
        check(flow.completed==1 && ProtectedLocalSource.reads==reads,"Double-clicking Continue advances once")
        check(ProtectedLocalSource.reads[.imessage]==nil,"Only the explicitly chosen source is probed")
        let older=Flow();older.openGuide();guide.guide(.fullDiskAccess,dragging:Bundle.main.bundleURL)
        let replacement=guide.job!.id;older.closeOwnedGuide()
        check(guide.job?.id==replacement,"Dismissing old source UI cannot close another permission guide")
        let busy=Flow();let opens=guide.opens;SafeAppRelaunch.shared.isPreparing=true
        busy.openGuide();busy.continueSetup()
        check(guide.opens==opens && !busy.openedSettings && busy.completed==0,
              "Relaunch preparation prevents late grant and source-selection actions")
        print("PASS \(checks) source-access opt-in, readiness and guide-ownership checks")
    }
}
'''.replace('// HANDLERS','\n'.join(method(name) for name in ['openGuide','refreshAccess','continueSetup','closeOwnedGuide']))
with tempfile.TemporaryDirectory(prefix='sentient-source-access-flow-') as directory:
    path=Path(directory);(path/'Tests.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',str(path/'Tests.swift'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
