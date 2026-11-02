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
    func fixturePassiveRefresh() { lastAutomationProbe=nil;refreshAutomation() }
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
    var ready=true;var isInstalling=false;var holdInstall=false;var installChecks=0
    func refresh() {}
    func ensureInstalled() async -> Bool {installChecks+=1;while holdInstall {try? await Task.sleep(for:.milliseconds(5));await Task.yield()};return true}
}
@MainActor final class CodexSetup {static let shared=CodexSetup();var computerUseReady=true}
nonisolated enum Permissions {
    enum AutomationState {case granted,denied,notAsked,unavailable}
    nonisolated(unsafe) static var automation=AutomationState.granted
    nonisolated(unsafe) static var hold=false
    nonisolated(unsafe) static var screen=true
    nonisolated(unsafe) static var accessibility=true
    nonisolated(unsafe) static var promptRequests=0
    nonisolated(unsafe) static var settingsOpens=0
    static func openAutomationSettings() { settingsOpens += 1 }
    static func nativeAutomationState(ask:Bool) async -> AutomationState {
        if ask {promptRequests+=1; if automation == .notAsked { automation = .granted }}
        let captured=automation
        while hold {try? await Task.sleep(for:.milliseconds(5));await Task.yield()};return captured
    }
    static func hasScreenRecording()->Bool {screen}
    static func hasAccessibility()->Bool {accessibility}
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
    enum RuntimeError:Error {case incomplete,conflictingHelper,restartRequired,backendUnavailable,helperRunning}
}
@MainActor final class OpenAIComputerUseRuntime {
    static let shared=OpenAIComputerUseRuntime()
    var nextStartFailure:OpenAIComputerUse.RuntimeError?
    var holdStart=false
    var permissionRestarts=0
    var canReserveDiagnostic=true
    var takeovers=0
    func prepareForPermissionRestart(configuration:OpenAIComputerUse.Configuration) async throws {permissionRestarts+=1}
    func start(configuration:OpenAIComputerUse.Configuration,stoppingConflictingHelpers:Bool) async throws -> Int {
        if stoppingConflictingHelpers {takeovers+=1}
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
    var isChecking=false
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
        NativePermissionSetup.shared.verified()
        if cancelAfterPublishing {cancelAfterPublishing=false;throw CancellationError()}
    }
    func close() async {snapshot = .init()}
    func invalidate() {snapshot = .init()}
}
nonisolated enum OpenAIComputerUseProbe {static func appStateResult(_ result:[String:Any]) throws -> [String:Any] {result};static func validateResult(_ result:[String:Any],requiresCapture:Bool) throws {}}
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
@main struct Tests {
 @MainActor static var count = 0
 @MainActor static func check(_ ok: Bool, _ name: String) { precondition(ok, name); count += 1 }
 @MainActor static func settle(_ gate: ComputerUseGate) async throws {
  await gate.awaitAutomationRefresh(); try await Task.sleep(for: .milliseconds(80))
 }
 @MainActor static func fresh(clear: Bool = true) -> ComputerUseGate {
  if clear { NativePermissionSetup.shared.reset() }
  NativePermissionCheck.shared.snapshot = .init()
  NativePermissionCheck.shared.calls = 0
  NativePermissionCheck.shared.nextFailure = nil
  NativePermissionCheck.shared.hold = false
  Permissions.screen = true; Permissions.automation = .granted
  return ComputerUseGate.fixture()
 }
 @MainActor static func main() async throws {
  defer { fixtureDefaults.removePersistentDomain(forName: "sentient-native-setup-fixture") }
  let proof = NativePermissionCheck.shared
  let first = fresh()
  Permissions.automation = .notAsked; Permissions.promptRequests = 0
  check(!first.intercept {}, "a first greeting needs no helper setup")
  try await settle(first)
  check(proof.calls == 0 && Permissions.promptRequests == 0 && !first.visible,
        "chat admission never prompts or reads through the helper")
  check(first.isReadyForTask && !first.allRequiredGranted, "chat-ready does not invent helper grants")
  await first.beginTeardown()

  for state in [Permissions.AutomationState.denied, .unavailable, .notAsked] {
    let gate = fresh(); Permissions.automation = state
    _ = NativePermissionSetup.shared.permissionFailed()
    check(!gate.intercept {}, "missing or revoked helper grants cannot block a chat")
    try await settle(gate)
    check(proof.calls == 0 && Permissions.promptRequests == 0, "native consent waits for actual tool use")
    await gate.beginTeardown()
  }

  let unasked = fresh(); Permissions.automation = .notAsked
  let firstAutomation = Task { @MainActor in try await unasked.waitForNativeAutomation(observed: .notAsked) }
  try await settle(unasked)
  check(unasked.visible && unasked.needsAutomation && !unasked.isReadyForTask,
        "confirmed unasked Automation opens the host setup before native requests")
  check(proof.calls == 0 && Permissions.promptRequests == 0, "showing Automation setup does not run native capability checks")
  unasked.requestAutomation(); try await settle(unasked)
  check(unasked.isReadyForTask && Permissions.promptRequests == 1, "Grant requests real macOS Automation consent")
  unasked.continueNow(); try await firstAutomation.value
  check(!unasked.visible && proof.calls == 0, "Automation grant resumes the task without helper capability preflight")
  await unasked.beginTeardown()

  let denied = fresh(); Permissions.automation = .denied
  let deniedAutomation = Task { @MainActor in try await denied.waitForNativeAutomation(observed: .denied) }
  try await settle(denied)
  check(denied.visible && denied.needsAutomation, "explicit Automation denial opens host setup")
  let promptsBefore = Permissions.promptRequests
  denied.requestAutomation()
  check(Permissions.settingsOpens == 1 && Permissions.promptRequests == promptsBefore, "denial routes to Settings")
  Permissions.automation = .granted; denied.fixturePassiveRefresh(); try await settle(denied)
  check(denied.isReadyForTask, "granting in Settings enables Continue")
  denied.continueNow(); try await deniedAutomation.value
  await denied.beginTeardown()

  let unknown = fresh(); Permissions.automation = .unavailable
  try await unknown.waitForNativeAutomation(observed: .unavailable)
  check(unknown.isReadyForTask && !unknown.visible && proof.calls == 0, "unreadable Automation status permits the real request")
  await unknown.beginTeardown()

  let staleDenial = fresh(); Permissions.automation = .granted
  try await staleDenial.waitForNativeAutomation(observed: .denied)
  check(!staleDenial.visible && staleDenial.isReadyForTask, "a fresh grant supersedes an old denial before displaying setup")
  await staleDenial.beginTeardown()

  let cancelAutomation = fresh(); Permissions.automation = .denied
  let cancelWait = Task { @MainActor in try await cancelAutomation.waitForNativeAutomation(observed: .denied) }
  try await settle(cancelAutomation); cancelWait.cancel()
  do { try await cancelWait.value; fatalError("Cancelled Automation resumed") } catch {}
  check(!cancelAutomation.visible && !cancelAutomation.hasWaitingAction, "Stop drains Automation wait and closes setup")
  await cancelAutomation.beginTeardown()
  Permissions.promptRequests = 0

  let legacy = fresh()
  fixtureDefaults.set(true, forKey: "computerUse.nativePermissionSetupCompleted")
  fixtureDefaults.set("old", forKey: "computerUse.nativePermissionConfirmedProcess")
  NativePermissionSetup.shared = NativePermissionSetup(defaults: fixtureDefaults)
  check(!NativePermissionSetup.shared.canAttemptTask, "old drag receipts never become helper readiness")
  check(!legacy.intercept {}, "legacy receipts are irrelevant to chat admission")
  await legacy.beginTeardown()

  let host = fresh(); Permissions.screen = false; var hostFired = 0
  check(host.intercept { hostFired += 1 }, "missing host capture holds the request")
  check(host.visible && proof.calls == 0 && hostFired == 0, "only host permission screen appears")
  host.continueNow()
  check(hostFired == 0, "Continue cannot bypass missing host capture")
  host.beganPermissionAction(.sentientScreen)
  check(host.requiresPermissionRestart && !host.canRestartAfterPermissions,
        "Grant reveals Restart but keeps it disabled before a completed drag")
  let restartsBefore = SafeAppRelaunch.shared.savedRestarts
  host.restartAfterPermissions()
  check(SafeAppRelaunch.shared.savedRestarts == restartsBefore, "direct restart cannot bypass drag requirement")
  host.completedPermissionDrag(.sentientScreen)
  check(host.canRestartAfterPermissions && !host.isReadyForTask,
        "completed drag enables restart without granting capture")
  host.restartAfterPermissions()
  check(SafeAppRelaunch.shared.savedRestarts == restartsBefore + 1, "completed drag permits restart")
  host.beganPermissionAction(.sentientScreen)
  check(!host.canRestartAfterPermissions, "a new Grant action waits for its own completed drag")
  Permissions.screen = true; host.refresh()
  check(!host.requiresPermissionRestart && host.isReadyForTask, "effective host grant enables Continue")
  host.continueNow(); host.continueNow()
  check(proof.calls == 0 && hostFired == 1 && !host.visible, "Continue releases exactly once without helper setup")
  await host.beginTeardown()

  // A fresh process can proceed after granting only Sentient Screen Recording.
  NativePermissionSetup.shared = NativePermissionSetup(defaults: fixtureDefaults)
  let restarted = fresh(clear: false)
  check(!restarted.intercept {} && proof.calls == 0, "restart needs no helper completion receipt")
  await restarted.beginTeardown()

  let cancel = fresh(); Permissions.screen = false; var cancelledFired = 0
  _ = cancel.intercept { cancelledFired += 1 }; cancel.fixtureClose()
  Permissions.screen = true; cancel.refresh(); cancel.continueNow()
  check(cancelledFired == 0, "closing host setup cannot revive a request after grant")
  await cancel.beginTeardown()

  let replace = fresh(); Permissions.screen = false; var oldIntent = 0, newIntent = 0
  _ = replace.intercept { oldIntent += 1 }
  _ = replace.intercept { newIntent += 1 }
  Permissions.screen = true; replace.continueNow()
  check(oldIntent == 0 && newIntent == 1, "replacement intent releases only newest request")
  await replace.beginTeardown()

  let cancelledWait = fresh(); Permissions.screen = false
  let waiter = Task { @MainActor in try await cancelledWait.waitUntilReady() }
  try await settle(cancelledWait); waiter.cancel()
  do { try await waiter.value; fatalError("Cancelled waiter continued") } catch {}
  check(!cancelledWait.hasWaitingAction && !cancelledWait.visible, "Stop drains a held host-permission waiter")
  await cancelledWait.beginTeardown()

  let teardown = fresh(); Permissions.screen = false; var late = 0
  _ = teardown.intercept { late += 1 }; await teardown.beginTeardown()
  Permissions.screen = true; teardown.continueNow()
  check(late == 0 && !teardown.isReadyForTask && !teardown.visible, "teardown closes admission")

  let settings = fresh(); Permissions.automation = .notAsked
  await settings.checkNativePermissionsIfNeeded()
  check(proof.calls == 0 && Permissions.promptRequests == 0, "visiting Settings does not request consent")
  proof.hold = true; settings.fixNativePermissions(); settings.fixNativePermissions()
  try await settle(settings)
  check(proof.calls == 1 && Permissions.promptRequests == 1, "explicit Settings repair still owns one native setup request")
  proof.hold = false; try await settle(settings)
  check(settings.nativeRepairSucceeded, "explicit repair records real completion")
  await settings.beginTeardown()

  let cancelledRepair = fresh(); proof.hold = true
  cancelledRepair.fixNativePermissions(); try await settle(cancelledRepair)
  await cancelledRepair.beginTeardown(); proof.hold = false
  check(!NativePermissionSetup.shared.canAttemptTask, "teardown cancels unfinished native repair")

  // A diagnostics failure remains visible in Settings without becoming a chat gate.
  let failedRepair = fresh()
  proof.nextFailure = .init(kind: .timeout, code: nil, detail: .requestTimedOut, stage: .probe)
  failedRepair.fixNativePermissions(); try await settle(failedRepair)
  check(failedRepair.nativePermissionError != nil && !failedRepair.intercept {}, "repair failure cannot block chat")
  await failedRepair.beginTeardown()

  ComputerUseBackend.current = .cua
  let cua = fresh(); Permissions.accessibility = false
  check(cua.intercept {}, "legacy CUA still requires Sentient Accessibility")
  Permissions.accessibility = true; cua.refresh(); cua.continueNow()
  check(cua.isReadyForTask && !cua.visible && !cua.requiresPermissionRestart, "legacy CUA continues after actual grants")
  await cua.beginTeardown()
  print("PASS \(count) host-only gate, deferred native consent, restart, cancellation and repair checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-gate-fixture-') as directory:
 p=Path(directory)
 setup=(APP/'Views/Permissions/NativePermissionSetup.swift').read_text().replace(
    'static let shared = NativePermissionSetup()',
    'static var shared = NativePermissionSetup(defaults: fixtureDefaults)')
 for name,value in [('Gate',source),('Support',SUPPORT),('Tests',TESTS),('Setup',setup)]: (p/(name+'.swift')).write_text(value)
 binary=p/'test'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',
    *[str(p/(n+'.swift')) for n in ['Support','Setup','Gate','Tests']],str(APP/'Driver/NativePermissionReadiness.swift'),str(APP/'Diagnostics/NativeComputerUseFailure.swift'),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],env=dict(os.environ,CFFIXED_USER_HOME=str(p/'home')),check=True,timeout=20)
