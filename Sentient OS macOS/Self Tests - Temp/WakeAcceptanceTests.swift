#if DEBUG
// WakeAcceptanceTests.swift
// A short physical wake/closed-lid inference test using the installed signed wake helper.
// Uses fictional prompts, never writes the real knowledge base, and restores sleep on exit.
// Doc: Documentation - General - Self-Testing (Eval Harness).md
import Foundation
import IOKit

enum WakeAcceptanceTests {
    @MainActor static func run() async {
        let helper = WakeHelperClient.shared
        var holding = false
        var armed = false
        var heartbeat: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        do {
            guard let epoch = ProcessInfo.processInfo.environment["LAB_WAKE_AT"].flatMap(Double.init),
                  (60...600).contains(epoch - Date().timeIntervalSince1970),
                  !UserDefaults.standard.bool(forKey: "scheduler.enabled"),
                  !UserDefaults.standard.bool(forKey: "dbg.scheduler.enabled"),
                  PowerState.overnightBlockReason(allowBattery: false) == nil,
                  let model = ModelLocator.resolve(), await helper.healthProbe() == .ready else {
                throw FullAcceptanceTests.Failure(message: "physical wake preconditions are not met")
            }
            let target = Date(timeIntervalSince1970: epoch)
            guard await helper.armWake(at: target) else { throw FullAcceptanceTests.Failure(message: "wake could not be armed") }
            armed = true
            Log("PHYSICAL WAKE ARMED: \(MCPSource.timestamp(target))")
            fflush(stdout)
            while Date() < target { try await Task.sleep(for: .seconds(1)) }
            let lateness = Date().timeIntervalSince(target)
            Log("PHYSICAL WAKE RUN START: \(MCPSource.timestamp(Date())), lateness=\(Int(lateness))s")
            guard await helper.beginAwake(timeout: 180) else { throw FullAcceptanceTests.Failure(message: "closed-lid awake hold failed") }
            holding = true
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            let lidClosed: Bool?
            if service != 0 {
                lidClosed = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
                IOObjectRelease(service)
            } else { lidClosed = nil }
            Log("PHYSICAL WAKE: lid closed=\(lidClosed.map(String.init) ?? "unknown")")
            heartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    _ = await helper.heartbeat()
                }
            }
            deadline = Task {
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                let restored = await helper.endAwake()
                _ = await helper.cancelWake()
                Log("PHYSICAL WAKE: bounded test timeout; sleep restoration=\(restored)")
                fflush(stdout)
                exit(1)
            }
            let engine = Engine(modelPath: model, maxNumTokens: 1024)
            try await engine.load()
            let local = try await engine.generate(prompt: "For this fictional system check, reply with exactly READY.")
            await engine.unload()
            guard local.text.contains("READY") else { throw FullAcceptanceTests.Failure(message: "local inference did not verify") }
            Log("PHYSICAL WAKE: on-device inference passed")
            var invocation = CodexCLI.Invocation(prompt: "Reply with exactly AWAKE. This is a fictional system test. Do not use tools.")
            invocation.feature = "connector-lab"; invocation.model = .gpt6luna
            invocation.toolsDisabled = true; invocation.includeUserConfig = false; invocation.webSearch = false
            invocation.effort = .low; invocation.timeout = 60
            let cloud = try await FrontierRun.run(invocation)
            guard cloud.result.trimmingCharacters(in: .whitespacesAndNewlines) == "AWAKE" else {
                throw FullAcceptanceTests.Failure(message: "cloud inference did not verify")
            }
            Log("PHYSICAL WAKE: frontier inference passed")
            heartbeat?.cancel(); deadline?.cancel()
            let restored = await helper.endAwake()
            holding = !restored
            _ = await helper.cancelWake()
            guard restored else { throw FullAcceptanceTests.Failure(message: "sleep restoration failed; helper backstops remain armed") }
            Log("PHYSICAL WAKE: sleep restored; real sleep/wake must also be confirmed in power logs")
            guard lateness < 45 else { throw FullAcceptanceTests.Failure(message: "wake execution was late") }
            guard lidClosed == true else { throw FullAcceptanceTests.Failure(message: "closed-lid condition was not observed") }
            Log("PHYSICAL WAKE EXECUTION: PASS")
        } catch {
            heartbeat?.cancel(); deadline?.cancel()
            if holding { _ = await helper.endAwake() }
            if armed { _ = await helper.cancelWake() }
            Log("PHYSICAL WAKE EXECUTION: FAIL (\(String(describing: type(of: error))))")
            if let failure = error as? FullAcceptanceTests.Failure { Log(failure.message) }
            fflush(stdout)
            exit(1)
        }
    }
}
#endif
