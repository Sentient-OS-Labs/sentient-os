#!/usr/bin/env python3
"""Production Doctor-to-readiness handoff with inert helper, windows and native transport.
Exercises proof ownership, repair, cancellation and broker isolation without opening apps.
"""
from pathlib import Path
import ast, platform, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'Sentient OS macOS'
temporary = tempfile.TemporaryDirectory(prefix='sentient-doctor-readiness-')
OUT=Path(temporary.name)
def literal(script,name):
 t=ast.parse((ROOT/'Scripts'/script).read_text())
 for n in t.body:
  if isinstance(n,ast.Assign) and any(isinstance(x,ast.Name) and x.id==name for x in n.targets):return ast.literal_eval(n.value)
cache=(APP/'Views/Permissions/NativePermissionCheck.swift').read_text().split('@MainActor private final class NativePermissionCheckWindow')[0].replace('import AppKit','import Foundation')
doctor=(APP/'Diagnostics/ComputerUseDoctor.swift').read_text()
presentation=doctor[doctor.index('    func start()'):doctor.index('        if window == nil {')] + '        presentations += 1\n    }\n'
run=doctor[doctor.index('    private func run('):doctor.index('    private func recordInfrastructureError(')].replace('private func run','func run')
uninstall=(APP/'System/Uninstall.swift').read_text()
uninstall_scope=uninstall[uninstall.index('        await ComputerUseGate.shared.beginTeardown()'):uninstall.index('        let processing =',uninstall.index('        await ComputerUseGate.shared.beginTeardown()'))]
probe_fixture=literal('test_computer_use_diagnostics.py','tests')
surface=probe_fixture[probe_fixture.index('@MainActor final class Surface'):probe_fixture.index('final class MockHTTP')]
support=r'''
import Foundation
import ImageIO
import UniformTypeIdentifiers
nonisolated enum ModelBackend {case fixture;static var current:Self{.fixture}}
@MainActor enum Analytics {
 static var signals: [(String, [String:String])] = []
 static func signal(_ name:String, parameters:[String:String]) { signals.append((name,parameters)) }
}
@MainActor final class ComputerUseGate {
 static let shared=ComputerUseGate()
 var active=false
 func beginTeardown() async {active=true}
 func endTeardown(){active=false}
}
nonisolated enum CodexRuntime {
 struct Release { let helperBuild:Int }
 static let release=Release(helperBuild:1)
 class FileLock { func unlock() {} }
 enum Failure: Error { case invalidPackage,busy }
 static func sharedRuntimeLease() async throws -> FileLock { .init() }
}
@MainActor final class NSRunningApplication {
 var isTerminated=false
 let processIdentifier:Int32
 init(_ pid:Int32=1){processIdentifier=pid}
 let bundleURL:URL?=OpenAIComputerUse.appURL
}
@MainActor final class NSWindow {}
@MainActor final class OpenAIComputerUseRuntime {
 static let shared=OpenAIComputerUseRuntime()
 var helper=NSRunningApplication()
 var busy=false, restarts=0
 func reserveDiagnostic() -> UUID? { if busy { return nil }; busy=true; return UUID() }
 func endDiagnostic(_ id:UUID) { busy=false }
 func start(configuration:OpenAIComputerUse.Configuration,stoppingConflictingHelpers:Bool=false) async throws -> NSRunningApplication {helper}
 func restart(configuration:OpenAIComputerUse.Configuration) async throws {restarts+=1;helper.isTerminated=true;helper=NSRunningApplication(helper.processIdentifier+1)}
 func prepareForReinstall(configuration:OpenAIComputerUse.Configuration) async throws {}
}
nonisolated enum OpenAIComputerUse {
 enum RuntimeError:Error {case helperRunning,invalidSignature,incomplete,changedInstallation,permissionRequired,backendUnavailable}
 static let appURL=URL(fileURLWithPath:"/fixture-helper.app")
 static let bundleID="fixture.helper"
 static func validate(at:URL) async throws -> Bool {true}
 static func installation(at:URL) -> Bool? {true}
 struct Configuration:Equatable,Sendable {
  var appURL:URL {OpenAIComputerUse.appURL}
  func afterRuntimeLease() throws -> Self {self}
  static func resolveForSetup() async throws -> Self {.init()}
 }
}
@MainActor final class ComputerUseSetup {
 enum Kind {case openAI}
 static func instance(for kind:Kind) -> ComputerUseSetup {.init()}
 var failure: Error? {nil}
 func ensureInstalled(force:Bool=false) async -> Bool {true}
}
nonisolated enum Permissions {
 enum State:String {case granted}
 static func nativeAutomationState(ask:Bool) async -> State {.granted}
 static func hasScreenRecording() -> Bool {true}
 static func tccState(service:String,clientBundleID:String) -> State {.granted}
}
@MainActor final class ComputerUseTestControls {
 struct View {var window:NSWindow?}
 var view=View()
 let surface=Surface()
 func target(window:NSWindow) -> ComputerUseCheckProbe.Target {surface.target}
 func reset() {}
}
@MainActor final class NativePermissionCheckWindow {
 static var shown=0
 static var isPresenting=false
 static var currentMarker=""
 let marker=UUID().uuidString
 var isCurrent:Bool {true}
 func show(){Self.shown+=1;Self.currentMarker=marker;Self.isPresenting=true}
 func close(){Self.isPresenting=false}
 func waitUntilCurrent() async throws {try Task.checkCancellation()}
}
actor OpenAIComputerUseSession {
 @MainActor static var sessions:[OpenAIComputerUseSession]=[]
 @MainActor static var surface:Surface?
 @MainActor static var pendingFailures:[NativeComputerUseFailure]=[]
 @MainActor static var delayCalls=false
 @MainActor static var replaceHelperOnOpen=false
 @MainActor static var replaceHelperAfterProbe=false
 var usable=true
 var calls=0
 static func open(_ config:OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession {
  let s=OpenAIComputerUseSession()
  await MainActor.run {
   if replaceHelperOnOpen {
    replaceHelperOnOpen=false
    let prior=OpenAIComputerUseRuntime.shared.helper;prior.isTerminated=true
    OpenAIComputerUseRuntime.shared.helper=NSRunningApplication(prior.processIdentifier+1)
   }
   sessions.append(s)
  };return s
 }
 func call(_ tool:String,arguments:Data,timeout:TimeInterval=12) async throws -> Data {
  calls+=1
  while await Self.delayCalls {try await Task.sleep(for:.milliseconds(10))}
  if let failure=await MainActor.run(body:{Self.pendingFailures.isEmpty ? nil : Self.pendingFailures.removeFirst()}) {throw failure}
  if let surface=await Self.surface, (try JSONSerialization.jsonObject(with:arguments) as? [String:Any])?["app"] as? String == "/fixture.app" {
   let result=try await surface.call(tool,arguments)
   await MainActor.run {
    if Self.replaceHelperAfterProbe && surface.reads == 5 {
     Self.replaceHelperAfterProbe=false
     let prior=OpenAIComputerUseRuntime.shared.helper;prior.isTerminated=true
     OpenAIComputerUseRuntime.shared.helper=NSRunningApplication(prior.processIdentifier+1)
    }
   }
   return result
  }
  let marker=await NativePermissionCheckWindow.currentMarker
  let image=await Surface().image
  return try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":marker],["type":"image","data":image]]])
 }
 func isUsable()->Bool{usable}
 func close(){usable=false}
}
nonisolated struct CaptureDiagnostics {
 enum Source{case healthProbe};enum Outcome{case passed,failed,cancelled}
 init(source:Source){}
 static func environment() async->[String:String]{[:]}
 func record(_ outcome:Outcome,failure:NativeComputerUseFailure?=nil,fields:[String:String]){}
}
'''
wrapper=r'''
@MainActor final class FixtureDoctor {
 var report:ComputerUseCheckReport? = .init(source:.settings,environment:.init(appVersion:"fixture",appBuild:"0",binaryID:UUID().uuidString,macOS:"fixture",backend:"fixture",helperVersion:"fixture",helperBuild:0,cliVersion:"fixture"))
 var window:NSWindow?=NSWindow()
 var isRunning=true, ownsCheckSurface=false, presentations=0, begins=0
 var controls:ComputerUseTestControls?=ComputerUseTestControls()
 init(){controls?.view.window=window}
 func begin(source:ComputerUseCheckReport.Source,backend:ModelBackend,call:ComputerUseCheckProbe.Call?){begins += 1 }
 func recordInfrastructureError(_ error:Error,at:ComputerUseCheckReport.Check){report?.update(at,.needsAttention)}
'''+presentation+run+'\n}\n'
tests=r'''
@main struct Test {
 @MainActor static var count=0
 @MainActor static func check(_ condition:Bool,_ message:String){precondition(condition,message);count+=1}
 @MainActor static func prepared() -> FixtureDoctor {
  let doctor=FixtureDoctor()
  OpenAIComputerUseSession.surface=doctor.controls!.surface
  return doctor
 }
 @MainActor static func main() async throws {
  let cache=NativePermissionCheck.shared
  let runtime=OpenAIComputerUseRuntime.shared
  let doctor=prepared()
  await doctor.run(source:.settings,agentCall:nil)
  check(doctor.report!.outcome == .passed,"Actual full Settings check passes")
  check(doctor.controls!.surface.reads == 5 && doctor.controls!.surface.clicks == 1 && doctor.controls!.surface.edits == 1,"Strict evidence comes from five real probe reads and verified fixture actions")
  check(cache.snapshot.isReady,"Settings success publishes admission proof")
  check(NativePermissionCheckWindow.shown == 0,"No second permission window")
  let retained=OpenAIComputerUseSession.sessions.last!
  check(await retained.isUsable(),"Verified Settings connection transferred alive")
  await cache.refresh(configuration:.init(),helper:runtime.helper)
  check(cache.snapshot.isReady,"Passive scoped refresh reuses Doctor proof")
  let sessions=OpenAIComputerUseSession.sessions.count
  try await cache.check(configuration:.init(),helper:runtime.helper)
  check(OpenAIComputerUseSession.sessions.count == sessions,"Next gate joins proof without another connection")

  let interrupted=prepared();interrupted.controls!.surface.wrongWindow=true
  await interrupted.run(source:.settings,agentCall:nil)
  check(interrupted.report!.outcome == .interrupted,"Missing marker remains an interruption")
  check(cache.snapshot.isReady && await retained.isUsable(),"Interrupted nonrepair diagnostic preserves committed proof")
  check(await OpenAIComputerUseSession.sessions.last!.isUsable() == false,"Failed candidate closes")

  let cancelled=prepared();OpenAIComputerUseSession.delayCalls=true
  let cancelling=Task{await cancelled.run(source:.settings,agentCall:nil)}
  try await Task.sleep(for:.milliseconds(100));cancelling.cancel();await cancelling.value
  OpenAIComputerUseSession.delayCalls=false
  check(cancelled.report!.outcome == .cancelled,"Owning cancellation stops Settings probe")
  check(cache.snapshot.isReady && await retained.isUsable(),"Cancellation keeps previous usable proof")

  let denied=prepared()
  OpenAIComputerUseSession.pendingFailures=[.init(kind:.permission,code:-3801,detail:.permissionDenied,stage:.probe,systemDomain:"SCStreamErrorDomain",systemCode:-3801)]
  await denied.run(source:.settings,agentCall:nil)
  check(denied.report!.outcome == .permissionsNeeded,"Native denial is not cancelled or repaired")
  check(!cache.snapshot.isReady && cache.snapshot.screenRecording == .denied,"Native denial invalidates old proof")
  await cache.close()
  check(await retained.isUsable() == false,"Revoked proof closes")

  let repairing=prepared()
  OpenAIComputerUseSession.pendingFailures=[.init(kind:.connection,code:nil,detail:.disconnected,stage:.transport)]
  let prior=runtime.helper
  let repairTask=Task{await repairing.run(source:.settings,agentCall:nil)}
  try await Task.sleep(for:.milliseconds(50))
  let waitingGate=Task{try await cache.check(configuration:.init(),helper:prior)}
  await repairTask.value;try await waitingGate.value
  check(NativePermissionCheckWindow.shown == 0,"Gate joining repair reuses proof from replacement helper")
  check(repairing.report!.outcome == .repaired && repairing.report!.repairVerified,"One real retry verifies repair")
  check(runtime.restarts == 1 && prior.isTerminated,"Repair replaces old helper")
  await cache.refresh(configuration:.init(),helper:runtime.helper)
  check(cache.snapshot.isReady,"Repair handoff binds new helper handle")
  await cache.close()

  let replaced=prepared()
  let beforeOpen=runtime.helper
  OpenAIComputerUseSession.replaceHelperOnOpen=true
  await replaced.run(source:.settings,agentCall:nil)
  check(beforeOpen.isTerminated && replaced.report!.outcome == .passed,"Settings binds helper replaced while opening client")
  await cache.refresh(configuration:.init(),helper:runtime.helper)
  check(cache.snapshot.isReady,"Post-open helper identity retained")
  await cache.close()

  let changedDuringProbe=prepared();OpenAIComputerUseSession.replaceHelperAfterProbe=true
  await changedDuringProbe.run(source:.settings,agentCall:nil)
  check(changedDuringProbe.report!.outcome == .needsAttention && !cache.snapshot.isReady,"Helper replacement during proof cannot be adopted")
  check(await OpenAIComputerUseSession.sessions.last!.isUsable() == false,"Rejected replacement closes candidate session")

  let shared=prepared();OpenAIComputerUseSession.delayCalls=true
  let settingsOwner=Task{await shared.run(source:.settings,agentCall:nil)}
  try await Task.sleep(for:.milliseconds(50))
  let observer=Task{try await cache.check(configuration:.init(),helper:runtime.helper)}
  try await Task.sleep(for:.milliseconds(25));observer.cancel()
  do {try await observer.value;preconditionFailure("Cancelled observer continued")}catch is CancellationError{count+=1}
  OpenAIComputerUseSession.delayCalls=false;await settingsOwner.value
  check(shared.report!.outcome == .passed && cache.snapshot.isReady,"Cancelling gate observer preserves Settings owner")
  await cache.close()

  let agent=prepared()
  let ownedBefore=OpenAIComputerUseSession.sessions.count
  await agent.run(source:.agent,agentCall:{name,data in try await agent.controls!.surface.call(name,data)})
  check(agent.report!.outcome == .passed,"Borrowed agent probe passes")
  check(!cache.snapshot.isReady && OpenAIComputerUseSession.sessions.count == ownedBefore,"Agent diagnostic neither creates nor adopts a global session")

  let queued=prepared();OpenAIComputerUseSession.delayCalls=true
  let normal=Task{try await cache.check(configuration:.init(),helper:runtime.helper)}
  while !NativePermissionCheckWindow.isPresenting {try await Task.sleep(for:.milliseconds(5))}
  let queuedCheck=Task{await queued.run(source:.settings,agentCall:nil)}
  try await Task.sleep(for:.milliseconds(25))
  queued.start();queued.show();queued.start()
  check(queued.presentations == 0,"Repeated Start/View cannot present queued Doctor over normal proof")
  let oldReport=FixtureDoctor();oldReport.isRunning=false;oldReport.show()
  check(oldReport.presentations == 0,"Completed report cannot displace ordinary proof")
  OpenAIComputerUseSession.delayCalls=false
  try await normal.value;await queuedCheck.value
  check(queued.report!.outcome == .passed && queued.presentations == 1,"Admitted Doctor presents once after ordinary probe closes")
  oldReport.show()
  check(oldReport.presentations == 1,"Completed report remains available when no proof window is active")
  await cache.close()

  let ending=prepared();OpenAIComputerUseSession.delayCalls=true
  let inFlight=Task{await ending.run(source:.settings,agentCall:nil)}
  try await Task.sleep(for:.milliseconds(100));await cache.close();await inFlight.value
  OpenAIComputerUseSession.delayCalls=false
  check(ending.report!.outcome == .cancelled && !cache.snapshot.isReady,"Teardown drains active Settings owner without late proof")
  await cache.beginTeardown()
  let newStart=prepared();newStart.isRunning=false;newStart.start();newStart.show()
  check(newStart.begins == 0 && newStart.presentations == 0,"Teardown blocks begin/report producer and completed report presentation")
  let beforeBlocked=OpenAIComputerUseSession.sessions.count
  let blocked=prepared();await blocked.run(source:.settings,agentCall:nil)
  check(blocked.report!.outcome == .cancelled && blocked.presentations == 0,"Settings producer is blocked throughout teardown scope")
  do {try await cache.check(configuration:.init(),helper:runtime.helper);preconditionFailure("Teardown admitted readiness")}catch is CancellationError{count+=1}
  check(OpenAIComputerUseSession.sessions.count == beforeBlocked && !cache.snapshot.isReady,"Held barrier opens no clients or proof")
  cache.endTeardown()
  let afterTeardown=prepared();await afterTeardown.run(source:.settings,agentCall:nil)
  check(afterTeardown.report!.outcome == .passed && cache.snapshot.isReady,"Admission resumes after teardown ends")
  await cache.close()
  await uninstallScope(completed:false)
  check(!cache.isTearingDown && !ComputerUseGate.shared.active,"Uninstall cancellation/failure releases production admission defers")
  await uninstallScope(completed:true)
  check(cache.isTearingDown && ComputerUseGate.shared.active,"Successful uninstall retains both barriers while completion UI survives")
  let afterUninstall=prepared();afterUninstall.isRunning=false;afterUninstall.start()
  check(afterUninstall.begins == 0,"Completed uninstall cannot restart Doctor before user quits")
  cache.endTeardown();ComputerUseGate.shared.endTeardown()
  print("PASS \(count) Doctor/readiness handoff checks with production owners and validators")
 }
}
'''
# Execute the production uninstall admission/defer block with inert collaborators.
tests=tests.replace(' @MainActor static func main()', ' @MainActor static func uninstallScope(completed:Bool) async {\n  var completedTeardown=false\n'+uninstall_scope+'\n  completedTeardown=completed\n }\n @MainActor static func main()')
# Await actor values before Boolean autoclosures.
tests=tests.replace('check(cache.snapshot.isReady && await retained.isUsable(),','check(await retained.isUsable() && cache.snapshot.isReady,')
for n,s in [('Support',support),('Surface',surface),('Cache',cache),('Doctor',wrapper),('Test',tests)]: (OUT/(n+'.swift')).write_text('import Foundation\nimport ImageIO\nimport UniformTypeIdentifiers\n'+s)
files=[str(OUT/(n+'.swift')) for n in ['Support','Surface','Cache','Doctor','Test']]+[str(APP/n) for n in ['Diagnostics/NativeComputerUseFailure.swift','Diagnostics/ComputerUseCheckReport.swift','Diagnostics/ComputerUseCheckProbe.swift','Driver/NativePermissionReadiness.swift','Driver/OpenAIComputerUseProbe.swift']]
subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',*files,'-o',str(OUT/'test')],check=True,timeout=60)
subprocess.run([str(OUT/'test')],check=True,timeout=30)
temporary.cleanup()
