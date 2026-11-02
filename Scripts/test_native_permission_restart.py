#!/usr/bin/env python3
"""Exercise the production permission-restart guard with inert process and lease peers.
No helper is launched/stopped and no real permissions, preferences or accounts are touched.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
source = (APP / "Driver/OpenAIComputerUseRuntime.swift").read_text()
start = source.index("    func prepareForPermissionRestart(")
end = source.index("{", start) + 1
depth = 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1

fixture = r'''
import Foundation
@MainActor enum CodexRuntime {
    static let executable = URL(fileURLWithPath: "/fixture/codex")
    static var busy = false
    static var unlocks = 0
    @MainActor struct Lease { func unlock() { CodexRuntime.unlocks += 1 } }
    static func executionLease(for path: String, exclusive: Bool) throws -> Lease? {
        precondition(path == executable.path && exclusive)
        return busy ? nil : Lease()
    }
}
@MainActor enum OpenAIComputerUse {
    enum RuntimeError: Error { case helperRunning, changedInstallation }
    static var stops = 0
    static var refuse = false
    static var changed = false
    @MainActor struct Configuration {
        func afterRuntimeLease() throws -> Self {
            if changed { throw RuntimeError.changedInstallation }
            return self
        }
    }
    static func stopOwnedHelper(allowForce: Bool) async throws {
        precondition(!allowForce)
        stops += 1
        if refuse { throw RuntimeError.helperRunning }
    }
}
@MainActor final class Runtime {
    var activeTasks: Set<UUID> = []
    var starting: Bool?
    var checking: Bool?
    var restarting = false
    var diagnosticLease: UUID?
    var launched: String? = "previous-helper"
    var checked: String? = "previous-check"
    // PRODUCTION_METHOD
}
@main struct Main {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ result: Bool, _ message: String) {
            precondition(result, message); count += 1
        }
        for block in 0..<6 {
            let runtime = Runtime()
            switch block {
            case 0: runtime.activeTasks.insert(UUID())
            case 1: runtime.starting = true
            case 2: runtime.checking = true
            case 3: runtime.restarting = true
            case 4: runtime.diagnosticLease = UUID()
            default: CodexRuntime.busy = true
            }
            do { try await runtime.prepareForPermissionRestart(configuration: .init()); fatalError("busy restart admitted") }
            catch OpenAIComputerUse.RuntimeError.helperRunning {}
            check(OpenAIComputerUse.stops == 0, "Active work/other-process leases must prevent helper termination")
            check(runtime.launched != nil && runtime.checked != nil, "Refused admission preserves runtime state")
            CodexRuntime.busy = false
        }
        let changed = Runtime()
        OpenAIComputerUse.changed = true
        do { try await changed.prepareForPermissionRestart(configuration: .init()); fatalError("changed installation admitted") }
        catch OpenAIComputerUse.RuntimeError.changedInstallation {}
        check(OpenAIComputerUse.stops == 0 && CodexRuntime.unlocks == 1, "Installation changes are rejected under the released exclusive lease")
        OpenAIComputerUse.changed = false
        let refusal = Runtime()
        OpenAIComputerUse.refuse = true
        do { try await refusal.prepareForPermissionRestart(configuration: .init()); fatalError("refusal ignored") }
        catch OpenAIComputerUse.RuntimeError.helperRunning {}
        check(!refusal.restarting && refusal.launched != nil && CodexRuntime.unlocks == 2,
              "A refusing helper is never forced and leaves retryable state")
        OpenAIComputerUse.refuse = false
        let cancelled = Runtime()
        let task = Task { try Task.checkCancellation(); try await cancelled.prepareForPermissionRestart(configuration: .init()) }
        task.cancel()
        do { try await task.value; fatalError("cancelled restart admitted") } catch is CancellationError {}
        check(OpenAIComputerUse.stops == 1, "Cancelled preparation never stops a helper")
        let success = Runtime()
        try await success.prepareForPermissionRestart(configuration: .init())
        check(success.launched == nil && success.checked == nil && !success.restarting,
              "Successful graceful stop clears old helper/readiness caches")
        check(OpenAIComputerUse.stops == 2 && CodexRuntime.unlocks == 3, "Successful preparation releases its runtime lease")
        print("PASS \(count) permission-restart ownership and lease checks")
    }
}
'''.replace("// PRODUCTION_METHOD", source[start:end])

with tempfile.TemporaryDirectory(prefix="sentient-permission-restart-") as directory:
    root = Path(directory)
    swift = root / "Fixture.swift"
    swift.write_text(fixture)
    binary = root / "fixture"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
