#!/usr/bin/env python3
"""Exercise real hosted setup and activation with offline, controlled collaborators.

Compiles SentientSetup, allowance formatting, and the panel's exact activation methods.
No preferences, Keychain, network, installers, or real provider calls are used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


panel = (APP / "Views/SentientInferencePanel.swift").read_text()
assert ".onDisappear { cancelActivation() }" in panel
assert ".onChange(of: backendRaw) { cancelActivation() }" in panel
methods = "\n".join(declaration(panel, name) for name in (
    "private func activate()", "private func cancelActivation()"))

fixture = r'''
import Foundation

@MainActor enum ModelBackend: String {
    case chatgpt, claude, custom, sentient
    static var current = Self.chatgpt
}
@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor enum HostedInference {
    struct Usage {
        var remainingSeconds: TimeInterval = 3_600
        var resetAt = Date(timeIntervalSince1970: 1_800_000_000)
        var dailyLimitSeconds: TimeInterval = 3_600
        var usedSeconds: TimeInterval = 0
    }
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Hosted service temporarily unavailable." }
    }
    static var isConfigured = true
    static var calls = 0
    static var fails = false
    static var gate: Gate?
    static var allowance = Usage()
    static func validate() async throws -> Usage {
        calls += 1
        if let gate { await gate.wait() }
        if fails { throw Failure.unavailable }
        return allowance
    }
}
// No login methods exist in these fixtures: hosted setup must not require subscription auth.
@MainActor final class ClaudeSetup {
    static let shared = ClaudeSetup()
    var installed = false
    var installStatus: String?
    var succeeds = true
    var calls = 0
    func ensureCurrent() async -> Bool { calls += 1; installed = succeeds; return succeeds }
    func refreshInstalled() async {}
}
@MainActor final class CodexSetup {
    static let shared = CodexSetup()
    var computerUseReady = false
    var outdated = false
    var installStatus: String?
    var succeeds = true
    var calls = 0
    func ensureCurrent() async -> Bool { calls += 1; computerUseReady = succeeds; return succeeds }
    func refreshInstalled() async {}
}
@MainActor final class ComputerUseSetup {
    enum Backend { case openAI }
    static let shared = ComputerUseSetup()
    static func instance(for backend: Backend) -> ComputerUseSetup { shared }
    var ready = false
    var status: String?
    var succeeds = true
    var calls = 0
    func install() async { calls += 1; ready = succeeds }
    func refresh() {}
}
@MainActor final class PanelFixture {
    let setup = SentientSetup()
    var backendRaw = "chatgpt"
    var attempt: UUID?
    var operation: Task<Void, Never>?
    func tap() { activate() }
    func leave() { cancelActivation() }
__METHODS__
}
@main struct Tests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
    }
    @MainActor static func reset() {
        ModelBackend.current = .chatgpt
        HostedInference.isConfigured = true; HostedInference.calls = 0
        HostedInference.fails = false; HostedInference.gate = nil; HostedInference.allowance = .init()
        ClaudeSetup.shared.installed = false; ClaudeSetup.shared.succeeds = true; ClaudeSetup.shared.calls = 0
        CodexSetup.shared.computerUseReady = false; CodexSetup.shared.outdated = false
        CodexSetup.shared.succeeds = true; CodexSetup.shared.calls = 0
        ComputerUseSetup.shared.ready = false; ComputerUseSetup.shared.succeeds = true; ComputerUseSetup.shared.calls = 0
    }
    @MainActor static func wait(_ gate: Gate) async {
        for _ in 0..<10_000 { if gate.entered { return }; await Task.yield() }
        preconditionFailure("Fixture did not reach async boundary")
    }
    @MainActor static func main() async {
        reset()
        let unavailable = PanelFixture()
        HostedInference.isConfigured = false
        unavailable.tap()
        check(unavailable.operation == nil && unavailable.backendRaw == "chatgpt", "An unconfigured build activated hosted inference")
        check(await unavailable.setup.prepare() == false, "Unconfigured setup reported ready")
        check(HostedInference.calls == 0 && ClaudeSetup.shared.calls == 0, "Unconfigured setup made a request or installed a runtime")
        check(unavailable.setup.status == SentientSetup.unavailableMessage, "Missing configuration was unexplained")

        reset()
        let browsing = SentientSetup()
        await browsing.refresh()
        check(HostedInference.calls == 0, "Browsing enrolled an unselected installation")

        for failure in ["service", "claude", "codex", "computer"] {
            reset()
            let panel = PanelFixture()
            HostedInference.fails = failure == "service"
            ClaudeSetup.shared.succeeds = failure != "claude"
            CodexSetup.shared.succeeds = failure != "codex"
            ComputerUseSetup.shared.succeeds = failure != "computer"
            panel.tap(); await panel.operation?.value
            check(!panel.setup.ready && panel.backendRaw == "chatgpt", "Failed setup changed provider: " + failure)
            check(panel.setup.status != nil && !panel.setup.preparing, "Failed setup was silent or stuck: " + failure)
            if failure == "service" { check(ClaudeSetup.shared.calls == 0, "Runtime installed after service rejected setup") }
        }

        reset()
        let selected = PanelFixture()
        selected.tap(); selected.tap(); await selected.operation?.value
        check(selected.backendRaw == "sentient" && selected.setup.ready, "Successful setup did not activate Sentient")
        check(HostedInference.calls == 1 && ClaudeSetup.shared.calls == 1 && CodexSetup.shared.calls == 1
            && ComputerUseSetup.shared.calls == 1, "Double click did not share exactly one setup")
        check(selected.setup.usage?.remainingSeconds == 3_600, "Server allowance was not retained")

        for change in ["leave", "provider", "configuration"] {
            reset()
            let panel = PanelFixture(), gate = Gate()
            HostedInference.gate = gate
            panel.tap(); let pending = panel.operation!
            await wait(gate)
            switch change {
            case "leave": panel.leave()
            case "provider": panel.backendRaw = "claude" // even before SwiftUI sends onChange
            default: HostedInference.isConfigured = false
            }
            let previous = panel.backendRaw
            gate.release(); await pending.value
            check(panel.backendRaw == previous, "Stale setup committed after " + change)
        }

        reset()
        let exhausted = SentientSetup()
        HostedInference.allowance.remainingSeconds = 0
        HostedInference.allowance.usedSeconds = 3_600
        check(await exhausted.prepare(), "Exhausted foreground allowance blocked preparing a background-capable provider")
        ModelBackend.current = .sentient
        HostedInference.fails = true
        await exhausted.refresh()
        check(!exhausted.ready && exhausted.usage == nil && exhausted.status != nil, "A failed refresh displayed stale healthy usage")

        check(SentientUsagePresentation.remaining(3_600) == "60 minutes left today", "Full allowance formatted incorrectly")
        check(SentientUsagePresentation.remaining(60) == "1 minute left today", "Singular allowance formatted incorrectly")
        check(SentientUsagePresentation.remaining(59).hasPrefix("Less than"), "Sub-minute balance rounded into a false full minute")
        check(SentientUsagePresentation.remaining(0) == "Daily Sidekick allowance used", "Exhausted balance not disclosed")
        check(SentientUsagePresentation.remaining(-1) == SentientUsagePresentation.remaining(0), "Negative balance shown")
        check(SentientUsagePresentation.remaining(.nan) == SentientUsagePresentation.remaining(0), "Invalid balance converted to Int")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = SentientUsagePresentation.reset(instant, timeZone: TimeZone(secondsFromGMT: 0)!)
        let local = SentientUsagePresentation.reset(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        check(utc != local && local.hasSuffix("(PST)"), "Reset instant ignored the display time zone")
        print("PASS: \(checks) hosted setup, activation, failure, cancellation, and allowance checks")
    }
}
'''.replace("__METHODS__", methods)

with tempfile.TemporaryDirectory(prefix="sentient-hosted-setup-tests-") as directory:
    directory = Path(directory)
    source = directory / "HostedSetupTests.swift"
    source.write_text(fixture)
    executable = directory / "tests"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6", str(source),
                    str(APP / "Cloud/HostedInference/SentientSetup.swift"),
                    str(APP / "Views/SentientUsagePresentation.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
