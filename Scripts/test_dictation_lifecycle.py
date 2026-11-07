#!/usr/bin/env python3
"""Run production coordinator dictation methods with controllable mic/transport collaborators.
No app launch, microphone, account access, notification, or actual Sidekick execution.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'Sentient OS macOS/Notch Magic'
source=(APP/'CommandCoordinator.swift').read_text()

def method(signature):
    start=source.index(signature)
    end=source.index('{',start)+1
    depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}'); end+=1
    return source[start:end]

METHODS=['func microphoneMouseDown()', 'func startListening()', 'private func beginDictation()', 'func finishListening(',
         'private func finalizeVoice(', 'private func restoreDictationEditor(', 'private func keepDictationDraft(', 'private func dictationFailed(', 'private func cancelDictation()']
SWIFT=r'''
import Foundation
import AppKit
nonisolated func Log(_ text:String) {}
enum NotchPhase: Equatable { case hidden, typing, message, listening, transcribing, running }
enum AgentMode { case computer }
enum TriggerSource { case voice }
enum ScreenCapture { static func summaryDisplay()->UInt32? {1} }
enum SummaryAccessibility { static func target()->Int? {42} }
enum CodexAuth { static var knowledgeBaseOnly = false }
final class ComputerUseGate {
 static let shared=ComputerUseGate()
 func presentVoiceFixIfDenied()->Bool { false }
}
final class NotchPressGesture {
 var tap:(()->Void)?,hold:(()->Bool)?,release:(()->Void)?,releaseAway:(()->Void)?
 func begin(tap:@escaping ()->Void,hold:@escaping ()->Bool,release:@escaping ()->Void,releaseAway:(()->Void)?=nil,cancelOnEarlyDrag:Bool=true){self.tap=tap;self.hold=hold;self.release=release;self.releaseAway=releaseAway}
 func cancel(){tap=nil;hold=nil;release=nil;releaseAway=nil}
}
struct ReplyRecord { struct Event { var id = "reply-1" }; var event = Event() }
enum SidekickConversationStore {typealias Record = ReplyRecord}
final class Conversation { var draft="" }
final class Run { var isRunning=false; var hasDeliveredFinalAnswer=false; var runID=UUID(); var isClearingChat=false; let recovery=Recovery(); let conversation=Conversation() }
final class Recovery { var isPending=false }
final class DictationPresentation {
 var text="", capturing=false, connected=false
 var error:String?
 enum Context {case activity, composer, reply(ReplyRecord)}
 var context:Context = .activity
 var replyMessage:ReplyRecord? {if case .reply(let r)=context{return r};return nil}
 var keepsDraft:Bool {if case .activity=context{return false};return true}
 var finalizing=false
 var baseDraft=""
 func composedText(_ text:String)->String {baseDraft.isEmpty ? text : baseDraft + " " + text}
 func reset(context:Context = .activity,baseDraft:String=""){self.context=context;self.baseDraft=baseDraft;text="";capturing=false;connected=false;error=nil}
 func endContext(){context = .activity;baseDraft=""}
 func push(_ value:Float){}
}
nonisolated enum VoiceError: LocalizedError { case noMicrophone; var errorDescription:String? {"No mic"} }
nonisolated enum DictationFailure: LocalizedError { case timedOut; var errorDescription:String? {"Timed out"} }
final class VoiceCapture {
 static var isAuthorized=true
 static let maxCaptureDuration:TimeInterval=180
 var onTranscript:((String)->Void)?,onLevel:((Float)->Void)?,onReady:(()->Void)?,onFailure:((Error)->Void)?
 var starts=0,stops=0,cancels=0,finalizes=0
 var startWait:CheckedContinuation<Void,Never>?
 var finalWait:CheckedContinuation<String,Error>?
 var delayStart=false,stopped=false
 func start()async throws {
  starts+=1
  if delayStart { await withCheckedContinuation {startWait=$0} }
  try Task.checkCancellation()
 }
 func stopCapturing(){ stops+=1;stopped=true }
 func stopAndTranscribe()async throws->String {
  finalizes+=1
  return try await withCheckedThrowingContinuation {finalWait=$0}
 }
 func cancel(){ cancels+=1;stopped=true;finalWait?.resume(throwing:CancellationError());finalWait=nil }
 func resolve(_ text:String){finalWait?.resume(returning:text);finalWait=nil}
}
final class Proofread {var isRunning=false;func clearPreparedSelection(){};func waitForSelection()async{}}
final class ComposerDictation {func cancel(){}}
final class CommandCoordinator {
 let composerDictation=ComposerDictation()
 let proofread=Proofread()
 func prepareProofreadSelection(){}
 let run=Run(),voice=VoiceCapture(),dictation=DictationPresentation(),notchPress=NotchPressGesture()
 var phase=NotchPhase.typing,voiceSessionID:UUID?,listening=false,onboardingDemoArmed=false
 var voiceStartTask:Task<Void,Never>?,voiceFinalizeTask:Task<Void,Never>?,voiceLimitTask:Task<Void,Never>?
 var summaryDisplayID:UInt32?
 var summaryTarget:Int?
 var notchMessage:ReplyRecord?,messageTimer:Task<Void,Never>?,replyID:String?
 func prepareMessageReply(_ quote:String?,messageID:String){replyID=messageID}
 func setMessageReplyFocused(_ value:Bool,messageID:String){replyID=messageID}
 var submissions:[String]=[],notice=""
 static let needsPlusNotice="Unavailable"
 func interceptForOnboarding()->Bool {false}
 func setPhase(_ phase:NotchPhase){self.phase=phase;if phase != .listening && phase != .transcribing {dictation.endContext()}}
 func flash(_ text:String,for duration:Double=2){notice=text;phase = .hidden}
 func submit(_ text:String,mode:AgentMode,source:TriggerSource)->Bool{
   guard !run.isRunning, voiceSessionID == nil else{return false}
   submissions.append(text);run.isRunning=true;setPhase(.running);return true
 }
 func cancel(){cancelDictation();setPhase(.hidden)}
 // METHODS
}
@main struct Tests {
 static func settle(_ milliseconds:Int=30)async {try? await Task.sleep(for:.milliseconds(milliseconds))}
 static func main()async {
  var checks=0
  func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
  let clicked=CommandCoordinator();clicked.microphoneMouseDown()
  check(clicked.phase == .listening,"mic mouse-down immediately opens the new dictation form")
  clicked.notchPress.tap?();await settle()
  check(clicked.phase == .listening && clicked.voice.starts == 1 && clicked.voice.stops == 0,
        "short mic click keeps recording without requiring a hold")
  _ = clicked.finishListening(send:false);await settle();clicked.voice.resolve("clicked request");await settle(350)
  check(clicked.submissions.isEmpty && clicked.run.conversation.draft == "clicked request" && clicked.phase == .typing,
        "click stop keeps an editable draft and never submits")

  let held=CommandCoordinator();held.microphoneMouseDown();await settle()
  check(held.notchPress.hold?() == true,"mic hold qualifies the already-started session")
  held.notchPress.release?()
  check(held.voice.stopped && held.phase == .transcribing,"mic hold release stops and finalizes immediately")
  await settle();held.voice.resolve("held request");await settle(350)
  check(held.submissions == ["held request"],"mic hold sends exactly once")

  let replacement=CommandCoordinator();replacement.microphoneMouseDown();await settle()
  let oldRelease=replacement.notchPress.release
  replacement.cancel();replacement.phase = .typing;replacement.microphoneMouseDown();await settle()
  oldRelease?()
  check(replacement.phase == .listening && replacement.voice.stops == 0,"stale mic release cannot end a new recording")
  replacement.cancel()

  let blockedMic=CommandCoordinator();blockedMic.run.isRunning=true;blockedMic.microphoneMouseDown();await settle()
  check(blockedMic.voice.starts == 0 && blockedMic.notchPress.tap == nil,"blocked mic press cannot arm a later recording")

  let normal=CommandCoordinator();normal.startListening();await settle()
  normal.voice.onTranscript?("live words")
  check(normal.dictation.text == "live words", "partial text appears before release")
  check(normal.finishListening(), "first release accepted")
  check(normal.voice.stopped && normal.phase == .transcribing,"release synchronously stops capture and changes visual phase")
  check(!normal.finishListening(), "second release is ignored")
  await settle();normal.voice.resolve("final words");await settle(350)
  check(normal.submissions == ["final words"], "final text submitted exactly once")

  let waiting=CommandCoordinator();waiting.voice.delayStart=true
  waiting.startListening();await settle();_ = waiting.finishListening()
  check(waiting.voice.stopped, "release does not wait for startup")
  waiting.voice.startWait?.resume();waiting.voice.startWait=nil
  await settle();waiting.voice.resolve("captured before release");await settle(350)
  check(waiting.submissions.isEmpty && waiting.phase == .hidden, "release during permission setup cancels without late capture or submission")

  let cancelled=CommandCoordinator();cancelled.startListening();await settle()
  let staleUpdate=cancelled.voice.onTranscript
  _ = cancelled.finishListening();await settle();cancelled.cancel()
  staleUpdate?("must not appear");await settle()
  check(cancelled.submissions.isEmpty && cancelled.dictation.text.isEmpty,"late messages and finalize cannot revive cancelled session")
  cancelled.phase = .typing;cancelled.startListening();await settle()
  staleUpdate?("must not contaminate next hold")
  check(cancelled.dictation.text.isEmpty,"old callbacks cannot affect the next capture")
  cancelled.cancel()

  let failed=CommandCoordinator();failed.run.conversation.draft="existing draft"
  failed.startListening();await settle();failed.voice.onTranscript?("recoverable speech")
  failed.voice.onFailure?(DictationFailure.timedOut);await settle()
  check(failed.run.conversation.draft == "existing draft\nrecoverable speech","failure preserves both existing and dictated text")
  check(failed.submissions.isEmpty && failed.phase == .typing && failed.dictation.error != nil,"partial speech never executes after failure")

  let silent=CommandCoordinator();silent.startListening();await settle();_ = silent.finishListening()
  await settle();silent.voice.resolve("");await settle(350)
  check(silent.submissions.isEmpty && silent.phase == .typing,"empty recording returns to the editor without a flashing notice")
  let busy=CommandCoordinator();busy.run.isRunning=true;busy.startListening();await settle()
  check(busy.voice.starts == 0,"existing Sidekick task prevents capture")
  let question=CommandCoordinator();question.run.recovery.isPending=true;question.startListening();await settle()
  check(question.voice.starts == 0,"pending question cannot be overwritten by dictation")
  let early=CommandCoordinator();early.startListening();_ = early.finishListening();await settle()
  check(early.voice.starts == 0,"release before scheduled start prevents late mic opening")
  early.voice.resolve("");await settle(350)
  check(early.submissions.isEmpty,"early release cannot submit stale words")
  let reply=CommandCoordinator();reply.phase = .message;reply.notchMessage=ReplyRecord()
  reply.microphoneMouseDown();await settle()
  check(reply.phase == .listening && reply.dictation.replyMessage?.event.id == "reply-1", "response microphone keeps the message context")
  check(reply.replyID == "reply-1", "voice follow-up targets the original response")
  reply.voice.onTranscript?("tell me more")
  _ = reply.finishListening();await settle()
  check(reply.dictation.finalizing && reply.dictation.text == "tell me more", "finalization retains transcript presentation")
  reply.voice.resolve("tell me more");await settle(350)
  check(reply.submissions == ["tell me more"] && reply.dictation.replyMessage == nil, "follow-up sends once and clears voice presentation")
  let composing=CommandCoordinator();composing.run.conversation.draft="Keep this draft"
  composing.microphoneMouseDown();await settle()
  check(composing.dictation.keepsDraft && composing.dictation.replyMessage == nil,"typing mic retains composer context")
  composing.voice.onTranscript?("and add this")
  _ = composing.finishListening();await settle()
  composing.voice.resolve("and add this");await settle(350)
  check(composing.submissions == ["Keep this draft and add this"] && composing.run.conversation.draft.isEmpty,"typed and spoken text submit together exactly once")
  let editing=CommandCoordinator();editing.phase = .message;editing.notchMessage=ReplyRecord()
  editing.run.conversation.draft="Please"
  editing.microphoneMouseDown();await settle();_ = editing.finishListening(send:false);await settle()
  editing.voice.resolve("explain more");await settle()
  check(editing.submissions.isEmpty && editing.phase == .message && editing.notchMessage?.event.id == "reply-1",
        "stop dictation returns to the same response")
  check(editing.run.conversation.draft == "Please explain more" && editing.replyID == "reply-1",
        "stop retains existing text, transcript and reply reference exactly once")
  editing.microphoneMouseDown();await settle();editing.notchPress.releaseAway?();await settle()
  editing.voice.resolve("about this");await settle()
  check(editing.submissions.isEmpty && editing.run.conversation.draft == "Please explain more about this",
        "hold and release away keeps text for editing instead of submitting")
  let draining=CommandCoordinator();draining.phase = .message;draining.notchMessage=ReplyRecord()
  draining.run.isRunning=true;draining.run.hasDeliveredFinalAnswer=true
  draining.microphoneMouseDown();await settle()
  check(draining.voice.starts == 1,"a delivered final answer allows follow-up recording during cleanup")
  _ = draining.finishListening();await settle();draining.voice.resolve("follow up");await settle()
  check(draining.submissions.isEmpty,"final-answer cleanup lock still prevents overlapping tasks")
  draining.run.isRunning=false;await settle(100)
  check(draining.submissions == ["follow up"],"follow-up sends once after prior execution drains")
  print("PASS: \(checks) production dictation lifecycle checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-dictation-lifecycle-') as directory:
 path=Path(directory);fixture=path/'test.swift'
 fixture.write_text(SWIFT.replace('// METHODS','\n'.join(method(name) for name in METHODS)))
 binary=path/'test'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',str(fixture),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],check=True,timeout=20)
