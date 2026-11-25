#!/usr/bin/env python3
"""Compile production wake diagnostics/client/history with inert XPC, service queries and sinks.
No daemon registration, power changes, application startup or telemetry uploads occur.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'
SUPPORT = r'''
import Foundation
import Synchronization
import ServiceManagement
nonisolated enum FixtureDefaults {
    static let name = "wake-diagnostics-" + UUID().uuidString
    static var history: UserDefaults { UserDefaults(suiteName: name)! }
}
nonisolated func Log(_ text: String) {}
nonisolated func ErrorLabel(_ error: Error) -> String { "synthetic_error" }
nonisolated enum NativeComputerUseFailure { enum Detail: String { case fixture } }
nonisolated enum CodexTrigger: String, Sendable {
    case overnight, pluggedInIdle = "plugged_in_idle", unknown
    @TaskLocal static var current: Self = .unknown
}
nonisolated enum WakeHelperMaintenance {
    static let supportPath = "/nonexistent-wake-fixture"
    static let logPath = "/nonexistent-wake-fixture/log"
}
nonisolated enum WakeHelperConfig {
    static let daemonPlistName = "fixture.invalid.plist"
    static let machServiceName = "fixture.invalid"
    static let legacyPlistPath = "/nonexistent-wake-fixture/legacy"
}
@MainActor final class PermissionGuide {
    enum Pane { case overnightWake }
    static let shared = PermissionGuide()
    func guide(_ pane: Pane, dragging: String?) { fatalError("unexpected approval UI") }
}
nonisolated enum Diagnostics {
    enum Event: String { case wakeFailed = "wake.operation_failed", serviceFailed = "service.operation_failed" }
    enum Phase: String, Sendable { case begin, arm, restore, heartbeat, cancel, probe, setup, remove }
    enum Count: String { case deadlineMS = "deadline_ms" }
    struct Payload: Sendable { let event: String; let tags: [String:String]; let extra: [String:String]; let fingerprint: [String] }
    final class Operation: Sendable {}
    @TaskLocal static var current: Operation?
    // The unchanged general diagnostics sanitizer is an inert, closed-field collaborator here.
    static func payload(_ event: Event, phase: Phase, reason: StaticString, error: Error? = nil,
                        source: String? = nil) -> Payload {
        var tags = ["phase":phase.rawValue, "reason":reason.description, "source":source ?? "app"]
        if let error { let ns=error as NSError; tags["error_code"]=String(ns.code); tags["error_domain"]=ns.domain }
        return Payload(event:event.rawValue,tags:tags,extra:[:],fingerprint:[event.rawValue,phase.rawValue])
    }
    static func report(_ event: Event, phase: Phase, reason: StaticString = "unexpected", error: Error? = nil,
                       source: String? = nil, counts: [Count:Int] = [:]) {
        Fixture.records.withLock { $0.operational += 1 }
    }
}
nonisolated enum CrashReporting {
    static let diagnosticsEnabled = false
    static let installID = "00000000-0000-4000-8000-000000000001"
    static func scrub(text: String) -> String { text }
    static func diagnosticBreadcrumb(_ name: String, data: [String:String]) {
        Fixture.records.withLock { $0.breadcrumbs.append(name) }
    }
    static func captureEvent(_ event: String, tags: [String:String], extra: [String:String],
                             fingerprint: [String], affectsOperation: Bool) {
        precondition(!affectsOperation, "observation cannot change recovered work")
        Fixture.records.withLock { $0.reports.append(.init(event:event,tags:tags,extra:extra,fingerprint:fingerprint)) }
    }
}
nonisolated enum Fixture {
    struct Records: Sendable { var reports:[Diagnostics.Payload]=[];var operational=0;var breadcrumbs:[String]=[] }
    static let records=Mutex(Records())
    enum Mode: Sendable {case error,reply(Bool),pending,noProxy}
    nonisolated(unsafe) static var mode=Mode.error
    nonisolated(unsafe) static var connections:[StubConnection]=[]
    nonisolated(unsafe) static var pending:[(Bool)->Void]=[]
}
nonisolated enum FixtureService {
    struct State: Sendable { var status: Int?=SMAppService.Status.requiresApproval.rawValue;var block=false;var calls=0 }
    static let state=Mutex(State())
    static let gate=DispatchSemaphore(value:0)
    static func operational(_ action: ServiceRegistration.Action)->ServiceRegistration.Result {
        precondition(!Thread.isMainThread)
        return .init(rawStatus:state.withLock{$0.status})
    }
    static func execute(_ action: ServiceRegistration.Action)->ServiceRegistration.Result {
        precondition(!Thread.isMainThread)
        precondition(action == .status, "diagnostics must never register or unregister")
        let input=state.withLock { $0.calls+=1;return ($0.status,$0.block) }
        if input.1 {gate.wait()}
        return .init(rawStatus:input.0)
    }
}
nonisolated protocol WakeHelperProtocol {
    func prepare(withReply: @escaping(Bool)->Void)
    func cancelRemoval(withReply: @escaping(Bool)->Void)
    func prepareForRemoval(withReply: @escaping(Bool)->Void)
    func beginAwake(timeoutSeconds:Int,withReply: @escaping(Bool)->Void)
    func heartbeat(withReply: @escaping(Bool)->Void)
    func endAwake(withReply: @escaping(Bool)->Void)
    func armWake(atEpoch:Double,withReply: @escaping(Bool)->Void)
    func cancelWake(withReply: @escaping(Bool)->Void)
    func cancelAllWakes(withReply: @escaping(Bool)->Void)
    func configureDiagnostics(enabled:Bool,anonymousID:String,withReply: @escaping()->Void)
}
nonisolated final class StubInterface: @unchecked Sendable {init(with:Any.Type){}}
nonisolated final class StubConnection: @unchecked Sendable {
    enum Options {case privileged}
    var remoteObjectInterface:StubInterface?
    var interruptionHandler:(()->Void)?,invalidationHandler:(()->Void)?
    init(machServiceName:String,options:Options){Fixture.connections.append(self)}
    func resume(){}
    func invalidate(){invalidationHandler?()}
    func remoteObjectProxyWithErrorHandler(_ handler:@escaping(Error)->Void)->Any {
        if case .noProxy=Fixture.mode{return "synthetic missing proxy"}
        return Proxy(error:handler)
    }
}
nonisolated final class Proxy: WakeHelperProtocol {
    let error:(Error)->Void
    init(error:@escaping(Error)->Void){self.error=error}
    func deliver(_ reply:@escaping(Bool)->Void){
        switch Fixture.mode {
        case .error:error(NSError(domain:NSCocoaErrorDomain,code:4099,userInfo:[NSLocalizedDescriptionKey:"SECRET /Users/PrivateName/account@example.test"]))
        case .reply(let value):reply(value)
        case .pending:Fixture.pending.append(reply)
        case .noProxy:fatalError()
        }
    }
    func prepare(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func cancelRemoval(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func prepareForRemoval(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func beginAwake(timeoutSeconds:Int,withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func heartbeat(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func endAwake(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func armWake(atEpoch:Double,withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func cancelWake(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func cancelAllWakes(withReply reply:@escaping(Bool)->Void){deliver(reply)}
    func configureDiagnostics(enabled:Bool,anonymousID:String,withReply reply:@escaping()->Void){reply()}
}
'''
TESTS = r'''
import Foundation
import ServiceManagement
@main @MainActor struct Tests {
 static var checks=0
 static func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1}
 static func until(_ ready:()->Bool) async throws {
  for _ in 0..<1000 {if ready(){return};try await Task.sleep(for:.milliseconds(2))};fatalError("fixture timeout")
 }
 static var reports:[Diagnostics.Payload]{Fixture.records.withLock{$0.reports}}
 static func main() async throws {
  defer{UserDefaults.standard.removePersistentDomain(forName:FixtureDefaults.name)}
  for (raw,expected) in [(0,"not_registered"),(1,"enabled"),(2,"requires_approval"),(3,"not_found"),(99,"unknown")] {
   check(WakeHelperDiagnostics.Registration(rawStatus:raw).rawValue==expected,"status categorization")
  }
  check(WakeHelperDiagnostics.Registration(rawStatus:nil) == .unknown,"unknown is not notFound")
  let home=URL(fileURLWithPath:"/Users/PrivateName")
  for (path,expected) in [("/Applications/Sentient.app","applications"),("/Users/PrivateName/Applications/Sentient.app","user_applications"),("/private/random/AppTranslocation/secret/Sentient.app","translocated"),("/Volumes/PrivateDisk/Sentient.app","volume"),("/Users/PrivateName/Downloads/Sentient.app","other")] {
   check(WakeHelperDiagnostics.Location(bundleURL:URL(fileURLWithPath:path),homeURL:home).rawValue==expected,"closed location category")
  }
  var state=WakeHelperDiagnostics.State()
  check(state.claim(.begin,failure:.xpcError,now:100),"first observation")
  check(!state.claim(.begin,failure:.xpcError,now:2000),"pending observation cannot pile up after interval")
  state.finish(.begin,failure:.xpcError)
  check(!state.claim(.begin,failure:.xpcError,now:999),"fifteen minute bound")
  check(state.claim(.begin,failure:.xpcError,now:1000),"exact retry boundary")
  check(state.claim(.begin,failure:.timeout,now:1000),"a different failure remains observable")
  check(!state.claim(.arm,failure:.timeout,now:.nan),"invalid clocks rejected")
  check(state.recordReply(at:100),"first reply")
  check(!state.recordReply(at:50),"late old reply does not reset last contact")
  check(state.snapshot(at:101).lastReplyAgeMS==1000,"reply age preserved")
  state.interrupted();state.invalidated()
  check(state.snapshot(at:101).interruptions==1 && state.snapshot(at:101).invalidations==1,"connection lifecycle")
  check(WakeHelperDiagnostics.milliseconds(.infinity)==0 && WakeHelperDiagnostics.milliseconds(-1)==0,"bounded invalid duration")

  let client=WakeHelperClient()
  let first=await CodexTrigger.$current.withValue(.pluggedInIdle){await client.beginAwake()}
  check(!first,"original failure result")
  try await until{reports.count==1}
  check(reports[0].tags["wake_registration_before"]=="unknown","before-call evidence")
  check(reports[0].tags["wake_registration_observed"]=="requires_approval","fresh approval evidence")
  check(reports[0].tags["wake_trigger"]=="plugged_in_idle","trigger survives callback hop")
  check(reports[0].extra["wake_helper_replied_this_process"]=="false","no fabricated contact")
  let serialized=String(describing:reports[0].tags)+String(describing:reports[0].extra)
  check(!serialized.contains("SECRET") && !serialized.contains("PrivateName") && !serialized.contains("account@"),"no raw error content")
  let queries=FixtureService.state.withLock{$0.calls}
  for _ in 0..<50 {_ = await client.beginAwake()}
  try await Task.sleep(for:.milliseconds(15))
  check(reports.count==1 && FixtureService.state.withLock{$0.calls}==queries,"repeated failures do not query or record again")

  check(await client.healthProbe() == .requiresApproval,"ordinary health read retains approval state")
  FixtureService.state.withLock{$0.status=SMAppService.Status.enabled.rawValue}
  _ = await client.armWake(at:Date())
  try await until{reports.count==2}
  check(reports[1].tags["wake_registration_before"]=="requires_approval" && reports[1].tags["wake_registration_observed"]=="enabled","fresh state distinguished from earlier cached state")
  check(reports[1].extra["wake_connection_reused"]=="true","reused connection captured")
  let old=Fixture.connections.last!;old.interruptionHandler?();old.invalidationHandler?()
  try await Task.sleep(for:.milliseconds(10))
  Fixture.mode = .reply(false)
  _ = await client.heartbeat()
  try await until{reports.count==3}
  check(reports[2].tags["reason"]=="helper_rejected" && reports[2].extra["wake_helper_replied_this_process"]=="true","negative response proves contact only")
  check(reports[2].extra["wake_connection_reused"]=="false" && reports[2].extra["wake_connection_generation"]=="2","new connection after invalidation")
  check(reports[2].extra["wake_interruptions_seen"]=="1" && reports[2].extra["wake_invalidations_seen"]=="1","lifecycle included")

  // A blocked OS query must not delay the already-failed helper call or queue mutations.
  Fixture.mode = .error;FixtureService.state.withLock{$0.block=true}
  let blocked=WakeHelperClient(),beforeBlockedQuery=FixtureService.state.withLock{$0.calls}
  check(!(await blocked.endAwake()),"failed cleanup returns")
  try await until{FixtureService.state.withLock{$0.calls}>beforeBlockedQuery}
  check(await blocked.register() == .enabled,"blocked diagnostic query cannot occupy the setup worker")
  try await until{reports.count==4}
  check(reports[3].tags["wake_registration_observed"]=="unknown","timed-out observation remains unknown")
  FixtureService.state.withLock{$0.block=false};FixtureService.gate.signal()
  try await Task.sleep(for:.milliseconds(10))

  Fixture.mode = .pending
  let late=WakeHelperClient(),count=reports.count
  check(!(await late.beginAwake()),"timeout preserves false result")
  try await until{reports.count==count+1}
  check(reports.last?.tags["reason"]=="xpc_timeout","timeout classified")
  let callback=Fixture.pending.removeFirst();callback(true)
  try await Task.sleep(for:.milliseconds(10))
  check(reports.count==count+1,"late reply cannot create a second failed outcome")
  Fixture.mode = .error;_ = await late.cancelWake()
  try await until{reports.count==count+2}
  check(reports.last?.extra["wake_helper_replied_this_process"]=="true","late response retained as contact evidence")

  Fixture.mode = .noProxy
  let missing=WakeHelperClient();check(!(await missing.beginAwake()),"missing proxy returns false")
  try await until{reports.count==count+3}
  check(reports.last?.tags["reason"]=="proxy_unavailable","missing proxy explained")
  Fixture.mode = .error
  let quiet=WakeHelperClient(),beforeQuiet=reports.count,operational=Fixture.records.withLock{$0.operational}
  check(await quiet.healthProbe() == .unavailable,"enabled but unreachable stays unavailable")
  try await until{reports.count==beforeQuiet+1}
  check(reports.last?.tags["phase"]=="probe" && reports.last?.tags["wake_registration_observed"]=="enabled","quiet readiness failures retain useful evidence")
  check(Fixture.records.withLock{$0.operational}==operational,"quiet probe does not acquire operational failure side effects")
  let local=try DiagnosticHistory.snapshot(defaults:FixtureDefaults.history)
  check(local.errors.count==reports.count,"local report retains each bounded observation")
  check(local.errors.first?.fields["wake_registration_observed"]=="requires_approval","categorical fields survive export allow-list")
  check(local.errors.first?.fields["wake_helper_replied_this_process"]=="false","boolean evidence survives export")
  print("PASS \(checks) wake-helper diagnostics checks; all XPC, registration and upload I/O inert")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-wake-diagnostics-') as directory:
    root = Path(directory)
    client = (APP / 'Scheduling/WakeHelperClient.swift').read_text()
    client = client.replace('NSXPCConnection', 'StubConnection').replace('NSXPCInterface', 'StubInterface')
    client = client.replace('private let registration = ServiceRegistration(kind: .wakeHelper)', 'private let registration = ServiceRegistration(kind: .wakeHelper, timeout: 0.05, execute: FixtureService.operational)')
    client = client.replace('private let diagnosticRegistration = ServiceRegistration(kind: .wakeHelper)', 'private let diagnosticRegistration = ServiceRegistration(kind: .wakeHelper, timeout: 0.05, execute: FixtureService.execute)')
    client = client.replace('.now() + 30', '.now() + 0.06')  # Only the simulated transport deadline is accelerated.
    (root / 'Client.swift').write_text(client)
    history = (APP / 'Diagnostics/DiagnosticHistory.swift').read_text().replace('UserDefaults = .standard', 'UserDefaults = FixtureDefaults.history')
    (root / 'History.swift').write_text(history)
    (root / 'Support.swift').write_text(SUPPORT)
    (root / 'Tests.swift').write_text(TESTS)
    binary = root / 'tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    str(APP / 'Diagnostics/WakeHelperDiagnostics.swift'), str(APP / 'Scheduling/ServiceRegistration.swift'),
                    str(root / 'Client.swift'), str(root / 'History.swift'), str(root / 'Support.swift'), str(root / 'Tests.swift'),
                    '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary)], check=True, timeout=30)
