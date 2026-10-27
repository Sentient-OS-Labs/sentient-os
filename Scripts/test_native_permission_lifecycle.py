#!/usr/bin/env python3
"""Production readiness cache lifecycle with inert windows/helper/session; no app state touched."""
from pathlib import Path
import platform
import subprocess
import tempfile
APP=Path(__file__).resolve().parents[1]/'Sentient OS macOS'
source=(APP/'Views/Permissions/NativePermissionCheck.swift').read_text()
source=source[:source.index('@MainActor private final class NativePermissionCheckWindow')].replace('import AppKit','import Foundation')
source += '\nextension NativePermissionCheck { static func fixture() -> NativePermissionCheck { NativePermissionCheck() } }\n'
SUPPORT=r'''
import Foundation
enum CodexRuntime {
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
    func reserveDiagnostic() -> UUID? { busy ? nil : UUID() }
    func endDiagnostic(_ id:UUID) {}
}
nonisolated enum OpenAIComputerUse {
    enum RuntimeError:Error {case helperRunning}
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
    func call(_ tool: String, arguments: Data, timeout: TimeInterval) async throws -> Data {
        precondition(timeout == 12 && tool == "get_app_state")
        if await Self.delay { try await Task.sleep(for:.seconds(30)) }
        let marker = await NativePermissionCheckWindow.currentMarker
        return try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":marker],["type":"image","data":"fixture"]]])
    }
    func isUsable() -> Bool { usable }
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
        let helper=NSRunningApplication(1)
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
