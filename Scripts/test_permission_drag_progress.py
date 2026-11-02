#!/usr/bin/env python3
"""Exercise actual drag-end and guide callbacks without dragging or changing macOS grants."""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
def method(path, signature):
    source = (APP / path).read_text()
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

guide = method('Views/Permissions/PermissionGuide.swift', '    func finishedDrag(')
ended = method('Views/Permissions/PermissionDragPanel.swift', '    func draggingSession(_ session: NSDraggingSession, endedAt')
ended = ended.replace('NSDraggingSession', 'Int')
fixture = r'''
import AppKit
@MainActor final class Guide {
    struct Job {let id=UUID()}
    struct Tracker {var currentFrame:CGRect?=CGRect(x:100,y:100,width:300,height:300)}
    var job:Job?=Job();var tracker=Tracker();var onDrop:(()->Void)?
    // GUIDE
}
@MainActor final class Source {
    var onDragStateChange:((Bool)->Void)?
    var activeDrop:((NSPoint,NSDragOperation)->Void)?
    var mouseDownPoint:NSPoint? = .zero
    var hasBegunDragging=true
    // ENDED
}
@main struct Main {
    @MainActor static func main() {
        let guide=Guide();let source=Source();var drops=0;var ended=0
        guide.onDrop={drops+=1};source.onDragStateChange={precondition(!$0);ended+=1}
        let id=guide.job!.id
        func arm() {source.activeDrop={guide.finishedDrag(jobID:id,at:$0,operation:$1)}}
        arm();source.draggingSession(0,endedAt:NSPoint(x:150,y:150),operation:[])
        precondition(drops==0,"Cancelled drag cannot count as setup progress")
        arm();source.draggingSession(0,endedAt:NSPoint(x:10,y:10),operation:.copy)
        precondition(drops==0,"Drop outside Settings cannot count")
        arm();source.draggingSession(0,endedAt:NSPoint(x:150,y:150),operation:.copy)
        precondition(drops==1,"Accepted copy inside Settings reports progress")
        source.draggingSession(0,endedAt:NSPoint(x:150,y:150),operation:.copy)
        precondition(drops==1,"Duplicate end callback cannot repeat progress")
        guide.job=Guide.Job();arm();source.draggingSession(0,endedAt:NSPoint(x:150,y:150),operation:.copy)
        precondition(drops==1,"Old drag cannot mark a replacement guide's permission")
        guide.job=nil;arm();source.draggingSession(0,endedAt:NSPoint(x:150,y:150),operation:.copy)
        precondition(drops==1 && ended==6 && !source.hasBegunDragging && source.mouseDownPoint==nil,
                     "Closed guide ignores completion and all outcomes restore drag state")
        print("PASS 6 cancelled, misplaced, accepted, duplicate and stale permission drag checks")
    }
}
'''.replace('// GUIDE', guide).replace('// ENDED', ended)
with tempfile.TemporaryDirectory(prefix='sentient-drag-progress-') as directory:
    path=Path(directory);(path/'Fixture.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(path/'Fixture.swift'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
