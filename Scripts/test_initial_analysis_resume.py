#!/usr/bin/env python3
"""Exercise actual coordinator pause, restart and scheduling methods with inert workers.
No app launch, service registration, real preferences, provider requests or user data.
"""
from pathlib import Path
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
s=(APP/'Ingestion/ProcessingCoordinator.swift').read_text()
def method(signature):
 a=s.index(signature);b=s.index('{',a)+1;depth=1
 while depth:
  depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b].replace('private ','',1)
fixture=r'''
import Foundation
struct RunProgress {var done=0}
struct CycleFailure:Error,Equatable {}
enum CodexTrigger {case onboarding,analyzeNow,overnight}
enum ModelBackend:String {case fixture;static let current=Self.fixture}
enum PowerState {enum Block:String {case thermal,batteryLow};struct Snapshot {var critical=false}}
struct ProcessingRequest:Sendable {var fullCycle=true;var readySelectionCount:Int?=3;static func current()->Self{Self()}}
enum Phase {case knowledgeBase(String),deciding,researching(Int),done,failed}
@MainActor final class ProcessingRun {
 struct Result {var progress=RunProgress()}
 static var scopes:[Bool]=[]
 init(request:ProcessingRequest,scheduled:Bool){}
 func execute(progress:@escaping @Sendable(RunProgress)->Void,phase:@escaping @Sendable(Phase)->Void,
              onLine:@escaping @Sendable(String)->Void)async->Result {
  Self.scopes.append(InitialAnalysisRecovery.replayCloudStages);return Result()
 }
}
enum DiagnosticHistory {
 enum Kind {case overnight};enum Outcome{case blocked,stalled,stopped}
 static func begin(_ kind:Kind,provider:String)->UUID{UUID()}
 static func finish(_ kind:Kind,id:UUID,outcome:Outcome,reason:String){}
}
enum Analytics {static func signal(_ name:String,parameters:[String:String]){}}
enum OvernightCaution {enum Kind{case stalled};static func record(_ kind:Kind){}}
enum OvernightScheduler {static let configuredMinutes=180;static func nextOccurrence(minutesSinceMidnight:Int)->Date{Date()}}
enum CrashReporting {enum Level{case warning};static func captureEvent(_ name:String,level:Level,tags:[String:String],fingerprint:[String]){}}
@MainActor final class Coordinator {
 let defaults:UserDefaults
 var record:ProcessingPlan.Record {didSet{ProcessingPlan.save(record,to:defaults)}}
 var state=State.idle
 var initialComplete=false;var isBusy=false;var isSuspended=false
 var paused:Bool {record.status == .paused}
 var requestOverride:ProcessingRequest?;var carried=RunProgress();var task:Task<Void,Never>?
 var stopReason:Stop?;var diagnosticID:UUID?;var begins=0;var deferrals=0;var checks=0
 var power=PowerState.Snapshot();var runID=UUID();var lastProgressAt=Date()
 var thought:String?;var prepStatus="";var prepSubtext:String?
 init(defaults:UserDefaults){self.defaults=defaults;record = .init()}
 func startMonitoring(){}
 func checkPendingWork(){checks+=1}
 func admission(_ request:ProcessingRequest,scheduled:Bool)->Wait?{nil}
 func sourceAdmissionNotice(_ request:ProcessingRequest)->String{"fixture"}
 func detail(for wait:Wait)->String{"fixture"}
 func deferNight(notice:String){deferrals+=1}
 func begin(_ request:ProcessingRequest){begins+=1}
 func releaseSystemActivity(){}
 func releaseAwake()async{}
 static func composed(_ a:RunProgress,_ b:RunProgress)->RunProgress{RunProgress(done:a.done+b.done)}
 // METHODS
}
@main struct Main {
 @MainActor static func main()async throws {
  let suite="sentient-initial-resume-"+UUID().uuidString
  let d=UserDefaults(suiteName:suite)!;defer{d.removePersistentDomain(forName:suite)}
  var count=0
  func check(_ value:Bool,_ name:String){precondition(value,name);count+=1}
  let c=Coordinator(defaults:d)
  check(ProcessingPlan.recovered(.init(status:.requested),initialComplete:false).status == .paused,
        "Queued first analysis also waits for explicit resume after quit")
  c.record = .init(status:.failed,trigger:.onboarding)
  await c.runScheduled()
  check(c.begins==1 && c.record.status == .requested && c.record.trigger == .overnight,
        "Scheduler can recover a failed first analysis")
  await c.runScheduled();check(c.begins==1,"Scheduler cannot duplicate already requested analysis")
  c.begins=0
  c.record = .init(status:.running,trigger:.onboarding);c.isBusy=true;c.pause()
  check(c.state == .stopping && ProcessingPlan.read(d).status == .paused,"Pause persists before worker drains")
  let recovered=ProcessingPlan.recovered(ProcessingPlan.read(d),initialComplete:false)
  check(recovered.status == .paused,"A quit during pause cannot resurrect analysis")
  c.finishStopped(RunProgress(done:9));c.isBusy=false
  await c.runScheduled();check(c.begins==0 && c.record.status == .paused,"Scheduler leaves explicit pause alone")
  check(c.requestNow() && c.record.status == .requested && c.carried.done==9 && c.checks==1,
        "Only explicit resume admits work while retaining saved device progress")
  c.record = .init(status:.running,trigger:.overnight);c.isBusy=true;c.stopReason=nil;c.stop(.cancelled)
  check(ProcessingPlan.read(d).status == .paused,"Cancelled initial work persists paused immediately")
  c.finishStopped(.init());c.isBusy=false
  check(c.record.status == .paused,"Legacy overnight ownership cannot reschedule first analysis")
  c.initialComplete=true;c.record = .init(status:.paused,trigger:.overnight)
  await c.runScheduled();check(c.begins==0,"Nightly updates also respect explicit pause")
  c.record = .init(status:.completed);await c.runScheduled()
  check(c.begins==1,"Nightly updates still run after first analysis completes")
  c.initialComplete=false;c.stopReason=nil
  _ = await c.execute(.init(),scheduled:false,id:c.runID,report:{_ in})
  c.initialComplete=true
  _ = await c.execute(.init(),scheduled:false,id:c.runID,report:{_ in})
  c.initialComplete=false
  _ = await c.execute(.init(readySelectionCount:nil),scheduled:false,id:c.runID,report:{_ in})
  check(ProcessingRun.scopes == [true,false,false],"Cloud replay scope applies only to production initial creation")
  check(!InitialAnalysisRecovery.replayCloudStages,"Replay policy never leaks outside the owned run")
  print("PASS \(count) initial analysis pause, scheduling and task-scope checks")
 }
}
'''
fixture=fixture.replace('// METHODS','\n'.join(method(x) for x in [
 'enum State:', 'enum Wait:', 'private enum Stop', 'func requestNow(', 'func pause()',
 'func runScheduled()', 'private func execute(', 'private func stop(', 'private func finishStopped(']))
with tempfile.TemporaryDirectory(prefix='sentient-initial-analysis-') as tmp:
 p=Path(tmp);(p/'Main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5',str(p/'Main.swift'),
  str(APP/'Ingestion/ProcessingPlan.swift'),str(APP/'Ingestion/InitialAnalysisRecovery.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=15)
