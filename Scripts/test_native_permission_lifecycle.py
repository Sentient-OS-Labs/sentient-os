#!/usr/bin/env python3
"""Production readiness cache lifecycle with inert windows/helper/session; no app state touched."""
from pathlib import Path
import platform
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'Views/Permissions/NativePermissionCheck.swift').read_text()
source=source.replace('import AppKit','import Foundation')
source += '\nextension NativePermissionCheck { static func fixture() -> NativePermissionCheck { NativePermissionCheck() } }\n'
SUPPORT=r'''
import Foundation
@MainActor enum Analytics {
    static func signal(_ name: String, parameters: [String:String]) {}
}
enum CodexRuntime {
    struct Release { let helperBuild = 1001365 }
    static let release = Release()
    struct Lease { func unlock() {} }
    static func sharedRuntimeLease() async throws -> Lease { .init() }
}
@MainActor final class NSRunningApplication {
    var isTerminated = false
    let processIdentifier: Int32
    let bundleURL: URL? = OpenAIComputerUse.appURL
    init(_ pid: Int32) { processIdentifier = pid }
}
@MainActor final class OpenAIComputerUseRuntime {
    static let shared=OpenAIComputerUseRuntime()
    var busy=false
    var helper=NSRunningApplication(1)
    var reservation: UUID?
    func reserveDiagnostic() -> UUID? {
        guard !busy, reservation == nil else {return nil}
        let id=UUID();reservation=id;return id
    }
    func endDiagnostic(_ id:UUID) {if reservation == id {reservation=nil}}
    func start(configuration: OpenAIComputerUse.Configuration) async throws -> NSRunningApplication {helper}
}
nonisolated enum OpenAIComputerUse {
    enum RuntimeError:Error {case helperRunning,backendUnavailable}
    nonisolated(unsafe) static var installed = true
    static let appURL = URL(fileURLWithPath:"/fixture-helper.app")
    static func validate(at:URL) async throws -> Bool { true }
    static func installation(at: URL) -> Bool? { installed ? true : nil }
    struct Configuration: Equatable, Sendable {
        func afterRuntimeLease() throws -> Self { self }
        let revision: Int
        var appURL: URL { OpenAIComputerUse.appURL }
    }
}
@MainActor final class NativePermissionCheckWindow {
    static var shown = 0
    static var closed = 0
    static var currentMarker = ""
    let marker = UUID().uuidString
    var isCurrent: Bool { true }
    func show() { Self.shown += 1; Self.currentMarker = marker }
    func close() { Self.closed += 1 }
    func waitUntilCurrent() async throws {try Task.checkCancellation()}
}
actor OpenAIComputerUseSession {
    @MainActor static var sessions: [OpenAIComputerUseSession] = []
    @MainActor static var delay = false
    @MainActor static var closeDelay = false
    var usable = true
    var closes = 0
    static func open(_ config: OpenAIComputerUse.Configuration) async throws -> OpenAIComputerUseSession {
        let s = OpenAIComputerUseSession()
        await MainActor.run { sessions.append(s) }; return s
    }
    func call(_ tool: String, arguments: Data, timeout: TimeInterval = 125) async throws -> Data {
        precondition(timeout > 0 && timeout <= 12 && tool == "get_app_state")
        if await Self.delay { try await Task.sleep(for:.seconds(30)) }
        let marker = await NativePermissionCheckWindow.currentMarker
        return try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":marker],["type":"image","data":"fixture"]]])
    }
    var livenessDelay: Duration = .zero
    var livenessStarted = false
    func delayLiveness() {livenessDelay = .milliseconds(200);livenessStarted=false}
    func didStartLiveness() -> Bool {livenessStarted}
    func isUsable() async -> Bool {
        livenessStarted=true
        if livenessDelay > .zero {try? await Task.sleep(for:livenessDelay)}
        return usable
    }
    func expire() { usable = false }
    func close() async {
        if await Self.closeDelay { try? await Task.sleep(for:.milliseconds(100)) }
        closes += 1; usable = false
    }
}
nonisolated enum OpenAIComputerUseProbe {
    static func validateResult(_ result: [String:Any], requiresCapture: Bool) throws {}
}
'''
TESTS=r'''
import Foundation
@main struct Tests {
    @MainActor static var count=0
    @MainActor static func check(_ condition: Bool,_ label:String) { precondition(condition,label);count+=1 }
    @MainActor static func main() async throws {
        let cache=NativePermissionCheck.fixture(), config=OpenAIComputerUse.Configuration(revision:1)
        let helper=OpenAIComputerUseRuntime.shared.helper
        cache.refresh()
        check(!cache.snapshot.isReady && NativePermissionCheckWindow.shown == 0,"Passive refresh never opens a window")
        try await cache.check(configuration:config,helper:helper)
        check(cache.snapshot.isReady && NativePermissionCheckWindow.shown == 1 && NativePermissionCheckWindow.closed == 1,"Explicit proof closes synthetic window")
        let first=OpenAIComputerUseSession.sessions.last!
        check(await first.isUsable(),"Verified helper connection stays alive")
        try await cache.check(configuration:config,helper:helper)
        check(NativePermissionCheckWindow.shown == 1,"Same live process reuses proof")
        await cache.refresh(configuration:.init(revision:2),helper:helper)
        check(!cache.snapshot.isReady,"Configuration change invalidates evidence")
        try await cache.check(configuration:config,helper:helper)
        helper.isTerminated=true;cache.refresh()
        check(!cache.snapshot.isReady,"Helper exit invalidates evidence")
        let next=NSRunningApplication(2)
        OpenAIComputerUseRuntime.shared.helper=next
        try await cache.check(configuration:config,helper:next)
        await cache.refresh(configuration:config,helper:NSRunningApplication(3))
        check(!cache.snapshot.isReady,"Replacement process cannot inherit proof")
        try await cache.check(configuration:config,helper:next)
        let connection=OpenAIComputerUseSession.sessions.last!
        await connection.expire()
        await cache.refresh(configuration:config,helper:next)
        check(!cache.snapshot.isReady,"Dead connection invalidates proof without opening UI")
        try await cache.check(configuration:config,helper:next)
        OpenAIComputerUse.installed=false;cache.refresh()
        check(!cache.snapshot.isReady,"Removed or changed helper package invalidates proof")
        OpenAIComputerUse.installed=true
        OpenAIComputerUseSession.delay=true
        let pending=Task { try await cache.check(configuration:config,helper:next) }
        try await Task.sleep(for:.milliseconds(160));pending.cancel()
        do { try await pending.value;fatalError("Cancellation ignored") } catch is CancellationError {count+=1}
        check(!cache.snapshot.isReady && NativePermissionCheckWindow.shown == NativePermissionCheckWindow.closed,"Cancelled proof closes the window and stays unknown")
        let shown=NativePermissionCheckWindow.shown
        let stopped=Task { withUnsafeCurrentTask {$0?.cancel()};try await cache.check(configuration:config,helper:next) }
        do { try await stopped.value;fatalError("Pre-cancellation ignored") } catch is CancellationError {count+=1}
        check(NativePermissionCheckWindow.shown == shown,"Stopped intent cannot open late UI")
        OpenAIComputerUseSession.delay=false
        try await cache.check(configuration:config,helper:next)
        await cache.close()
        check(!cache.snapshot.isReady,"Explicit teardown clears proof")
        let beforeBusy=NativePermissionCheckWindow.shown
        OpenAIComputerUseRuntime.shared.busy=true
        do {try await cache.check(configuration:config,helper:next);fatalError("Interrupted active runtime")}
        catch OpenAIComputerUse.RuntimeError.helperRunning {count+=1}
        check(NativePermissionCheckWindow.shown == beforeBusy,"Busy runtime never opens a competing window")
        OpenAIComputerUseRuntime.shared.busy=false
        let beforeConcurrent=NativePermissionCheckWindow.shown
        let one=Task {try await cache.check(configuration:config,helper:next)}
        let two=Task {try await cache.check(configuration:config,helper:next)}
        try await one.value;try await two.value
        check(NativePermissionCheckWindow.shown == beforeConcurrent + 1,"Concurrent callers share one synthetic window")
        await cache.close();OpenAIComputerUseSession.delay=true
        let teardown=Task {try await cache.check(configuration:config,helper:next)}
        try await Task.sleep(for:.milliseconds(160));await cache.close()
        do {try await teardown.value;fatalError("Teardown permitted late proof")} catch is CancellationError {count+=1}
        check(!cache.snapshot.isReady && NativePermissionCheckWindow.shown == NativePermissionCheckWindow.closed,
              "Reset or uninstall drains active proof and closes all owned windows")
        OpenAIComputerUseSession.delay=false
        try await cache.check(configuration:config,helper:next)
        let retiring=OpenAIComputerUseSession.sessions.last!
        OpenAIComputerUseSession.closeDelay=true
        cache.invalidate()
        let drain=Task {await cache.close()}
        try await Task.sleep(for:.milliseconds(10))
        do {try await cache.check(configuration:config,helper:next);fatalError("Check raced teardown")}
        catch is CancellationError {count+=1}
        await drain.value
        let retiredCloses = await retiring.closes
        let retiredUsable = await retiring.isUsable()
        check(retiredCloses == 1 && !retiredUsable,"Teardown joins previously invalidated retained clients")

        OpenAIComputerUseSession.closeDelay=false
        try await cache.check(configuration:config,helper:next)
        let staleProof=OpenAIComputerUseSession.sessions.last!
        await staleProof.delayLiveness()
        let stale=Task {await cache.refresh(configuration:config,helper:next)}
        while !(await staleProof.didStartLiveness()) {await Task.yield()}
        cache.invalidate()
        try await cache.check(configuration:config,helper:next)
        let newest=cache.proofID
        await stale.value
        check(cache.snapshot.isReady && cache.proofID == newest,"Old liveness failure cannot invalidate a newer proof")

        let shared=OpenAIComputerUseSession.sessions.last!
        await shared.delayLiveness();await shared.expire()
        let beforeShared=NativePermissionCheckWindow.shown
        let firstCheck=Task {try await cache.check(configuration:config,helper:next)}
        while !(await shared.didStartLiveness()) {await Task.yield()}
        let secondCheck=Task {try await cache.check(configuration:config,helper:next)}
        try await firstCheck.value;try await secondCheck.value
        check(cache.snapshot.isReady && NativePermissionCheckWindow.shown == beforeShared + 1,
              "Cached-liveness callers join one new proof without a spurious busy error")

        let closing=OpenAIComputerUseSession.sessions.last!
        await closing.delayLiveness()
        let late=Task {try await cache.check(configuration:config,helper:next)}
        while !(await closing.didStartLiveness()) {await Task.yield()}
        let beforeClose=NativePermissionCheckWindow.shown
        await cache.close()
        do {try await late.value;fatalError("Liveness waiter survived teardown")} catch is CancellationError {count+=1}
        check(!cache.snapshot.isReady && NativePermissionCheckWindow.shown == beforeClose,
              "Close drains admitted cached-proof waiter without a later window or publication")

        try await cache.check(configuration:config,helper:next)
        let stillLive=OpenAIComputerUseSession.sessions.last!
        await stillLive.delayLiveness()
        let oldSuccess=Task {try await cache.check(configuration:config,helper:next)}
        while !(await stillLive.didStartLiveness()) {await Task.yield()}
        cache.invalidate()
        do {try await oldSuccess.value;fatalError("Stale liveness success admitted work")} catch is CancellationError {count+=1}
        check(!cache.snapshot.isReady,"Late true liveness cannot certify an invalidated proof")

        try await cache.check(configuration:config,helper:next)
        let owned=OpenAIComputerUseSession.sessions.last!
        await owned.delayLiveness()
        let owner=Task {try await cache.check(configuration:config,helper:next)}
        while !(await owned.didStartLiveness()) {await Task.yield()}
        let observer=Task {try await cache.check(configuration:config,helper:next)}
        await Task.yield();observer.cancel()
        do {try await observer.value;fatalError("Cancelled observer waited")} catch is CancellationError {count+=1}
        try await owner.value
        check(cache.snapshot.isReady,"Cancelling an observer preserves the still-owned successful check")

        let observed=cache.proofID
        cache.invalidate()
        next.isTerminated=true
        let replacement=NSRunningApplication(4)
        OpenAIComputerUseRuntime.shared.helper=replacement
        try await cache.check(configuration:config,helper:replacement)
        let replacementID=cache.proofID
        let beforeStaleInput=NativePermissionCheckWindow.shown
        await cache.refresh(configuration:.init(revision:2),helper:next,observedProofID:observed)
        check(cache.snapshot.isReady && cache.proofID == replacementID,
              "Stale configuration/helper lookup cannot erase proof committed before refresh entry")
        await cache.refresh(configuration:config,helper:next,observedProofID:nil)
        check(cache.snapshot.isReady && cache.proofID == replacementID,
              "Lookup begun without evidence cannot erase a newly committed proof")
        try await cache.check(configuration:config,helper:next)
        check(cache.snapshot.isReady && cache.proofID == replacementID && NativePermissionCheckWindow.shown == beforeStaleInput,
              "Admitted check resolves a terminated supplied handle and reuses current proof")
        await cache.refresh(configuration:.init(revision:2),helper:replacement,observedProofID:replacementID)
        check(!cache.snapshot.isReady,"Matching observation still invalidates changed configuration")
        await cache.close()
        print("PASS \(count) native permission lifecycle checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-permission-lifecycle-') as directory:
 p=Path(directory)
 for name,value in [('Cache',source),('Support',SUPPORT),('Tests',TESTS)]: (p/(name+'.swift')).write_text(value)
 binary=p/'test'
 subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-target',f'{platform.machine()}-apple-macos15.0',
                 *[str(p/(n+'.swift')) for n in ['Support','Cache','Tests']],str(APP/'Driver/NativePermissionReadiness.swift'),
                 str(APP/'Diagnostics/NativeComputerUseFailure.swift'),'-o',str(binary)],check=True,timeout=60)
 subprocess.run([str(binary)],check=True,timeout=15)
