#!/usr/bin/env python3
"""Exercise the production notch action routing before ordinary Sidekick/provider gates."""
from pathlib import Path
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'Sentient OS macOS'
source=(APP/'Notch Magic/CommandCoordinator.swift').read_text()
def method(signature):
    start=source.index(signature); end=source.index('{',start)+1; depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]
fixture=r'''
import AppKit
import Foundation
enum AgentMode { case computer }
enum TriggerSource { case voice, notchTyped, promptBar, proactiveCard }
enum NotchAnchor { case mainDisplay }
enum NotchPhase:Equatable { case hidden, typing, opening, running;case notice(String) }
enum ShortcutPreferences {static var isRecording=false}
struct ShortcutActivity:Equatable {var keys=0;static var current=Self()}
final class QuickActionHotkeys {var enabled=false;func setEnabled(_ value:Bool){enabled=value}}
final class Recovery {var isPending=false}
enum CodexAuth { static var knowledgeBaseOnly=false }
enum SummaryAccessibility { static func target()->Int? {42} }
enum ScreenCapture { static var display:UInt32?=42;static func summaryDisplay()->UInt32?{display} }
enum SidekickConversationEvent { struct ReplyReference {} }
enum CommandRunModel { enum Outcome {case success} }
final class Conversation {var replyReference:SidekickConversationEvent.ReplyReference?;var draft="existing draft"}
final class Run {var isRunning=false,isClearingChat=false;let conversation=Conversation();let recovery=Recovery()}
final class Summary {var starts=0;var preference="";var display:UInt32?;var target:Int?;func start(displayID:UInt32,preference:String,target:Int?){self.target=target;starts+=1;self.preference=preference;display=displayID}}
struct Pair{mutating func reset(){}}
final class Proofread {var isRunning=false,starts=0,clears=0,captureWasInterrupted=false;func clearPreparedSelection(){clears+=1};func waitForSelection()async{try? await Task.sleep(for:.milliseconds(30))};func start(completion:(String)->Void)->Bool{starts+=1;isRunning=true;return true}}
final class DoubleTap {static let shared=DoubleTap();var isDrafting=false}
final class Coordinator {
 let proofread=Proofread()
 let quickActionHotkeys=QuickActionHotkeys()
 var quickActionTask:Task<Void,Never>?,quickActionID:UUID?,preparations=0
 func prepareProofreadSelection(){preparations+=1}
 let run=Run(),summarize=Summary()
 var quickActionsAvailable=true,summaryDisplayID:UInt32?=7,voiceSessionID:UUID?
 var summaryTarget:Int?=7
 var phase=NotchPhase.typing,notchAnchor=NotchAnchor.mainDisplay
 var pendingSingleTap:Task<Void,Never>?,hotkeyPair=Pair(),returningFromRecovery=false
 var blockedOnboarding=false,launches:[String]=[],notices:[String]=[]
 static let needsPlusNotice="Plus needed"
 func interceptForOnboarding()->Bool{blockedOnboarding}
 func flash(_ value:String,for duration:Double=2){notices.append(value)}
 func clearReadBack(){}
 func setPhase(_ phase:NotchPhase){self.phase=phase}
 func launch(_ text:String,mode:AgentMode,source:TriggerSource,reply:SidekickConversationEvent.ReplyReference?,onCompletion:((CommandRunModel.Outcome)->Void)?)->Bool{launches.append(text);return true}
 // METHODS
}
@main enum Test{
 static func main()async{
  _ = NSApplication.shared
  var checks=0
  func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
  let voice=Coordinator();CodexAuth.knowledgeBaseOnly=true
  check(voice.submit("Can you summarize this?",mode:.computer,source:.voice),"voice summary admitted without Sidekick subscription")
  check(voice.summarize.starts==1 && voice.launches.isEmpty && voice.summarize.display==7,"summary uses remembered display and dedicated feature")
  check(voice.phase == .hidden && voice.run.conversation.draft=="existing draft","notch retracts without discarding unrelated draft")
  let ordinary=Coordinator()
  check(!ordinary.submit("reply to this",mode:.computer,source:.voice) && ordinary.summarize.starts==0,"ordinary requests retain their provider gate")
  CodexAuth.knowledgeBaseOnly=false
  for text in ["I'll summarize it tomorrow","don't summarize this","summarize the file report.pdf","summarize this and email it"]{
   let c=Coordinator();check(c.submit(text,mode:.computer,source:.voice) && c.launches==[text] && c.summarize.starts==0,"ordinary request retained: "+text)
  }
  let typed=Coordinator();check(typed.submit("summarize this in three bullets",mode:.computer,source:.notchTyped) && typed.summarize.preference.contains("three bullets"),"typed request preserves modifier")
  let context=Coordinator();context.run.conversation.replyReference = .init()
  check(context.submit("summarize this",mode:.computer,source:.notchTyped) && context.summarize.starts==0 && context.launches.count==1,"reply context remains a conversation request")
  for source in [TriggerSource.promptBar,.proactiveCard]{
   let c=Coordinator();check(c.submit("summarize",mode:.computer,source:source) && c.launches.count==1,"other command sources retain their original semantics")
  }
  let button=Coordinator();check(button.summarizeScreen() && button.summarize.starts==1 && button.run.conversation.draft=="existing draft","button preserves existing input")
  let incomplete=Coordinator();incomplete.voiceSessionID=UUID()
  check(!incomplete.submit("summarize",mode:.computer,source:.voice) && incomplete.summarize.starts==0,"partial dictation cannot trigger")
  let onboarding=Coordinator();onboarding.blockedOnboarding=true
  check(!onboarding.submit("summarize",mode:.computer,source:.voice),"onboarding admission remains")
  let unavailable=Coordinator();unavailable.summaryDisplayID=nil;ScreenCapture.display=nil
  check(!unavailable.summarizeScreen() && unavailable.summarize.starts==0 && !unavailable.notices.isEmpty,"no display cannot dispatch")
  ScreenCapture.display=42
  let proofreading=Coordinator();CodexAuth.knowledgeBaseOnly=true
  check(proofreading.submit("Can you proofread this?",mode:.computer,source:.voice) && proofreading.proofread.starts==1 && proofreading.launches.isEmpty,"voice proofread bypasses ordinary provider gate")
  check(!proofreading.submit("reply to this",mode:.computer,source:.notchTyped),"running proofreading prevents Sidekick overlap")
  CodexAuth.knowledgeBaseOnly=false;DoubleTap.shared.isDrafting=true
  let busy=Coordinator();check(!busy.proofreadSelection() && busy.proofread.starts==0,"Double Tap blocks proofreading start")
  DoubleTap.shared.isDrafting=false
  let mention=Coordinator();check(mention.submit("I'll proofread it tomorrow",mode:.computer,source:.voice) && mention.proofread.starts==0 && mention.launches.count==1,"proofread mention stays ordinary dictation")
  let globalSummary=Coordinator();globalSummary.phase = .hidden
  globalSummary.handleQuickActionShortcut(.summarize)
  check(globalSummary.summarize.display==42 && globalSummary.summarize.target==42,"global summary refreshes an old display anchor")
  let typedSummary=Coordinator();typedSummary.handleQuickActionShortcut(.summarize)
  check(typedSummary.summarize.display==7 && typedSummary.summarize.target==7,"summary from an open notch retains its original display")
  let globalProofread=Coordinator();globalProofread.phase = .hidden
  globalProofread.handleQuickActionShortcut(.proofread)
  check(globalProofread.preparations==1 && globalProofread.proofread.starts==0 && globalProofread.phase == .hidden,"global proofread captures without taking focus")
  try? await Task.sleep(for:.milliseconds(60))
  check(globalProofread.proofread.starts==1,"global proofread uses the existing action after capture")
  let openProofread=Coordinator();openProofread.handleQuickActionShortcut(.proofread)
  try? await Task.sleep(for:.milliseconds(60))
  check(openProofread.preparations==0 && openProofread.proofread.starts==1,"open-notch shortcut reuses the original selection")
  let stale=Coordinator();stale.phase = .hidden;stale.handleQuickActionShortcut(.proofread)
  ShortcutActivity.current.keys+=1;try? await Task.sleep(for:.milliseconds(60))
  check(stale.proofread.starts==0 && stale.proofread.clears>0,"intervening input discards stale shortcut preparation")
  let cancelled=Coordinator();cancelled.phase = .hidden;cancelled.handleQuickActionShortcut(.proofread);cancelled.cancelQuickActionPreparation()
  try? await Task.sleep(for:.milliseconds(60));check(cancelled.proofread.starts==0,"cancelled shortcut cannot dispatch late")
  let competing=Coordinator();competing.phase = .hidden;competing.run.isRunning=true;competing.handleQuickActionShortcut(.proofread)
  check(competing.preparations==0,"proofreading shortcut does not overlap a computer action")
  let recording=Coordinator();ShortcutPreferences.isRecording=true;recording.refreshQuickActionShortcuts();recording.handleQuickActionShortcut(.summarize)
  check(!recording.quickActionHotkeys.enabled && recording.summarize.starts==0,"shortcut recorder suspends quick actions")
  ShortcutPreferences.isRecording=false;recording.refreshQuickActionShortcuts();check(recording.quickActionHotkeys.enabled,"closing recorder restores quick actions")
  recording.quickActionsAvailable=false;recording.refreshQuickActionShortcuts();check(!recording.quickActionHotkeys.enabled,"onboarding/reset releases global quick actions")
  print("PASS: \(checks) production notch action routing checks")
 }
}
'''
fixture=fixture.replace('// METHODS','\n'.join(method(sig) for sig in ['func summarizeScreen(', 'func proofreadSelection(', 'func submit(', 'func handleQuickActionShortcut(', 'func cancelQuickActionPreparation(', 'func refreshQuickActionShortcuts(', 'private func interruptHotkeyGesture(']))
with tempfile.TemporaryDirectory(prefix='sentient-summary-routing-') as temporary:
    path=Path(temporary);(path/'Routing.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor','-parse-as-library',
        str(APP/'System/Shortcuts/QuickActionShortcut.swift'),str(APP/'Proofread/ProofreadRequest.swift'),str(APP/'Summarize/SummaryRequest.swift'),str(path/'Routing.swift'),'-o',str(path/'test')],check=True,timeout=60)
    subprocess.run([str(path/'test')],check=True,timeout=10)
