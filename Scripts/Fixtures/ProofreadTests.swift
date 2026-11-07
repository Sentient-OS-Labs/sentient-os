// Production request, parser, lifecycle and clipboard tests with synthetic capture/insertion.
// No editor mutation, provider billing, microphone, or production clipboard is used.
import AppKit
import Foundation
import ApplicationServices

enum ScreenRelay {
    static var url: URL? { URL(string: CommandLine.arguments[1]) }
    static func identity() throws -> String { String(repeating:"a",count:43) }
}
struct ShortcutActivity: Equatable { var keys=0; static var current=Self() }
enum Permissions { static func hasAccessibility()->Bool{false} }
final class DoubleTap {static let shared=DoubleTap();var isDrafting=false}
final class ProofreadResultPanel {func close(){};func show(text:String?,explanation:String,permission:Bool){fatalError("unexpected window")}}

@main enum Tests {
    static var checks=0
    static func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
    static func reject(_ label:String,_ body:()throws->Void){do{try body();fatalError(label)}catch{checks+=1}}
    static func settle()async{try? await Task.sleep(for:.milliseconds(25))}
    static func snapshot(_ text:String="teh sample",replace:Bool=true)->ProofreadSelection.Snapshot {
        .init(pid:-999,element:AXUIElementCreateApplication(-999),window:nil,range:CFRange(location:0,length:(text as NSString).length),
              text:text,originalValue:text,canReplace:replace)
    }
    static func main()async throws {
        for text in ["proofread","Proofread this!","please proofread the selected text","Can you proofread this for me?","proof read my selection","hey Sentient, proofread it"] {
            check(ProofreadRequest.matches(text),"explicit request: "+text)
        }
        for text in ["I'll proofread this tomorrow","don't proofread this","say proofread","proofreading","proofread this and send it","proofread the following: hi","\"proofread\"",""] {
            check(!ProofreadRequest.matches(text),"do not hijack: "+text)
        }
        let exact="  Corrected text.\n\n🙂  "
        let json=String(data:try JSONSerialization.data(withJSONObject:["corrected_text":exact]),encoding:.utf8)!
        check(try ProofreadInference.decode(json)==exact,"leading/trailing whitespace and paragraphs preserved")
        for invalid in ["plain text","{}","{\"corrected_text\":\"\"}","{\"corrected_text\":2}","{\"corrected_text\":\"x\",\"extra\":true}","{\"corrected_text\":\"x"] {
            reject("invalid correction"){_ = try ProofreadInference.decode(invalid)}
        }
        check(try ProofreadInference.decode("{\"corrected_text\":\"The sample\"}", original: "  teh sample  ")=="  The sample  ","boundary whitespace restored mechanically")
        reject("paragraph deletion refused") { _ = try ProofreadInference.decode("{\"corrected_text\":\"One two\"}", original: "One\n\nTwo") }
        check(!ProofreadSelection.sameText("é", "e\u{301}"), "Unicode normalization cannot conceal shifted AX offsets")
        let source="A 👩🏽‍💻 café phrase"
        let range=(source as NSString).range(of:"👩🏽‍💻 café")
        check(ProofreadSelection.substring(source,range:CFRange(location:range.location,length:range.length))=="👩🏽‍💻 café","AX range uses UTF16 offsets")
        check(ProofreadSelection.substring(source,range:CFRange(location:Int.max,length:2))==nil,"overflow range refused")
        check(ProofreadSelection.substring(source,range:CFRange(location:-1,length:1))==nil,"negative range refused")
        check(await ProofreadSelection.apply("the sample",to:snapshot(),activity:.current) == .changed,"wrong app rejected before AX or clipboard")
        check(await ProofreadSelection.apply("the sample",to:snapshot(replace:false),activity:.current) == .unsupported,"unsupported selection never pastes")

        let board=NSPasteboard(name:NSPasteboard.Name("sentient-proofread-test-"+UUID().uuidString))
        defer{board.releaseGlobally()}
        board.clearContents()
        let empty=ProofreadClipboard.capture(from:board)!
        board.setString("temporary",forType:.string);empty.restore(ifOwned:board.changeCount)
        check(board.pasteboardItems?.isEmpty != false,"empty clipboard restored")
        let item=NSPasteboardItem();item.setString("old",forType:.string);item.setData(Data("{\\rtf1 old}".utf8),forType:.rtf)
        board.writeObjects([item]);let saved=ProofreadClipboard.capture(from:board)!
        board.clearContents();board.setString("replacement",forType:.string);saved.restore(ifOwned:board.changeCount)
        check(board.string(forType:.string)=="old" && board.data(forType:.rtf)==Data("{\\rtf1 old}".utf8),"all clipboard formats restored")
        let owned=board.changeCount;board.clearContents();board.setString("new user copy",forType:.string);saved.restore(ifOwned:owned)
        check(board.string(forType:.string)=="new user copy","intervening clipboard change survives")
        board.clearContents();board.setData(Data(repeating:1,count:4_000_001),forType:.rtf)
        check(ProofreadClipboard.capture(from:board)==nil,"large clipboard prevents unsafe replacement")

        check(try await ProofreadInference.correct("teh sample")=="the sample","actual HTTP client through real relay with synthetic upstream")
        for text in ["interrupted","malformed","network-error"] {
            do{_ = try await ProofreadInference.correct(text);fatalError("bad network result")}catch{checks+=1}
        }
        var pending:CheckedContinuation<String,Error>?,captures=0,insertions=0,results:[String]=[],messages:[String]=[]
        let model=Proofread(capture:{captures+=1;return snapshot()},correct:{_ in try await withCheckedThrowingContinuation{pending=$0}},
            apply:{text,_,_ in check(text=="the sample","only validated complete result inserted");insertions+=1;return .applied},
            showResult:{_,message,_ in results.append(message)})
        model.prepareSelection();check(model.isCapturingSelection,"capture gates notch focus");await model.waitForSelection()
        check(!model.isCapturingSelection && captures==1,"selection capture finishes")
        check(model.start{messages.append($0)},"start accepted");await settle()
        check(insertions==0 && model.isRunning,"no edit while model pending")
        check(!model.start{_ in},"duplicate start refused")
        pending?.resume(returning:"the sample");pending=nil;await settle()
        check(insertions==1 && !model.isRunning && messages.last=="","one complete correction applied without a completion caption")
        model.prepareSelection();await model.waitForSelection();_ = model.start{messages.append($0)};await settle()
        pending?.resume(returning:"teh sample");pending=nil;await settle()
        check(insertions==1 && messages.last=="Looks good.","unchanged text creates no undo edit")
        model.prepareSelection();await model.waitForSelection();_ = model.start{messages.append($0)};await settle()
        let old=pending;pending=nil;model.cancel();model.prepareSelection();await model.waitForSelection();_ = model.start{messages.append($0)};await settle()
        old?.resume(returning:"the sample");await settle()
        check(insertions==1 && model.isRunning,"late cancelled correction cannot edit or finish newer request")
        pending?.resume(throwing:ProofreadInference.Failure.incomplete);pending=nil;await settle()
        check(insertions==1 && results.count==1 && !model.isRunning,"incomplete result preserves original")
        let changed=Proofread(capture:{snapshot()},correct:{_ in "the sample"},apply:{_,_,_ in .changed},showResult:{text,_,_ in check(text=="the sample","changed target keeps corrected copy")})
        changed.prepareSelection();await changed.waitForSelection();_ = changed.start{_ in};await settle()
        check(!changed.isRunning,"fallback releases editing lock")
        DoubleTap.shared.isDrafting=true;check(!changed.start{_ in},"Double Tap cannot overlap proofreading");DoubleTap.shared.isDrafting=false
        var slowCapture:CheckedContinuation<ProofreadSelection.Snapshot,Error>?
        let cancelled=Proofread(capture:{try await withCheckedThrowingContinuation{slowCapture=$0}},correct:{_ in fatalError("cancelled capture")},showResult:{_,_,_ in})
        cancelled.prepareSelection();await settle();cancelled.clearPreparedSelection();slowCapture?.resume(returning:snapshot());await settle()
        check(!cancelled.isCapturingSelection,"stale capture cannot revive selection")
        var interruptedCapture:CheckedContinuation<ProofreadSelection.Snapshot,Error>?
        let interrupted=Proofread(capture:{try await withCheckedThrowingContinuation{interruptedCapture=$0}},correct:{_ in fatalError("interrupted capture")},showResult:{_,_,_ in})
        interrupted.prepareSelection();await settle();ShortcutActivity.current.keys+=1
        interruptedCapture?.resume(returning:snapshot());await settle()
        check(interrupted.captureWasInterrupted && !interrupted.isCapturingSelection,"input during capture prevents a late focus steal")
        interrupted.clearPreparedSelection()
        var slow:CheckedContinuation<String,Error>?
        var timeoutMessages:[String]=[]
        let timeout=Proofread(capture:{snapshot()},correct:{_ in try await withCheckedThrowingContinuation{slow=$0}},apply:{_,_,_ in fatalError("timed out edit")},showResult:{_,_,_ in},deadline:.milliseconds(50))
        timeout.prepareSelection();await timeout.waitForSelection();_ = timeout.start{timeoutMessages.append($0)}
        try await Task.sleep(for:.milliseconds(90));check(!timeout.isRunning && timeoutMessages.count==1,"deadline cancels and releases operation")
        slow?.resume(returning:"the sample");await settle();check(timeoutMessages.count==1,"late timeout response cannot edit or finish twice")
        var insertion:CheckedContinuation<ProofreadSelection.Outcome,Never>?,cancelMessages:[String]=[]
        let draining=Proofread(capture:{snapshot()},correct:{_ in "the sample"},apply:{_,_,_ in await withCheckedContinuation{insertion=$0}},showResult:{_,_,_ in fatalError("late applied result")})
        draining.prepareSelection();await draining.waitForSelection();_ = draining.start{cancelMessages.append($0)};await settle()
        draining.cancel();check(draining.isRunning && !draining.start{_ in},"cancel keeps editing gate until posted insertion drains")
        draining.cancel();check(cancelMessages.count==1,"repeated cancel cannot release the cleanup gate")
        insertion?.resume(returning:.applied);await settle()
        check(!draining.isRunning && cancelMessages.count==1,"cleanup releases gate without a late completion")
        print("PASS: \(checks) proofreading request, transport, clipboard and lifecycle checks")
    }
}
