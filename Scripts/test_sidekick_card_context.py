#!/usr/bin/env python3
"""Verify reviewed card snapshots, evidence checks and retirement with no app/model calls."""
from pathlib import Path
import subprocess, tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
def member(source,signature):
 start=source.index(signature);end=source.index('{',start)+1;depth=1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
event=member((APP/'Notch Magic/SidekickConversationStore.swift').read_text(),'nonisolated struct SidekickConversationEvent:')
action=member((APP/'Proactive/ProactiveResearch.swift').read_text(),'struct PreparedAction:')
support=r'''
import Foundation
nonisolated enum ActionItem {enum Urgency:String,Codable {case soon}}
nonisolated enum OutlookMailConnector {static let slug="outlook-mail";enum Operation:String,Codable {case send};static func cachedFingerprint()->String? {"account-fixture"}}
nonisolated enum OutlookCalendarConnector {static let slug="outlook-calendar";enum Operation:String,Codable {case create};static func cachedFingerprint()->String? {"account-fixture"}}
nonisolated enum SlackConnector {struct Identity {let fingerprint:String};nonisolated(unsafe) static var identity:String?="account-fixture";static func cachedIdentity()->Identity? {identity.map {Identity(fingerprint:$0)}}}
nonisolated enum AppleMailResearch {struct Evidence:Codable {let token:String}}
nonisolated enum SidekickContext {static func json<T:Encodable>(_ value:T)->String{String(decoding:try! JSONEncoder().encode(value),as:UTF8.self)}}
nonisolated enum ProactiveExecutor {
 nonisolated(unsafe) static var canFire=true
 nonisolated(unsafe) static var issue:String?
 static func isFireable(_ action:PreparedAction)->Bool{canFire && action.method != .research}
 static func mailEvidenceIssue(_ action:PreparedAction)async->String?{issue}
}
nonisolated struct ReadyResult {let ready:[PreparedAction];let dropped:[String]}
nonisolated enum ProactiveResearch {
 nonisolated(unsafe) static var saved:ReadyResult?
 static func latest()->ReadyResult?{saved}
 static func saveLatest(_ result:ReadyResult){saved=result}
}
'''
coordinator=(APP/'Notch Magic/CommandCoordinator.swift').read_text()
launch=member(coordinator,'    private func launch(').replace('private func launch(', 'func launch(')
support+=r'''
nonisolated enum AgentMode {case computer;var label:String {"computer"}}
nonisolated enum TriggerSource:String {case promptBar,notchTyped,voice,proactiveCard="proactive_card"}
nonisolated enum Analytics {enum Tier {case core};static func signal(_ name:String,parameters:[String:String],tier:Tier){}}
nonisolated enum SidekickDiscovery {static func recordNotchUse(){}}
nonisolated enum InviteProgram {enum Kind{case sidekick};struct Service{func record(_ kind:Kind){}};static let shared=Service()}
func Log(_ line:String){}
@MainActor final class CommandRunModel {
 enum Outcome {case success,failed,stopped}
 final class Conversation {var replyReference:SidekickConversationEvent.ReplyReference?}
 var isRunning=false;var isClearingChat=false;let conversation=Conversation()
 var preflight:(@MainActor () async throws->Void)?;var completion:((Outcome)->Void)?
 var received:SidekickConversationEvent.ReplyReference?
 func start(_ text:String,mode:AgentMode,source:String,reply:SidekickConversationEvent.ReplyReference?,preflight:(@MainActor () async throws->Void)?,onCompletion:((Outcome)->Void)?){isRunning=true;received=reply;self.preflight=preflight;completion=onCompletion}
}
@MainActor final class CommandCoordinator {
 let run=CommandRunModel();enum Phase {case running}
 func setReadBack(_ text:String){};func clearReadBack(){};func setPhase(_ phase:Phase){};func runFinished(_ outcome:CommandRunModel.Outcome){}
 // LAUNCH
}
'''
support=support.replace('// LAUNCH',launch)

tests=r'''
@main struct Tests {
 static func main()async throws {
  var count=0
  func check(_ condition:Bool,_ message:String){precondition(condition,message);count+=1}
  var action=PreparedAction(title:"Reply to Sam",method:.gmail,target:"Gmail",urgency:.soon,dueDate:nil,status:.confirmed,
    verification:"Checked thread",cardSummary:"The planning reply is ready",preparedContent:"My edited draft 😊",executionRecipe:"Use the original thread",
    buttonText:"Send reply",detailLabel:"Read draft",sources:["thread-fixture"],reviewNote:"")
  action.recipient="reviewed@example.test";action.connectorIdentity="account-fixture"
  let reply=try SidekickCardContext.reply(to:action),card=reply.card!
  let decoded=try JSONDecoder().decode(PreparedAction.self,from:Data(card.actionJSON.utf8))
  check(decoded.preparedContent==action.preparedContent && decoded.recipient==action.recipient && decoded.connectorIdentity==action.connectorIdentity,"Exact edited content, recipient and account context survive")
  check(reply.messageID==card.referenceID && card.title==action.title && card.summary==action.cardSummary,"Reply preview identifies the selected card snapshot")
  try await SidekickCardContext.validate(card);check(true,"Current card passes source checks")
  var bound=action;bound.methodTarget="slack"
  let boundCard=try SidekickCardContext.reply(to:bound).card!
  SlackConnector.identity="different-account"
  do{try await SidekickCardContext.validate(boundCard);fatalError("changed account accepted")}catch{count+=1}
  SlackConnector.identity="account-fixture";ProactiveExecutor.issue="Original email changed"
  do{try await SidekickCardContext.validate(card);fatalError("stale evidence accepted")}catch{count+=1}
  ProactiveExecutor.issue=nil
  ProactiveResearch.saved=ReadyResult(ready:[action],dropped:["preserved"])
  SidekickCardContext.finish(card,succeeded:false)
  check(ProactiveResearch.latest()!.ready.count==1,"Failure or Stop retains suggestion")
  SidekickCardContext.finish(card,succeeded:true)
  check(ProactiveResearch.latest()!.ready.isEmpty && ProactiveResearch.latest()!.dropped==["preserved"],"Success retires only reviewed card and preserves other metadata")
  var changed=action;changed.preparedContent="New suggestion with the same title"
  ProactiveResearch.saved=ReadyResult(ready:[changed],dropped:[])
  SidekickCardContext.finish(card,succeeded:true)
  check(ProactiveResearch.latest()!.ready.count==1,"Old task cannot retire a newer changed suggestion")
  let restored=try JSONDecoder().decode(SidekickConversationEvent.ReplyReference.self,from:JSONEncoder().encode(reply))
  ProactiveResearch.saved=ReadyResult(ready:[action],dropped:[])
  SidekickCardContext.finish(restored.card!,succeeded:true)
  check(ProactiveResearch.latest()!.ready.isEmpty,"Restored permission draft can retire the same reviewed suggestion")
  let coordinator=CommandCoordinator()
  ProactiveResearch.saved=ReadyResult(ready:[action],dropped:[])
  var completed=false
  check(coordinator.launch("Do this for me.",mode:.computer,source:.proactiveCard,reply:reply,onCompletion:{_ in completed=true}),"Real coordinator launch accepts card as an ordinary request")
  check(coordinator.run.received==reply,"Coordinator forwards the durable card reply")
  try await coordinator.run.preflight?()
  coordinator.run.completion?(.success)
  check(completed && ProactiveResearch.latest()!.ready.isEmpty,"Real launch closure retires the card and notifies UI after success")
  print("PASS \(count) reviewed-card context checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-card-context-') as directory:
 p=Path(directory);(p/'Fixture.swift').write_text(support+'\n'+event+'\n'+action+'\n'+tests)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor',str(p/'Fixture.swift'),str(APP/'Notch Magic/SidekickCardContext.swift'),'-o',str(p/'tests')],check=True)
 subprocess.run([str(p/'tests')],check=True)
