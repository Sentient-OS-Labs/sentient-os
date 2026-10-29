#!/usr/bin/env python3
"""Exercise production Gmail diagnostic privacy and cancellation boundaries without SDKs.

Compiles the actual categorical extractors, scrubber, operation/error boundaries and local
history implementation. Provider payloads are synthetic; persistence uses a temporary suite.
The actual process-cancellation path is covered separately by test_run_watchdog.py.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"

def declaration(source, signature):
    start = source.index(signature)
    depth = 0
    for opening in range(start, len(source)):
        depth += (source[opening] == "(") - (source[opening] == ")")
        if source[opening] == "{" and depth == 0:
            break
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

agent = (APP / "Diagnostics/AgentRunDiagnostics.swift").read_text()
crash = (APP / "Diagnostics/CrashReporting.swift").read_text()
diag = (APP / "Diagnostics/Diagnostics.swift").read_text()
registry = (APP / "Cloud/ConnectorRegistry.swift").read_text()
# Actual curated names, extracted from the registry; no real account/discovery initialization.
gmail_reads = registry.split('CuratedConnector(slug: "gmail"', 1)[1].split('codexReadTools: [', 1)[1].split(']', 1)[0]
production = "import Foundation\nimport CoreFoundation\nimport Synchronization\n"
production += "nonisolated enum AgentRunDiagnostics {\n" + "\n".join(
    declaration(agent, name) for name in ["static func toolIdentity(", "static func connectorFailureFields("]
) + "\n}\n"
production += "nonisolated enum CrashReporting {\n" + "\n".join(
    declaration(crash, name) for name in ["nonisolated static func scrubData(", "nonisolated static func scrub(text:", "private static let scrubbers:"]
) + "()\n static func diagnosticBreadcrumb(_ name: String, data: [String: String]) { Sink.state.withLock { $0.breadcrumbs.append(data.merging([\"event\": name]) { _, new in new }) } }\n}\n"
production += "nonisolated enum Diagnostics {\n @TaskLocal static var current: Operation?\n" + "\n".join(
    declaration(diag, name) for name in ["enum Event:", "enum Phase:", "struct Payload:", "final class Operation:", "static func withOperation<", "static func boundary<", "static func isCancellation("]
) + r'''
 static func isExpected(_ error: Error) -> Bool { isCancellation(error) }
 static func errorFields(_ error: Error) -> [String: String] { ["error_type": error is CancellationError ? "CancellationError" : "FixtureError"] }
 static func causeKey(_ error: Error) -> String { String(describing: type(of: error)) }
 static func report(_ event: Event, phase: Phase, reason: StaticString, error: Error, source: String?, terminal: Bool) {
     current?.markReported(error)
     _ = current?.claim(event.rawValue)
     Sink.state.withLock { $0.failures += 1 }
 }
}
'''
SUPPORT = r'''
import Foundation
import Synchronization
nonisolated enum Sink {
 struct State: Sendable { var failures = 0; var breadcrumbs: [[String: String]] = [] }
 static let state = Mutex(State())
}
nonisolated enum NativeComputerUseFailure {
 enum Detail: String { case focusChanged }
}
nonisolated enum ConnectorRegistry {
 struct Pack { let slug: String; let claudeToolPrefix: String?; let readTools: [String]?; let codexReadTools: [String]? }
 static let packs = [Pack(slug: "gmail", claudeToolPrefix: "mcp__claude_ai_Gmail__", readTools: ["search_threads"], codexReadTools: [__GMAIL_READS__])]
}
nonisolated enum ModelBackend: String { case chatgpt; static let current = Self.chatgpt }
nonisolated enum DoubleTapProvider: String { case fixture }
nonisolated enum ConnectorClassificationDiagnostics { static let ownsFailures = false }
nonisolated enum ChildProcessDiagnostics {
 static func observe<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T { try await body() }
}
'''.replace('__GMAIL_READS__', gmail_reads)
TESTS = r'''
import Foundation
@main struct Tests {
 static func main() async throws {
  var checks = 0
  func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
  func connector(_ fields: [String: Any]) -> [String: Any] {
   ["type": "mcp_tool_call", "server": "codex_apps"].merging(fields) { _, new in new }
  }
  let secret = "PRIVATE_BODY private@example.invalid /Users/private/message.txt"
  for name in ["gmail.batch_read_email", "mcp__codex_apps__gmail__batch_read_email", "mcp__codex_apps__gmail_batch_read_email", "mcp__codex_apps__gmail.batch_read_email"] {
   check(AgentRunDiagnostics.toolIdentity(server: "codex_apps", tool: name).tool == "gmail.batch_read_email", "All supported Codex tool encodings retain curated identity")
  }
  for (server, tool) in [("codex_apps", "gmail." + secret), ("codex_apps", "private_gmail.read_email"), ("private-server", "gmail.read_email"), ("codex_apps", "gmail.send_email")] {
   check(AgentRunDiagnostics.toolIdentity(server: server, tool: tool).tool == "other", "Uncurated names never enter telemetry")
  }
  check(AgentRunDiagnostics.toolIdentity(server: "claude_ai_Gmail", tool: "search_threads").tool == "gmail.search_threads", "Existing Claude curated identity remains intact")
  let transport: [String: Any] = ["status": "failed", "error": ["code": -32603, "data": ["http_status": 503, "code": "UNAVAILABLE", "message": secret]]]
  let fields = AgentRunDiagnostics.connectorFailureFields(connector(transport))
  check(fields == ["rpc_error_code": "-32603", "http_status": "503", "provider_error_code": "unavailable"], "Explicit connector diagnostics retain only recognized structured codes")
  let payload: [String: Any] = ["error": ["code": "rate_limit_exceeded", "status_code": 429, "message": secret]]
  let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
  let failed: [String: Any] = ["result": ["isError": true, "content": [["type": "text", "text": json]]]]
  check(AgentRunDiagnostics.connectorFailureFields(connector(failed)) == ["http_status": "429", "provider_error_code": "rate_limit_exceeded"], "JSON error blocks retain safe provider evidence")
  check(AgentRunDiagnostics.connectorFailureFields(connector(["error": json])) == ["http_status": "429", "provider_error_code": "rate_limit_exceeded"], "JSON transport-error strings retain only structured evidence")
  check(AgentRunDiagnostics.connectorFailureFields(connector(["status": "failed", "error": NSNull(), "result": ["structured_content": payload]]))["http_status"] == "429", "Connector failed status is sufficient even when isError is omitted")
  for unsupported in [
   transport,
   connector(transport).merging(["type": "command_execution"]) { _, new in new },
   connector(transport).merging(["type": "web_search"]) { _, new in new },
   connector(transport).merging(["server": "private-server"]) { _, new in new }
  ] {
   check(AgentRunDiagnostics.connectorFailureFields(unsupported).isEmpty, "Only native Codex connector failures receive provider fields")
  }
  for code in [127, 429, 599] {
   check(AgentRunDiagnostics.connectorFailureFields(connector(["error": ["code": code]])).isEmpty, "Generic numeric provider codes must not imply an HTTP status")
  }
  for item: [String: Any] in [
   ["status": "completed", "result": ["structured_content": payload, "content": [["type": "text", "text": json]]]],
   ["status": "completed", "result": ["content": [["type": "text", "text": "quota exceeded " + secret]]]],
   ["status": "failed", "error": ["code": 123456789, "http_status": true, "status_code": 429.5, "error_code": secret]],
   ["status": "failed", "error": ["message": json, "body": payload, "subject": "unauthorized"]]
  ] {
   check(AgentRunDiagnostics.connectorFailureFields(connector(item)).isEmpty, "Successful content, arbitrary strings and unbounded/invalid numeric values cannot become technical fields")
  }
  let binaryID = "d0fac146-217a-3766-a693-271c0f6133b0"
  let scrubbed = CrashReporting.scrubData(["app_binary_id": binaryID, "arbitrary": binaryID, "token": binaryID, "prompt": secret])
  check(scrubbed["app_binary_id"] as? String == binaryID, "Exact artifact UUID survives the production scrubber")
  check(scrubbed["arbitrary"] as? String != binaryID && scrubbed["token"] as? String == "<redacted>", "UUID allowlist does not exempt arbitrary fields or secrets")
  check(CrashReporting.scrubData(["app_binary_id": secret])["app_binary_id"] as? String != secret, "Non-UUID binary values receive normal scrubbing")

  let suite = "sentient-gmail-diagnostic-test-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  DiagnosticHistory.recordAgentFailure("agent.tool_failed", fields: fields.merging(["tool": "gmail.batch_read_email", "tool_family": "connector", "error_text": secret, "arguments": secret, "content": secret]) { _, new in new }, defaults: defaults)
  let history = try DiagnosticHistory.snapshot(defaults: defaults)
  let stored = history.errors.last!.fields
  check(stored["http_status"] == "503" && stored["rpc_error_code"] == "-32603" && stored["provider_error_code"] == "unavailable", "New evidence survives the real bounded local export ledger")
  check(stored["tool"] == "gmail.batch_read_email" && stored["error_text"] == nil && stored["arguments"] == nil && stored["content"] == nil, "Export carries curated tool identity without payloads")
  check(!String(decoding: try JSONEncoder().encode(history), as: UTF8.self).contains("PRIVATE"), "Private diagnostic text never enters persisted export")

  enum Exit: Error { case terminated }
  let recoveredParent = Diagnostics.Operation("processing")
  await Diagnostics.$current.withValue(recoveredParent) {
   var attempt: Diagnostics.Operation?
   var child: Diagnostics.Operation?
   do {
    try await Diagnostics.withOperation("gmail_read_attempt", propagatesFailure: false) {
     attempt = Diagnostics.current
     try await Diagnostics.withOperation("frontier_run") {
      child = Diagnostics.current
      Diagnostics.current?.markReported(Exit.terminated)
      throw Exit.terminated
     }
    }
   } catch Exit.terminated { checks += 1 } catch { preconditionFailure("Unexpected retry error") }
   check(attempt?.hasFailure == true && child?.hasFailure == true, "Nested runtime failures remain recorded inside their attempt")
   check(attempt?.wasReported(Exit.terminated) == true && !recoveredParent.wasReported(Exit.terminated), "Attempt cause dedup stops before the caller")
   check(attempt?.parentID == recoveredParent.id && child?.parentID == attempt?.id && child?.rootID == recoveredParent.id, "Failure isolation preserves parent and root correlation")
   check(!recoveredParent.hasFailure, "A failed retryable grandchild cannot poison processing outcome")
   await Diagnostics.withOperation("gmail_read_attempt", propagatesFailure: false) {
    await Diagnostics.withOperation("frontier_run") {}
   }
   check(!recoveredParent.hasFailure && !recoveredParent.wasReported(Exit.terminated), "Successful retry leaves parent healthy and future identical errors reportable")
  }
  let exhaustedParent = Diagnostics.Operation("processing")
  await Diagnostics.$current.withValue(exhaustedParent) {
   for _ in 0..<2 {
    do {
     try await Diagnostics.withOperation("gmail_read_attempt", propagatesFailure: false) {
      try await Diagnostics.withOperation("frontier_run") { throw Exit.terminated }
     }
    } catch Exit.terminated {} catch { preconditionFailure("Unexpected retry error") }
   }
   check(!exhaustedParent.hasFailure, "Attempts alone do not decide the caller's final result")
   // The emitter is inert, but claims and cause accounting use the real Operation methods.
   Diagnostics.report(.sourceReadFailed, phase: .read, reason: "hosted_source", error: Exit.terminated, source: "gmail", terminal: false)
   check(exhaustedParent.hasFailure && exhaustedParent.wasReported(Exit.terminated), "Caller reporting exhausted retries marks the final processing failure")
  }
  let defaultParent = Diagnostics.Operation("processing")
  await Diagnostics.$current.withValue(defaultParent) {
   do {
    try await Diagnostics.withOperation("ordinary_parent") {
     try await Diagnostics.withOperation("frontier_run") {
      Diagnostics.current?.markReported(Exit.terminated)
      throw Exit.terminated
     }
    }
   } catch Exit.terminated {} catch { preconditionFailure("Unexpected default propagation error") }
   check(defaultParent.hasFailure && defaultParent.wasReported(Exit.terminated), "Ordinary nested operations retain existing failure and cause propagation")
  }
  check(Sink.state.withLock { $0.breadcrumbs.contains { $0["operation"] == "gmail_read_attempt" && $0["event"] == "operation.end" && $0["failed"] == "true" } }, "Failed attempt stays visible in diagnostic breadcrumbs")
  Sink.state.withLock { $0.failures = 0 }
  let cancelled = Task {
   try await Diagnostics.withOperation("frontier_run") {
    try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") {
     withUnsafeCurrentTask { $0?.cancel() }
     throw Exit.terminated
    }
   }
  }
  do { try await cancelled.value; preconditionFailure("Cancelled task lost its error") }
  catch is CancellationError { checks += 1 }
  check(Sink.state.withLock { $0.failures } == 0, "Terminated sibling cannot report false setup failure")
  check(Sink.state.withLock { $0.breadcrumbs.contains { $0["event"] == "operation.end" && $0["outcome"] == "cancelled" && $0["failed"] == "false" } }, "Operation closes honestly as canceled")
  do {
   try await Diagnostics.withOperation("frontier_run") {
    try await Diagnostics.boundary(.connectorFailed, phase: .request, reason: "frontier_setup") { throw Exit.terminated }
   }
   preconditionFailure("Actual failure disappeared")
  } catch Exit.terminated { checks += 1 }
  check(Sink.state.withLock { $0.failures } == 1, "Uncancelled process failure still reports")
  print("PASS \(checks) Gmail diagnostic privacy, export and cancellation checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix="sentient-gmail-diagnostics-") as directory:
    path = Path(directory)
    (path / "Production.swift").write_text(production)
    (path / "Support.swift").write_text(SUPPORT)
    (path / "Tests.swift").write_text(TESTS)
    binary = path / "tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
                    "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library",
                    str(path / "Production.swift"), str(path / "Support.swift"), str(path / "Tests.swift"),
                    str(APP / "Diagnostics/DiagnosticHistory.swift"), "-o", str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=30)
