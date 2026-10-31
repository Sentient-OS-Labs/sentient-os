#!/usr/bin/env python3
"""Exercise production daily retention and real Sentry SDK event objects, without starting Sentry.
Pass the isolated xcodebuild products directory containing Sentry.framework as the only argument.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTICS = ROOT / "Sentient OS macOS/Diagnostics"
frameworks = Path(sys.argv[1])
assert (frameworks / "Sentry.framework").is_dir(), "Build first; supply the build products directory"
TESTS = r'''
import Foundation
import Synchronization
import Sentry

@main struct Tests {
    static func check(_ condition: Bool, _ label: String) { precondition(condition, label) }
    static func hang(base: UInt64 = 0x1000, position: UInt64 = 0x30) -> Event {
        let frame = Frame()
        frame.imageAddress = String(format: "0x%016llx", base)
        frame.instructionAddress = String(format: "0x%llx", base + position)
        let image = DebugMeta()
        image.imageAddress = String(format: "0x%llx", base)
        image.debugID = "00000000-0000-4000-8000-000000000001"
        let exception = Exception(value: "App hanging for at least 10000 ms", type: "App Hanging")
        exception.mechanism = Mechanism(type: "AppHang")
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        let event = Event(level: .error)
        event.exceptions = [exception]; event.debugMeta = [image]
        return event
    }
    static func main() async throws {
        let suite = "ai.sentient.retention-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let budget = DiagnosticEventBudget(defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for _ in 0..<5 {
            check(budget.claim(signature: "one", release: "v1", identity: "app:one", now: now).allowed, "first five retained")
        }
        check(!budget.claim(signature: "one", release: "v1", identity: "app:one", observations: 20, now: now).allowed, "sixth occurrence capped")
        budget.flush()
        let restarted = DiagnosticEventBudget(defaults: defaults)
        check(!restarted.claim(signature: "one", release: "v1", identity: "app:one", now: now).allowed, "relaunch cannot reset allowance")
        check(!restarted.claim(signature: "one", release: "v1", identity: "app:one", now: now.addingTimeInterval(-86400)).allowed, "clock rollback cannot reset allowance")
        let nextDay = restarted.claim(signature: "one", release: "v1", identity: "app:one", now: now.addingTimeInterval(86400))
        check(nextDay.allowed && nextDay.suppressed == 22, "next day retains suppression totals")
        check(restarted.claim(signature: "two", release: "v1", identity: "app:one", now: now).allowed, "new signature retained")
        check(restarted.claim(signature: "one", release: "v2", identity: "app:one", now: now).allowed, "new release has independent allowance")
        check(restarted.claim(signature: "one", release: "v1", identity: "helper:one", now: now).allowed, "processes have independent allowances")
        let accepted = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask {
                if restarted.claim(signature: "concurrent", release: "v1", identity: "app:one", now: now).allowed {
                    accepted.withLock { $0 += 1 }
                }
            } }
        }
        check(accepted.withLock { $0 } == 5, "concurrent callbacks cannot exceed five")
        restarted.flush()
        let reloaded = DiagnosticEventBudget(defaults: defaults)
        check(!reloaded.claim(signature: "concurrent", release: "v1", identity: "app:one", now: now).allowed, "concurrent persistence retains final snapshot")

        for n in 0..<5 {
            check(SentryHangPolicy.apply(hang(base: 0x1000 + UInt64(n * 0x1000)), identity: "hang", release: "v1", budget: reloaded, now: now) != nil, "first samples retained across ASLR")
        }
        check(SentryHangPolicy.apply(hang(base: 0x9000), identity: "hang", release: "v1", budget: reloaded, now: now) == nil, "ASLR and hex padding cannot evade cap")
        check(SentryHangPolicy.apply(hang(position: 0x50), identity: "hang", release: "v1", budget: reloaded, now: now) != nil, "new hang stacks remain visible")
        let next = SentryHangPolicy.apply(hang(), identity: "hang", release: "v1", budget: reloaded, now: now.addingTimeInterval(86400))!
        check(next.extra?["suppressed_since_last_report"] as? Int == 1, "hang suppression count is attached")
        for _ in 0..<10 {
            let native = hang(); native.exceptions![0].mechanism = Mechanism(type: "mach")
            check(SentryHangPolicy.apply(native, identity: "hang", release: "v1", budget: reloaded, now: now) === native, "native crashes always pass unchanged")
            let fatal = hang(); fatal.level = .fatal
            check(SentryHangPolicy.apply(fatal, identity: "hang", release: "v1", budget: reloaded, now: now) === fatal, "fatal exceptions always pass unchanged")
            let unknown = hang(); unknown.debugMeta = nil
            check(SentryHangPolicy.apply(unknown, identity: "hang", release: "v1", budget: reloaded, now: now) === unknown, "unattributed hangs fail open")
            let mixed = hang(); mixed.exceptions!.append(Exception(value: "failure", type: "NSError"))
            check(SentryHangPolicy.apply(mixed, identity: "hang", release: "v1", budget: reloaded, now: now) === mixed, "mixed exceptions are not filtered as hangs")
        }
        reloaded.flush()
        let saved = defaults.data(forKey: "diagnostics.eventBudget.v1")!
        check(!String(decoding: saved, as: UTF8.self).contains("app:one"), "only hashes and counters persist")
        print("PASS durable budgets, concurrency, ASLR normalization, new-signature retention and native-crash passthrough")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-retention-tests-") as directory:
    folder = Path(directory)
    (folder / "Tests.swift").write_text(TESTS)
    binary = folder / "tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-F", str(frameworks),
                    "-framework", "Sentry", "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                    str(DIAGNOSTICS / "DiagnosticEventBudget.swift"), str(DIAGNOSTICS / "SentryHangPolicy.swift"),
                    str(folder / "Tests.swift"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
