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
    var ready=true;var isInstalling=false
    func refresh() {}
    func ensureInstalled() async -> Bool {true}
}
@MainActor final class CodexSetup {static let shared=CodexSetup();var computerUseReady=true}
nonisolated enum Permissions {
    enum AutomationState {case granted,denied,notAsked,unavailable}
    nonisolated(unsafe) static var automation=AutomationState.granted
    nonisolated(unsafe) static var hold=false
    nonisolated(unsafe) static var screen=true
    static func nativeAutomationState(ask:Bool) async -> AutomationState {
        while hold {try? await Task.sleep(for:.milliseconds(5))};return automation
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
    func start(configuration:OpenAIComputerUse.Configuration,stoppingConflictingHelpers:Bool) async throws -> Int {1}
    func restart(configuration:OpenAIComputerUse.Configuration) async throws {}
    func invalidate() {}
}
@MainActor final class NativePermissionCheck {
    static let shared=NativePermissionCheck()
    var snapshot=NativePermissionReadiness.Snapshot()
    var calls=0
    var hold=false
    func refresh() {}
    func refresh(configuration:OpenAIComputerUse.Configuration,helper:Int) async {}
    func check(configuration:OpenAIComputerUse.Configuration,helper:Int) async throws {
        calls+=1
        while hold {try await Task.sleep(for:.milliseconds(5))}
        try Task.checkCancellation()
        snapshot = .init(accessibility:.verified,screenRecording:.verified)
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
enum Analytics {static func signal(_ value:String,parameters:[String:String]) {}}
@MainActor final class CuaDriverHost {static let shared=CuaDriverHost();func markGrantsChanged() async {}}
'''
TESTS=r'''
import Foundation
@main struct Tests {
    @MainActor static var count=0
    @MainActor static func check(_ value:Bool,_ label:String) {precondition(value,label);count+=1}
    @MainActor static func settle(_ gate:ComputerUseGate) async throws {await gate.awaitAutomationRefresh();try await Task.sleep(for:.milliseconds(50))}
    @MainActor static func main() async throws {
        let proof=NativePermissionCheck.shared
        proof.snapshot = .init(accessibility:.verified,screenRecording:.verified)
        let ready=ComputerUseGate.fixture()
        ready.refresh();try await settle(ready)
        check(!ready.intercept({fatalError("Unheld synchronous action belongs to caller")}),"Typed command bypasses gate despite never-requested mic/speech")
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
        print("PASS \(count) typed gate and held-action checks")
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
