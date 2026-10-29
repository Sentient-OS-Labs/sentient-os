#!/usr/bin/env python3
"""Run production reporting decisions with inert sinks and synthetic failures; no telemetry.
The argument is the xcodebuild products directory containing Sparkle.framework.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def declaration(source, marker):
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


SUPPORT = r'''
import Foundation
import Synchronization
import Sparkle
nonisolated enum FixtureError: Error { case expected, defect }
nonisolated enum Fixture {
    struct State: Sendable { var sent: [String] = []; var local: [String] = []; var crumbs: [String] = [] }
    static let state = Mutex(State())
    static func reset() { state.withLock { $0 = State() } }
}
nonisolated enum CrashReporting {
    enum Level { case warning }
    static func diagnosticBreadcrumb(_ name: String, data: [String: String]) { Fixture.state.withLock { $0.crumbs.append(name) } }
    static func captureEvent(_ name: String, level: Level = .warning, tags: [String: String], extra: [String: String],
                             fingerprint: [String], cooldown: TimeInterval = 900, affectsOperation: Bool = true) {
        Fixture.state.withLock { $0.sent.append(name) }
    }
}
nonisolated enum Diagnostics {
    struct Payload { let event: String; let tags: [String: String]; let extra: [String: String]; let fingerprint: [String] }
    @TaskLocal static var current: Operation?
    final class Operation: Sendable {
        let reported = Mutex(false)
        func finish(outcome: String) {}
        func wasReported(_ error: Error) -> Bool { reported.withLock { $0 } }
        func markReported(_ error: Error) { reported.withLock { $0 = true } }
    }
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError }
    static func isExpected(_ error: Error) -> Bool { error as? FixtureError == .expected }
    static func errorFields(_ error: Error) -> [String: String] { [:] }
    static func source(_ value: String) -> String { value }
}
nonisolated enum DiagnosticHistory {
    static func recordAgentFailure(_ name: String, fields: [String: String]) { Fixture.state.withLock { $0.local.append(name) } }
    static func recordError(_ value: Diagnostics.Payload) { Fixture.state.withLock { $0.local.append(value.event) } }
}
nonisolated enum CodexFailureReason: String { case unknown; static func classify(_ error: Error) -> Self { .unknown } }
nonisolated enum CodexCLI { enum CLIError: Error { case badEnvelope(String) } }
nonisolated enum ConnectorRegistry {
    enum ToolCategory: String, Sendable { case read, write, destructive }
    struct ClassifiedTool { let name: String; let category: ToolCategory }
    struct Pack { var readTools: [String]? }
    static func pack(forSlug: String) -> Pack? { nil }
    static func telemetrySlug(_ slug: String) -> String { slug }
}
nonisolated enum ConnectorClassifier { static func reviewedDestructiveTools(slug: String) -> Set<String> { [] } }
nonisolated enum SlackConnector {
    enum Backend { case claude }
    static func categories(backend: Backend) -> [String: ConnectorRegistry.ToolCategory] { [:] }
}
nonisolated enum Microsoft365Connector {
    static func contains(_ slug: String) -> Bool { false }
    static let categories: [String: ConnectorRegistry.ToolCategory] = [:]
}
nonisolated func Log(_ message: String) {}
@MainActor enum Analytics { static func signal(_ name: String, parameters: [String: String]) {} }
nonisolated enum AgentStatus { case done, couldNot(String), none }
nonisolated final class Run {
    enum Reason: String { case unknown; static func classify(_ text: String) -> Self { .unknown } }
    let summary: [String: String]
    let operation = Diagnostics.current
    let began = Date(), feature = "fixture", backend = "fixture", trigger = "fixture"
    let correlation: [String: String] = [:]
    init(toolFailures: Int = 0) { summary = ["tool_failed": String(toolFailures)] }
    func breadcrumb(_ name: String, _ fields: [String: String]) { CrashReporting.diagnosticBreadcrumb(name, data: fields) }
    __FINISH__
    __EMIT__
}
nonisolated enum UpdatePolicy { __UPDATE__ }
'''
agent = (APP / "Diagnostics/AgentRunDiagnostics.swift").read_text()
SUPPORT = SUPPORT.replace("__FINISH__", declaration(agent, "private func finish(").replace("private func", "func", 1))
SUPPORT = SUPPORT.replace("__EMIT__", declaration(agent, "private func emit("))
SUPPORT = SUPPORT.replace("__UPDATE__", declaration((APP / "Updates/UpdateController.swift").read_text(), "nonisolated static func isExpectedUpdateOutcome("))
TESTS = r'''
import Foundation
import Sparkle
@main @MainActor struct Tests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    static func main() {
        for error: Error? in [nil, FixtureError.expected, CancellationError()] {
            Fixture.reset()
            Run(toolFailures: 3).finish(.done, error: error)
            check(Fixture.state.withLock { $0.sent.isEmpty && $0.local == ["agent.run_diagnostic"] }, "recovered/expected/stopped runs retain local evidence without an event")
        }
        for status in [AgentStatus.couldNot("unable to complete"), .none] {
            Fixture.reset(); Run(toolFailures: 2).finish(status)
            check(Fixture.state.withLock { $0.sent == ["agent.run_diagnostic"] }, "terminal task failure remains visible")
        }
        Fixture.reset()
        let operation = Diagnostics.Operation()
        Diagnostics.$current.withValue(operation) {
            Run().finish(nil, error: FixtureError.defect)
            Run().finish(nil, error: FixtureError.defect)
        }
        check(Fixture.state.withLock { $0.sent.count == 1 }, "same runtime failure reported once")
        check(operation.wasReported(FixtureError.defect), "outer terminal boundaries know the error was reported")
        Fixture.reset()
        ConnectorClassificationDiagnostics.$ownsFailures.withValue(true) { Run().finish(nil, error: FixtureError.defect) }
        check(Fixture.state.withLock { $0.sent.isEmpty }, "classifier retains ownership of its retry outcome")

        typealias C = ConnectorClassificationDiagnostics
        for state in [C.NativeState.pending, .disabled, .needsAuth, .serverMissing] {
            Fixture.reset()
            C.record(.init(stage: .inventory, reason: .inventoryNotReady, nativeState: state), slug: "slack", version: nil, attempt: 2, terminal: true)
            check(Fixture.state.withLock { $0.sent.isEmpty && !$0.crumbs.isEmpty }, "ordinary readiness states are breadcrumb-only")
        }
        for state in [C.NativeState.failed, .unknown, .snapshotMissing] {
            Fixture.reset()
            C.record(.init(stage: .inventory, reason: .inventoryNotReady, nativeState: state), slug: "slack", version: nil, attempt: 2, terminal: true)
            check(Fixture.state.withLock { $0.sent.count == 1 }, "unknown or failed native evidence remains reportable")
        }
        for reason in [C.Reason.invalidNativeInventory, .nativeToolsMissing, .invalidJSON, .categoryMismatch] {
            Fixture.reset()
            C.record(.init(stage: .validate, reason: reason), slug: "slack", version: nil, attempt: 2, terminal: true)
            check(Fixture.state.withLock { $0.sent.count == 1 }, "malformed evidence and policy mismatches stay visible")
        }
        for code in [1001, 1003, 1005] {
            let error = NSError(domain: SUSparkleErrorDomain, code: code)
            check(UpdatePolicy.isExpectedUpdateOutcome(error), "ordinary Sparkle outcomes are expected")
        }
        check(UpdatePolicy.isExpectedUpdateOutcome(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))), "user cancellation is expected")
        for code in [2001, 3000, 3001, 4000, 9999] {
            check(!UpdatePolicy.isExpectedUpdateOutcome(NSError(domain: SUSparkleErrorDomain, code: code)), "download/signature/install and unknown failures are retained")
        }
        check(!UpdatePolicy.isExpectedUpdateOutcome(NSError(domain: "Other", code: 1003)), "error codes are domain-specific")
        print("PASS \(checks) agent, connector and updater reporting checks")
    }
}
'''
frameworks = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="sentient-noise-tests-") as directory:
    folder = Path(directory)
    (folder / "Support.swift").write_text(SUPPORT)
    (folder / "Tests.swift").write_text(TESTS)
    binary = folder / "tests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-F", str(frameworks),
                    "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                    str(APP / "Diagnostics/ConnectorClassificationDiagnostics.swift"), str(folder / "Support.swift"),
                    str(folder / "Tests.swift"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
