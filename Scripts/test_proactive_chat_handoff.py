#!/usr/bin/env python3
"""Exercise production card handoff methods without providers, permissions or real actions.

Compiles the real run/runReal/stopRun paths against deterministic in-memory collaborators.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import Foundation
import SwiftUI
struct PreparedAction {var id="card";var title="Reply to the planning email";var preparedContent="Original draft";var recipient="original@example.test";var fireable=true}
enum BriefingPhase:Equatable {case offer,working(Int),done}
struct Briefing {var id="card";var offer:String?="Send this reply";var workLog:[String]=[]}
enum SidekickConversationEvent {typealias ReplyReference=SidekickCardContext.Reply}
enum SidekickCardContext {
 static func canSubmit(_ action:PreparedAction)->Bool{action.fireable}
 struct Reply {let action:PreparedAction}
 static func reply(to action:PreparedAction)throws->Reply{.init(action:action)}
}
enum InviteProgram {enum Kind{case proactive};static let shared=Service();final class Service{func record(_ value:Kind){}}}
enum ProactiveExecutor {static func isFireable(_ action:PreparedAction)->Bool{action.fireable}}
final class Conversation {var navigationRequests=0;var draft="My unrelated draft";func requestNavigation(){navigationRequests+=1}}
final class Run {
 enum Outcome:Equatable {case success,failed,stopped}
 var isRunning=false;var activeCardID:String?;let conversation=Conversation()
 var completion:((Outcome)->Void)?
 func finish(_ outcome:Outcome){guard isRunning else{return};isRunning=false;activeCardID=nil;let callback=completion;completion=nil;callback?(outcome)}
 func stop(){finish(.stopped)}
}
final class CommandCoordinator {
 enum Source {case proactiveCard};enum Mode {case computer}
 func showSubmissionFailure(_ error:Error){}
 let run=Run();var refuse=false;var submitted:[(String,SidekickCardContext.Reply)]=[]
 func submit(_ text:String,mode:Mode,source:Source,reply:SidekickCardContext.Reply,onCompletion:((Run.Outcome)->Void)?)->Bool{
  guard !refuse,!run.isRunning else{return false}
  submitted.append((text,reply));run.isRunning=true;run.activeCardID=reply.action.id;run.completion=onCompletion;return true
 }
}
final class ForYouModel {
 struct Entry {let b:Briefing;var action:PreparedAction?;var phase=BriefingPhase.offer;var id:String{b.id}}
 var coordinator:CommandCoordinator?=CommandCoordinator();var entries=[Entry(b:Briefing(),action:PreparedAction())]
 var visit=0;var removedFromLatest:[String]=[];var draftPreviews:[String:(content:String,recipient:String)]=[:]
 func entry(_ id:String)->Entry?{entries.first{$0.id==id}}
 func update(_ id:String,_ mutate:(inout Entry)->Void){if let i=entries.firstIndex(where:{$0.id==id}){mutate(&entries[i])}}
 func applyEdit(_ id:String,content:String,recipient:String){update(id){$0.action?.preparedContent=content;$0.action?.recipient=recipient};draftPreviews[id]=nil}
 func dismiss(_ id:String,toward:CGSize){}
 // PRODUCTION_METHODS
}
@main enum Tests {
 static func main() {
  var checks=0
  func check(_ value:Bool,_ why:String){precondition(value,why);checks+=1}
  let model=ForYouModel(),coordinator=model.coordinator!
  model.draftPreviews["card"]=("Reviewed draft","reviewed@example.test")
  model.run("card")
  check(coordinator.submitted.count==1 && coordinator.submitted[0].0=="Do this for me.","Card uses ordinary main-agent submission with a readable request")
  let action=coordinator.submitted[0].1.action
  check(action.preparedContent=="Reviewed draft" && action.recipient=="reviewed@example.test","Latest unpersisted edits are frozen in the card reply")
  check(coordinator.run.conversation.navigationRequests==1 && coordinator.run.activeCardID=="card","Chat opens immediately and the main run owns the card")
  check(coordinator.run.conversation.draft=="My unrelated draft","Existing composer draft is preserved")
  model.run("card");check(coordinator.submitted.count==1,"Double click cannot submit twice")
  coordinator.run.finish(.success)
  check(model.entries.isEmpty,"Success retires the selected suggestion")
  for outcome in [Run.Outcome.failed,.stopped] {
   let next=ForYouModel();next.run("card");next.coordinator!.run.finish(outcome)
   check(next.entry("card")?.phase == .offer && next.removedFromLatest.isEmpty,"Failure/Stop preserves suggestion")
  }
  let stopped=ForYouModel();stopped.run("card");stopped.stopRun("card")
  check(!stopped.coordinator!.run.isRunning && stopped.entry("card")?.phase == .offer,"Card Stop cancels the ordinary Sidekick task")
  let hidden=ForYouModel();hidden.run("card");hidden.visit+=1;hidden.entries=[];hidden.coordinator!.run.finish(.success)
  check(!hidden.coordinator!.run.isRunning,"Leaving the card view does not lose completion")
  let busy=ForYouModel();busy.coordinator!.run.isRunning=true;busy.run("card")
  check(busy.coordinator!.submitted.isEmpty,"Existing Sidekick task prevents card launch")
  let refused=ForYouModel();refused.coordinator!.refuse=true;refused.run("card")
  check(refused.entry("card")?.phase == .offer && refused.coordinator!.run.conversation.navigationRequests==0,"Rejected admission preserves the suggestion")
  let info=ForYouModel();info.entries[0].action!.fireable=false;info.run("card")
  check(info.coordinator!.submitted.isEmpty,"Information-only cards remain non-executable")
  print("PASS \(checks) proactive-to-main-agent handoff checks")
 }
}
'''


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    source = (APP / "Views/HomeView.swift").read_text()
    methods = "\n".join(method(source, signature) for signature in [
        "    func run(_ id: String)", "    private func runReal(",
        "    func stopRun(", "    private static func replacing("])
    with tempfile.TemporaryDirectory(prefix="sentient-card-chat-") as temporary:
        root = Path(temporary)
        fixture = root / "CardChat.swift"
        fixture.write_text(FIXTURE.replace("// PRODUCTION_METHODS", methods))
        executable = root / "card-chat-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-parse-as-library", str(fixture), "-o", str(executable)], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
