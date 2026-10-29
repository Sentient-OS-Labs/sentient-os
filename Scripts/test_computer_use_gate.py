#!/usr/bin/env python3
"""Real gate admission/held-intent logic, with inert permission peers and window lifecycle.
All defaults, permission APIs, native sessions, app state and UI are replaced by fixture peers.
"""
from pathlib import Path
import platform
import os
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
        if ownsPermissionRelaunch, SafeAppRelaunch.shared.isPreparing,
           !SafeAppRelaunch.shared.isApplicationTerminating { SafeAppRelaunch.shared.cancelPendingRelaunch() }
        ownsPermissionRelaunch=false
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
nonisolated enum ComputerUseBackend { case cua, openAI; nonisolated(unsafe) static var current: Self = .openAI; var isInstalled:Bool { true } }
@MainActor let fixtureDefaults = UserDefaults(suiteName: "sentient-native-setup-fixture")!
@MainActor final class SafeAppRelaunch {
    static let shared=SafeAppRelaunch()
    var canRelaunchPermissionWait=true;var canRelaunch=true;var isPreparing=false
    var isApplicationTerminating=false;var cancellations=0
    var savedRestarts=0;var idleRestarts=0
    func relaunchPermissionWait()->Bool {savedRestarts+=1;return true}
    func relaunchPreservingDraft()->Bool {idleRestarts+=1;return true}
    func cancelPendingRelaunch() {isPreparing=false;cancellations+=1}
}
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
    var permissionRestarts=0
    func prepareForPermissionRestart(configuration:OpenAIComputerUse.Configuration) async throws {permissionRestarts+=1}
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
    func check(configuration:OpenAIComputerUse.Configuration,helper:Int,useHelperSetup:Bool = false) async throws {
        precondition(useHelperSetup, "Gate recovery must use the official helper UI")
        calls+=1
        while hold {try await Task.sleep(for:.milliseconds(5))}
        try Task.checkCancellation()
        if let failure=nextFailure {nextFailure=nil;throw failure}
        snapshot = .init(accessibility:.verified,screenRecording:.verified)
        if cancelAfterPublishing {cancelAfterPublishing=false;throw CancellationError()}
    }
    func close() async {snapshot = .init()}
    func invalidate() {snapshot = .init()}
}
nonisolated enum OpenAIComputerUseProbe {static func validateResult(_ result:[String:Any],requiresCapture:Bool) throws {}}
enum Diagnostics {
    enum Kind {case readinessFailed};enum Phase {case probe}
    static func isExpected(_ error:Error)->Bool {true}
    static func report(_ kind:Kind,phase:Phase,error:Error) {}
}
@MainActor enum HealthCaution {
    static let nativeComputerUseEverReadyKey="fixture.native-ever-ready"
    static func latchComputerUse() {}
}
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
        fixtureDefaults.removePersistentDomain(forName:"sentient-native-setup-fixture")
        let firstUse=ComputerUseGate.fixture();var firstFired=0
        check(firstUse.intercept({firstFired+=1}),"First use holds the request")
        try await settle(firstUse)
        check(firstUse.visible && firstUse.requiresPermissionRestart && proof.calls == 0,"Initial setup never tests a window")
        await firstUse.prepareNativePermissions();try await settle(firstUse)
        check(firstUse.automation == .granted && !firstUse.isReadyForTask,"Automation alone does not finish setup")
        NativePermissionSetup.shared.didDrop(.accessibility)
        check(NativePermissionSetup.shared.dropped == [.accessibility] && !firstUse.helperAccessibility,
              "One completed drag updates only progress, never a grant")
        firstUse.continueNow();try await settle(firstUse)
        check(SafeAppRelaunch.shared.savedRestarts == 0 && firstFired == 0,"Drag alone cannot admit or restart")
        firstUse.permissionSetupConfirmed=true
        SafeAppRelaunch.shared.canRelaunchPermissionWait=false;SafeAppRelaunch.shared.canRelaunch=false
        firstUse.restartAfterPermissions()
        check(NativePermissionSetup.shared.restartProcess == nil,"Busy work refuses restart")
        SafeAppRelaunch.shared.canRelaunchPermissionWait=true;SafeAppRelaunch.shared.canRelaunch=true
        firstUse.restartAfterPermissions()
        check(NativePermissionSetup.shared.needsRestart && !NativePermissionSetup.shared.canAttemptTask,"Same process cannot consume confirmation")
        firstUse.fixtureClose()
        NativePermissionSetup.shared=NativePermissionSetup(defaults:fixtureDefaults,processID:"after-restart")
        let restarted=ComputerUseGate.fixture();var fired=0
        _=restarted.intercept({fired+=1});try await settle(restarted)
        check(fired == 1 && proof.calls == 0 && !restarted.visible,"After restart try actual work without synthetic verification")
        check(restarted.isReadyForTask && !restarted.allRequiredGranted && !proof.snapshot.isReady,"Task admission never fabricates grant proof")
        check(OpenAIComputerUseRuntime.shared.permissionRestarts == 1,"Prior helper is refreshed once after permission restart")
        restarted.checkAfterRestartIfNeeded();restarted.checkAfterRestartIfNeeded();try await settle(restarted)
        check(proof.calls == 0,"Reopening setup never triggers a test popup")

        check(!NativePermissionSetup.shared.hasRestarted,"Successful helper preparation consumes the one-time restart receipt")
        NativePermissionSetup.shared=NativePermissionSetup(defaults:fixtureDefaults,processID:"later-launch")
        let later=ComputerUseGate.fixture();var laterFired=0
        _=later.intercept({laterFired+=1});try await settle(later)
        check(laterFired == 1 && OpenAIComputerUseRuntime.shared.permissionRestarts == 1,
              "Later launches reuse completed setup without restarting a healthy helper")

        // Merely opening a guide then quitting must not impersonate the confirmation step.
        NativePermissionSetup.shared.requestRestart()
        NativePermissionSetup.shared=NativePermissionSetup(defaults:fixtureDefaults,processID:"unconfirmed-relaunch")
        check(NativePermissionSetup.shared.needsRestart && !NativePermissionSetup.shared.canAttemptTask,"Unconfirmed relaunch does not complete setup")
        NativePermissionSetup.shared.confirmForRestart()
        NativePermissionSetup.shared=NativePermissionSetup(defaults:fixtureDefaults,processID:"confirmed-relaunch")
        let token=NativePermissionSetup.shared.permissionFailed()
        let recovery=ComputerUseGate.fixture();var recoveredFired=0
        _=recovery.intercept({recoveredFired+=1});try await settle(recovery)
        check(recovery.visible && !recovery.isReadyForTask && !recovery.requiresPermissionRestart,
              "Known permission failure offers helper recovery rather than endless restart")
        proof.nextFailure = .init(kind:.timeout,code:nil,detail:.requestTimedOut,stage:.probe)
        recovery.verifyNativePermissions();try await settle(recovery)
        check(proof.calls == 1 && recovery.capabilityCheckFailed && !recovery.isReadyForTask,"Timed out recovery never becomes ready")
        recovery.fixturePassiveRefresh();try await settle(recovery)
        check(proof.calls == 1 && recovery.capabilityCheckFailed,"Passive refresh does not repeat helper setup")
        recovery.verifyNativePermissions();try await settle(recovery)
        check(proof.calls == 2 && recovery.allRequiredGranted && recovery.isReadyForTask,"Explicit successful helper response completes recovery")
        recovery.continueNow();recovery.continueNow();try await settle(recovery)
        check(recoveredFired == 1 && !recovery.visible,"Repeated Continue releases exactly one waiting action")
        _=NativePermissionSetup.shared.permissionFailed();proof.snapshot = .init()
        proof.publishNewProof();recovery.refresh();try await settle(recovery)
        check(recovery.isReadyForTask && !NativePermissionSetup.shared.recoveryNeeded,
              "A fresh successful Settings diagnostic also resolves permission recovery")
        NativePermissionSetup.shared.requestRestart()
        NativePermissionSetup.shared.recovered(ifCurrent:token)
        check(NativePermissionSetup.shared.needsRestart,"Stale recovery cannot overwrite a newer setup round")
        NativePermissionSetup.shared.verified();proof.snapshot = .init();proof.calls=0

        OpenAIComputerUseRuntime.shared.holdStart=true
        let stopped=ComputerUseGate.fixture();var stoppedFired=0
        _=stopped.intercept({stoppedFired+=1});try await Task.sleep(for:.milliseconds(15))
        check(stopped.cancelBeforePresentation(),"Stop cancels asynchronous startup")
        OpenAIComputerUseRuntime.shared.holdStart=false;try await settle(stopped)
        check(stoppedFired == 0 && !stopped.visible,"Late startup cannot revive a stopped task")
        OpenAIComputerUseRuntime.shared.holdStart=true
        let edited=ComputerUseGate.fixture();var editedFired=0
        _=edited.intercept({editedFired+=1});try await Task.sleep(for:.milliseconds(15))
        edited.changingNativePermissions();OpenAIComputerUseRuntime.shared.holdStart=false;try await settle(edited)
        check(edited.visible && edited.requiresPermissionRestart && editedFired == 0,"New permission round cancels old admission")
        edited.fixtureClose();NativePermissionSetup.shared.verified()

        Permissions.screen=false
        let dismissed=ComputerUseGate.fixture();var dismissedFired=0
        _=dismissed.intercept({dismissedFired+=1})
        check(dismissed.visible,"Missing Sentient Screen Recording retains our setup screen")
        dismissed.fixtureClose();Permissions.screen=true;try await settle(dismissed)
        check(dismissedFired == 0,"Closing setup discards its held action")
        NativePermissionSetup.shared.requestRestart()
        let savedWait=ComputerUseGate.fixture()
        let savedTask=Task {try await savedWait.waitUntilReady()};try await settle(savedWait)
        savedWait.permissionSetupConfirmed=true;savedWait.restartAfterPermissions()
        SafeAppRelaunch.shared.isPreparing=true;savedTask.cancel()
        do {try await savedTask.value;fatalError("Saved waiter admitted")}
        catch is ComputerUseGate.SetupCancelled {} catch is CancellationError {}
        try await settle(savedWait)
        check(savedWait.visible && !savedWait.hasWaitingAction,"Restart preserves the draft and leaves setup visible while preparing")
        savedWait.fixtureClose()
        check(!SafeAppRelaunch.shared.isPreparing,"Closing setup cancels pending relaunch")
        NativePermissionSetup.shared.verified();proof.calls=0

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
        check(coldFired == 1 && !proof.snapshot.isReady,"Expired proof does not prevent a confirmed setup from trying real work")

        proof.publishNewProof();proof.holdRefresh=true
        let stoppedCached=ComputerUseGate.fixture();var cachedFired=0
        check(stoppedCached.intercept({cachedFired+=1}),"Cached validation remains cancellable")
        try await Task.sleep(for:.milliseconds(15))
        check(stoppedCached.cancelBeforePresentation(),"Stop reaches a cached-proof waiter")
        proof.holdRefresh=false;try await settle(stoppedCached)
        check(cachedFired == 0 && !stoppedCached.visible,"Late liveness success cannot resume stopped cached waiter")

        proof.snapshot = .init();OpenAIComputerUseRuntime.shared.holdStart=true
        let replaced=ComputerUseGate.fixture();var oldFired=0;var newFired=0
        _=replaced.intercept({oldFired+=1});try await Task.sleep(for:.milliseconds(15))
        _=replaced.intercept({newFired+=1})
        OpenAIComputerUseRuntime.shared.holdStart=false;try await settle(replaced)
        check(oldFired == 0 && newFired == 1,"Replacement intent is the only one resumed")

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
        check(proof.calls == callsBeforeTeardown,"Post-teardown consent still does not capture a window")
        teardown.verifyNativePermissions()
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
        telemetry.refresh();try await settle(telemetry);Analytics.events=[]
        telemetry.verifyNativePermissions();try await settle(telemetry)
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
        telemetry.verifyNativePermissions();try await settle(telemetry)
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
        telemetry.verifyNativePermissions()
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
        NativePermissionSetup.shared.requestRestart()
        fixtureDefaults.removeObject(forKey:HealthCaution.nativeComputerUseEverReadyKey)
        NativePermissionSetup.shared.reset()
        let resetPolicy=NativePermissionSetup(defaults:fixtureDefaults,processID:"after-reset")
        check(resetPolicy.needsRestart && !resetPolicy.hasRestarted,
              "Factory reset leaves no old restart receipt that could skip fresh grant setup")
        ComputerUseBackend.current = .cua
        let legacy=ComputerUseGate.fixture()
        check(!legacy.intercept({}),"Legacy CUA admission does not acquire the native restart requirement")
        check(!legacy.requiresPermissionRestart,"Legacy CUA keeps its existing permission UI")
        print("PASS \(count) typed gate, restart workflow, scoped error and held-action checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-gate-fixture-') as directory:
 p=Path(directory)
 setup=(APP/'Views/Permissions/NativePermissionSetup.swift').read_text().replace(
    'static let shared = NativePermissionSetup()',
    'static var shared = NativePermissionSetup(defaults: fixtureDefaults, processID: "before-restart")')
 for name,value in [('Gate',source),('Support',SUPPORT),('Tests',TESTS),('Setup',setup)]: (p/(name+'.swift')).write_text(value)
 binary=p/'test'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',
    *[str(p/(n+'.swift')) for n in ['Support','Setup','Gate','Tests']],str(APP/'Driver/NativePermissionReadiness.swift'),str(APP/'Diagnostics/NativeComputerUseFailure.swift'),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],env=dict(os.environ,CFFIXED_USER_HOME=str(p/'home')),check=True,timeout=20)
