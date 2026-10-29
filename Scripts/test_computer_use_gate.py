#!/usr/bin/env python3
"""Real gate admission/held-intent logic, with inert permission peers and window lifecycle.
All defaults, permission APIs, native sessions, app state and UI are replaced by fixture peers.
"""
from pathlib import Path
import platform
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'Views/Permissions/ComputerUseGate.swift').read_text()
source=source[:source.index('    // MARK: Window lifecycle')]
for module in ['AppKit','AVFoundation','Speech','SwiftUI']: source=source.replace('import '+module,'')
source='import Foundation\nimport Observation\n'+source+r'''
    private func present() { if window == nil { window=NSWindow() }; presentations += 1 }
    private func dismissWindow() { windowClosed() }
    private func windowClosed() {
        permissionRequest?.cancel(); cancelPendingAction(); window=nil; showingVoiceRepair=false
    }
    var presentations=0
    var visible: Bool { window != nil }
    func fixtureClose() { windowClosed() }
    func fixturePassiveRefresh() { lastAutomationProbe=nil;refresh() }
    static func fixture() -> ComputerUseGate { ComputerUseGate() }
}
'''
SUPPORT=r'''
import Foundation
func Log(_ value:String) {}
enum PrivacyCopy { static let voiceInput="fixture" }
@MainActor final class NSWindow { var isVisible=true }
nonisolated enum ComputerUseBackend { case cua, openAI; static var current: Self { .openAI }; var isInstalled:Bool { true } }
@MainActor final class ComputerUseSetup {
    static let shared=ComputerUseSetup()
    static func instance(for:ComputerUseBackend)->ComputerUseSetup {shared}
    var ready=true;var isInstalling=false;var holdInstall=false
    func refresh() {}
    func ensureInstalled() async -> Bool {while holdInstall {try? await Task.sleep(for:.milliseconds(5));await Task.yield()};return true}
}
@MainActor final class CodexSetup {static let shared=CodexSetup();var computerUseReady=true}
nonisolated enum Permissions {
    enum AutomationState {case granted,denied,notAsked,unavailable}
    nonisolated(unsafe) static var automation=AutomationState.granted
    nonisolated(unsafe) static var hold=false
    nonisolated(unsafe) static var screen=true
    static func nativeAutomationState(ask:Bool) async -> AutomationState {
        let captured=automation
        while hold {try? await Task.sleep(for:.milliseconds(5));await Task.yield()};return captured
    }
    static func hasScreenRecording()->Bool {screen}
    static func hasAccessibility()->Bool {true}
}
nonisolated enum AVCaptureDevice {
    enum Media {case audio};enum State {case authorized,denied,restricted,notDetermined}
    static func authorizationStatus(for:Media)->State {.notDetermined}
}
nonisolated enum SFSpeechRecognizer {
    enum State {case authorized,denied,restricted,notDetermined}
    static func authorizationStatus()->State {.notDetermined}
}
nonisolated enum OpenAIComputerUse {
    struct Configuration:Sendable {static func resolveForSetup() async throws -> Self {Self()}}
    enum RuntimeError:Error {case incomplete,conflictingHelper,restartRequired,backendUnavailable}
}
@MainActor final class OpenAIComputerUseRuntime {
    static let shared=OpenAIComputerUseRuntime()
    var nextStartFailure:OpenAIComputerUse.RuntimeError?
    var holdStart=false
    func start(configuration:OpenAIComputerUse.Configuration,stoppingConflictingHelpers:Bool) async throws -> Int {
        while holdStart {try? await Task.sleep(for:.milliseconds(5));await Task.yield()}
        if let failure=nextStartFailure {nextStartFailure=nil;throw failure};return 1
    }
    func restart(configuration:OpenAIComputerUse.Configuration) async throws {}
    func invalidate() {}
}
@MainActor final class NativePermissionCheck {
    static let shared=NativePermissionCheck()
    var proofID:UUID?
    var snapshot=NativePermissionReadiness.Snapshot() {didSet {if snapshot.isReady {if proofID == nil {proofID=UUID()}} else {proofID=nil}}}
    var calls=0
    var hold=false
    var cancelAfterPublishing=false
    var holdRefresh=false
    var invalidateOnRefresh=false
    var staleRefreshes=0
    var nextFailure:NativeComputerUseFailure?
    func publishNewProof() {snapshot = .init(accessibility:.verified,screenRecording:.verified);proofID=UUID()}
    func refresh() {}
    func refresh(configuration:OpenAIComputerUse.Configuration,helper:Int,observedProofID:UUID?) async {
        guard observedProofID == proofID else {staleRefreshes+=1;return}
        await refresh(configuration:configuration,helper:helper)
    }
    func refresh(configuration:OpenAIComputerUse.Configuration,helper:Int) async {
        while holdRefresh {try? await Task.sleep(for:.milliseconds(5));await Task.yield()}
        if invalidateOnRefresh {invalidateOnRefresh=false;snapshot = .init()}
    }
    func check(configuration:OpenAIComputerUse.Configuration,helper:Int) async throws {
        calls+=1
        while hold {try await Task.sleep(for:.milliseconds(5))}
        try Task.checkCancellation()
        if let failure=nextFailure {nextFailure=nil;throw failure}
        snapshot = .init(accessibility:.verified,screenRecording:.verified)
        if cancelAfterPublishing {cancelAfterPublishing=false;throw CancellationError()}
    }
    func close() async {snapshot = .init()}
}
nonisolated enum OpenAIComputerUseProbe {static func validateResult(_ result:[String:Any],requiresCapture:Bool) throws {}}
enum Diagnostics {
    enum Kind {case readinessFailed};enum Phase {case probe}
    static func isExpected(_ error:Error)->Bool {true}
    static func report(_ kind:Kind,phase:Phase,error:Error) {}
}
@MainActor enum HealthCaution {static func latchComputerUse() {}}
@MainActor enum Analytics {
    enum Tier {case core,extended}
    struct Event {let name:String;let parameters:[String:String];let tier:Tier}
    static var events:[Event]=[]
    static func signal(_ value:String,parameters:[String:String],tier:Tier = .extended) {
        events.append(.init(name:value,parameters:parameters,tier:tier))
    }
}
@MainActor final class CuaDriverHost {static let shared=CuaDriverHost();func markGrantsChanged() async {}}
'''
TESTS=r'''
import Foundation
@main struct Tests {
    @MainActor static var count=0
    @MainActor static func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1}
    @MainActor static var checkEvents:[Analytics.Event] {Analytics.events.filter {$0.name.hasPrefix("PermissionGate.nativeCheck")}}
    @MainActor static var checkTerminals:[Analytics.Event] {checkEvents.filter {$0.name == "PermissionGate.nativeCheckFinished"}}
    @MainActor static func settle(_ gate:ComputerUseGate) async throws {await gate.awaitAutomationRefresh();try await Task.sleep(for:.milliseconds(50))}
    @MainActor static func main() async throws {
        let proof=NativePermissionCheck.shared
        proof.snapshot = .init(accessibility:.verified,screenRecording:.verified)
        let ready=ComputerUseGate.fixture()
        ready.refresh();try await settle(ready)
        var readyFired=0
        check(ready.intercept({readyFired+=1}),"Native cached readiness waits for asynchronous validation")
        check(readyFired == 0,"No synchronous native admission")
        try await settle(ready)
        check(readyFired == 1,"Validated cached proof resumes exactly once")
        check(!ready.visible && ready.micSpeech == .notAsked,"No unsolicited voice offer")
        proof.snapshot = .init();proof.calls=0
        let fresh=ComputerUseGate.fixture();var fired=0
        check(fresh.intercept({fired+=1}),"Unknown helper capability holds user action")
        try await settle(fresh)
        check(fired == 1 && proof.calls == 1 && !fresh.visible,"Explicit user intent verifies owned target then resumes exactly once")
        proof.snapshot = .init();proof.hold=true
        let stopped=ComputerUseGate.fixture();var stoppedFired=0
        check(stopped.intercept({stoppedFired+=1}),"Pending readiness holds action")
        try await Task.sleep(for:.milliseconds(15))
        check(stopped.cancelBeforePresentation(),"Stop cancels pending preflight")
        proof.hold=false;try await settle(stopped)
        check(stoppedFired == 0 && !stopped.visible && !proof.snapshot.isReady,"Late probe cannot revive stopped action")
        proof.snapshot = .init();Permissions.screen=false
        let dismissed=ComputerUseGate.fixture();var dismissedFired=0
        check(dismissed.intercept({dismissedFired+=1}) && dismissed.visible,"Missing own screen permission opens required setup")
        dismissed.fixtureClose();Permissions.screen=true;proof.snapshot = .init(accessibility:.verified,screenRecording:.verified)
        try await settle(dismissed)
        check(dismissedFired == 0,"Closing required setup drops original action")
        proof.snapshot = .init();proof.hold=true
        let waiter=ComputerUseGate.fixture()
        let task=Task {try await waiter.waitUntilReady()}
        try await Task.sleep(for:.milliseconds(15));task.cancel();proof.hold=false
        do {try await task.value;fatalError("Stopped waiter continued")}
        catch is CancellationError {count+=1}
        catch is ComputerUseGate.SetupCancelled {count+=1}
        try await settle(waiter)
        check(!waiter.visible,"Cancellation closes waiting setup and cannot reopen later")

        proof.snapshot = .init();proof.calls=0
        proof.nextFailure = .init(kind:.unknown,code:nil,detail:.testWindowMarkerMissing,stage:.probe)
        let failed=ComputerUseGate.fixture();var failedFired=0
        check(failed.intercept({failedFired+=1}),"Failed capability check holds task")
        try await settle(failed)
        let failureMessage=failed.nativePermissionError
        check(failureMessage != nil && failed.capabilityCheckFailed && !failed.checkingCapabilities && failed.visible,
              "Failed proof leaves an actionable error and exits checking")
        failed.fixturePassiveRefresh();try await settle(failed)
        check(failed.nativePermissionError == failureMessage && failed.capabilityCheckFailed && proof.calls == 1 && !failed.allRequiredGranted,
              "Automation-only success preserves proof failure without retrying capture")
        OpenAIComputerUseRuntime.shared.nextStartFailure = .conflictingHelper
        failed.fixturePassiveRefresh();try await settle(failed)
        check(failed.nativePermissionError == failureMessage && !failed.allRequiredGranted,
              "Passive helper conflict cannot erase capability error")
        failed.fixturePassiveRefresh();try await settle(failed)
        proof.publishNewProof()
        check(failed.nativePermissionError == nil && failed.allRequiredGranted && failed.visible && failedFired == 0,
              "New shared Doctor proof clears capability error without running visible held task")
        failed.continueNow();failed.continueNow();try await settle(failed)
        check(failedFired == 1 && !failed.visible,"Repeated Continue resumes original task exactly once")

        proof.snapshot = .init()
        let startup=ComputerUseGate.fixture()
        OpenAIComputerUseRuntime.shared.nextStartFailure = .backendUnavailable
        startup.refresh();try await settle(startup)
        check(startup.nativeRestartRequired && startup.nativePermissionError != nil,"Startup failure owns restart action")
        proof.publishNewProof()
        check(startup.nativeRestartRequired && startup.nativePermissionError != nil,"New proof cannot clear unrelated startup failure")
        startup.fixturePassiveRefresh();try await settle(startup)
        check(!startup.nativeRestartRequired && startup.nativePermissionError == nil,"Real startup recovery resolves only its failure")

        let stale=ComputerUseGate.fixture()
        stale.refresh();try await settle(stale)
        Permissions.automation = .denied;Permissions.hold=true
        stale.fixturePassiveRefresh()
        try await Task.sleep(for:.milliseconds(15))
        ComputerUseSetup.shared.holdInstall=true
        stale.requestAutomation()
        Permissions.automation = .granted;Permissions.hold=false
        await stale.awaitAutomationRefresh()
        check(stale.automation == .granted,"Old denied preflight cannot overwrite newer explicit operation")
        ComputerUseSetup.shared.holdInstall=false
        try await Task.sleep(for:.milliseconds(80))
        check(stale.automation == .granted && !stale.requestingAutomation,"New explicit check completes independently")

        proof.publishNewProof();proof.holdRefresh=true;proof.invalidateOnRefresh=true
        let cold=ComputerUseGate.fixture();var coldFired=0
        check(cold.intercept({coldFired+=1}),"Cached ready result still holds task during liveness")
        try await Task.sleep(for:.milliseconds(15))
        check(coldFired == 0 && !cold.visible,"No inference admission while liveness is unresolved")
        proof.holdRefresh=false;try await settle(cold)
        check(coldFired == 1 && proof.snapshot.isReady,"Dead cached proof is renewed before task admission")

        proof.publishNewProof();proof.holdRefresh=true
        let stoppedCached=ComputerUseGate.fixture();var cachedFired=0
        check(stoppedCached.intercept({cachedFired+=1}),"Cached validation remains cancellable")
        try await Task.sleep(for:.milliseconds(15))
        check(stoppedCached.cancelBeforePresentation(),"Stop reaches a cached-proof waiter")
        proof.holdRefresh=false;try await settle(stoppedCached)
        check(cachedFired == 0 && !stoppedCached.visible,"Late liveness success cannot resume stopped cached waiter")

        proof.snapshot = .init();proof.cancelAfterPublishing=true
        let retired=ComputerUseGate.fixture();var retiredFired=0
        check(retired.intercept({retiredFired+=1}),"Retired proof operation holds original intent")
        try await settle(retired)
        check(retiredFired == 0 && retired.visible,
              "Cancelled validation cannot admit from another simultaneously ready snapshot")
        retired.fixtureClose()

        proof.snapshot = .init();proof.hold=true
        let replaced=ComputerUseGate.fixture();var oldFired=0;var newFired=0
        check(replaced.intercept({oldFired+=1}),"First user intent waits for proof")
        try await Task.sleep(for:.milliseconds(15))
        check(replaced.intercept({newFired+=1}),"New user intent replaces waiting continuation")
        proof.hold=false;try await settle(replaced)
        check(oldFired == 0 && newFired == 1 && !replaced.visible,
              "Late old check cannot clear or resume the replacement intent")

        proof.snapshot = .init();ComputerUseSetup.shared.holdInstall=true
        let teardown=ComputerUseGate.fixture();var teardownFired=0
        let callsBeforeTeardown=proof.calls
        teardown.requestAutomation()
        try await Task.sleep(for:.milliseconds(15))
        let heldTask=Task {try await teardown.waitUntilReady()}
        try await Task.sleep(for:.milliseconds(15))
        check(teardown.visible && teardown.requestingAutomation,"Fixture suspends explicit request before shared proof admission")
        var drained=false
        let drain=Task {await teardown.beginTeardown();drained=true}
        try await Task.sleep(for:.milliseconds(15))
        check(!drained && !teardown.visible && !teardown.allRequiredGranted,
              "Teardown closes setup and holds admission while pre-cache producer drains")
        do {try await heldTask.value;fatalError("Teardown left held intent running")}
        catch is ComputerUseGate.SetupCancelled {count+=1}
        teardown.refresh();teardown.requestAutomation();teardown.restartComputerUse()
        await teardown.prepareNativePermissions()
        check(teardown.intercept({teardownFired+=1}) && teardownFired == 0 && !teardown.visible,
              "Teardown consumes new intents and blocks setup producers")
        do {try await teardown.waitUntilReady();fatalError("Teardown admitted waiting task")}
        catch is CancellationError {count+=1}
        ComputerUseSetup.shared.holdInstall=false
        await drain.value
        check(drained && !teardown.requestingAutomation && !teardown.checkingAutomation && proof.calls == callsBeforeTeardown,
              "Cancelled pre-cache producer cannot start a new proof after teardown")
        await teardown.beginTeardown()
        teardown.endTeardown();teardown.requestAutomation()
        check(!teardown.requestingAutomation,"Nested teardown holds admission until every owner releases")
        teardown.endTeardown();teardown.requestAutomation()
        try await settle(teardown)
        check(proof.calls == callsBeforeTeardown+1 && !teardown.requestingAutomation && teardown.allRequiredGranted,
              "Fresh user operation can run after teardown ends")

        let passiveTeardown=ComputerUseGate.fixture()
        Permissions.automation = .denied;Permissions.hold=true
        passiveTeardown.refresh()
        try await Task.sleep(for:.milliseconds(15))
        var passiveDrained=false
        let passiveDrain=Task {await passiveTeardown.beginTeardown();passiveDrained=true}
        try await Task.sleep(for:.milliseconds(15))
        check(!passiveDrained,"Teardown drains a suspended passive Automation producer")
        Permissions.hold=false;Permissions.automation = .granted
        await passiveDrain.value
        check(passiveTeardown.automation == .unavailable && !passiveTeardown.checkingAutomation,
              "Late cancelled passive Automation result cannot publish during teardown")
        passiveTeardown.endTeardown()

        proof.snapshot = .init();proof.invalidateOnRefresh=true
        let incomingRefresh=ComputerUseGate.fixture()
        let previousStaleRefreshes=proof.staleRefreshes
        OpenAIComputerUseRuntime.shared.holdStart=true
        incomingRefresh.refresh()
        try await Task.sleep(for:.milliseconds(15))
        proof.publishNewProof()
        let newerProofID=proof.proofID
        OpenAIComputerUseRuntime.shared.holdStart=false
        try await settle(incomingRefresh)
        check(proof.staleRefreshes == previousStaleRefreshes+1 && proof.proofID == newerProofID && proof.snapshot.isReady,
              "Refresh carries the pre-start proof observation so an old producer cannot invalidate a newer proof")
        proof.invalidateOnRefresh=false

        let observedEntryPoints=Set(checkTerminals.compactMap {$0.parameters["entry_point"]})
        check(observedEntryPoints.isSuperset(of:["passive","explicit_check","held_task","continue"]),
              "Telemetry distinguishes passive, explicit, held-task and Continue checks")
        check(checkEvents.count == checkTerminals.count*2,
              "Every completed check emits exactly one start and terminal across success, failure and cancellation")
        check(checkTerminals.contains {$0.parameters["outcome"] == "stale" && $0.parameters["reason"] == "superseded"},
              "Replaced passive operation is recorded as stale rather than failed or cancelled")
        check(checkTerminals.contains {$0.parameters["outcome"] == "cancelled"},
              "Stopped operation emits a cancellation terminal")

        Analytics.events=[];proof.snapshot = .init()
        let telemetry=ComputerUseGate.fixture()
        telemetry.requestAutomation();try await settle(telemetry)
        check(checkEvents.map(\.name) == ["PermissionGate.nativeCheckStarted","PermissionGate.nativeCheckFinished"],
              "One explicit owned check emits one attempt and one terminal")
        check(checkEvents[0].parameters["proof_present"] == "false"
              && checkTerminals[0].parameters["proof_present"] == "true"
              && checkTerminals[0].parameters["outcome"] == "success"
              && checkTerminals[0].parameters["reason"] == "capability_verified"
              && checkTerminals[0].parameters["stage"] == "capability"
              && checkTerminals[0].parameters["entry_point"] == "explicit_check",
              "Successful proof has an explicit denominator and bounded stage categories")
        Analytics.events=[];telemetry.fixturePassiveRefresh();try await settle(telemetry)
        check(checkEvents.count == 2 && checkTerminals[0].parameters["outcome"] == "success"
              && checkTerminals[0].parameters["reason"] == "automation_granted"
              && checkTerminals[0].parameters["stage"] == "automation"
              && checkTerminals[0].parameters["capability_requested"] == "false",
              "Passive success never claims that it proved capabilities")
        Analytics.events=[];Permissions.automation = .denied
        telemetry.fixturePassiveRefresh();try await settle(telemetry)
        check(checkEvents.count == 2 && checkTerminals[0].parameters["outcome"] == "blocked"
              && checkTerminals[0].parameters["reason"] == "automation_denied",
              "An Automation gate is counted separately from a check failure")
        Permissions.automation = .granted
        Analytics.events=[];telemetry.restartComputerUse();try await settle(telemetry)
        check(checkEvents.count == 2 && checkTerminals[0].parameters["entry_point"] == "restart",
              "Restart uses its own fixed entry point")

        Analytics.events=[]
        let privateText="PRIVATE_NONCE_PROMPT_PATH_/Users/customer/secret"
        proof.nextFailure = .init(kind:.unknown,code:42,detail:.testWindowMarkerMissing,stage:.probe,
                                  rpcCode:-32603,systemDomain:privateText,modelError:privateText)
        telemetry.requestAutomation();try await settle(telemetry)
        let failureFields=checkTerminals[0].parameters
        check(checkEvents.count == 2 && failureFields["outcome"] == "failure"
              && failureFields["reason"] == "native_error" && failureFields["native_detail"] == "testWindowMarkerMissing"
              && failureFields["native_error_code"] == "42" && failureFields["rpc_error_code"] == "-32603",
              "Failure terminal preserves only typed native classifications and numeric codes")
        let allowedKeys:Set<String>=["entry_point","stage","capability_requested","proof_present","outcome","reason",
            "elapsed_ms","native_kind","native_detail","failure_stage","native_error_code","rpc_error_code"]
        check(checkEvents.allSatisfy {event in
            event.tier == .extended && Set(event.parameters.keys).isSubset(of:allowedKeys)
                && !event.parameters.values.contains(where:{$0.contains(privateText)})
        },"Outcome analytics are extended-only and exclude model errors, arbitrary domains, nonce, prompt and path")
        let elapsed=Int(failureFields["elapsed_ms"] ?? "") ?? -1
        check((0...600_000).contains(elapsed),"Elapsed time is a bounded nonnegative integer")

        Analytics.events=[];proof.hold=true
        telemetry.requestAutomation()
        try await Task.sleep(for:.milliseconds(15))
        telemetry.fixtureClose();proof.hold=false
        try await settle(telemetry)
        check(checkEvents.count == 2 && checkTerminals.count == 1
              && checkTerminals[0].parameters["outcome"] == "cancelled"
              && checkTerminals[0].parameters["reason"] == "cancelled",
              "One stopped check emits one cancelled terminal without a failure event")
        Analytics.events=[];Permissions.hold=true
        let superseded=ComputerUseGate.fixture()
        superseded.refresh()
        try await Task.sleep(for:.milliseconds(15))
        ComputerUseSetup.shared.holdInstall=true;superseded.requestAutomation()
        Permissions.hold=false;await superseded.awaitAutomationRefresh()
        check(checkEvents.count == 2 && checkTerminals.count == 1
              && checkTerminals[0].parameters["entry_point"] == "passive"
              && checkTerminals[0].parameters["outcome"] == "stale"
              && checkTerminals[0].parameters["reason"] == "superseded",
              "One superseded passive check emits one stale terminal without cancelling its replacement")
        ComputerUseSetup.shared.holdInstall=false;try await settle(superseded)
        check(checkEvents.count == 4 && checkTerminals.last?.parameters["entry_point"] == "explicit_check"
              && checkTerminals.last?.parameters["outcome"] == "success",
              "Replacement explicit check has an independent attempt and success terminal")
        print("PASS \(count) typed gate, scoped error and held-action checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-gate-fixture-') as directory:
 p=Path(directory)
 for name,value in [('Gate',source),('Support',SUPPORT),('Tests',TESTS)]: (p/(name+'.swift')).write_text(value)
 binary=p/'test'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',
    *[str(p/(n+'.swift')) for n in ['Support','Gate','Tests']],str(APP/'Driver/NativePermissionReadiness.swift'),str(APP/'Diagnostics/NativeComputerUseFailure.swift'),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],check=True,timeout=15)
