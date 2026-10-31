#!/usr/bin/env python3
"""Execute real hosted lifecycle + SidekickInteraction against an offline async HTTP fixture.
Optional first argument is an integrated source worktree. No account or network is used.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

def declaration(source, signature):
    start = source.index(signature); end = source.index("{", start) + 1; depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}"); end += 1
    return source[start:end]

STUBS = r'''
import Foundation
import os
nonisolated enum ModelBackend: String, Sendable {
    case sentient, claude
    @TaskLocal static var current = Self.sentient
}
nonisolated struct ComputerUseDiagnosticConsent: Sendable {}
nonisolated enum SidekickInstructionStore { struct Snapshot: Sendable { let promptBlock = "" } }
nonisolated final class SidekickPersonalization: Sendable {
    struct Review { enum Operation { case write }; let operation: Operation; let markdown: String? }
    enum Failure: Error { case unavailable }
    var promptInstructions: String { "" }
    func discardProposal() {}
    func recordAnswer(_ id: UUID, text: String) {}
    func stage(_ review: Review) async throws -> String { "" }
    static func rejectionCode(_ error: Error) async -> String { "fixture" }
}
nonisolated final class SidekickTaskSummary: Sendable {
    static let promptInstructions = ""
    func discard() {}
}
nonisolated final class SidekickConversationRun: Sendable {
    let taskID = UUID()
    func question(id: UUID, text: String, choices: [String], error: String?) throws {}
    func answer(questionID: UUID, text: String) throws {}
    func observe(_ line: String, streamID: UUID) throws {}
}
nonisolated enum SidekickToolServer { static let name = "sentient_recovery" }
nonisolated enum Diagnostics { static func isCancellation(_ error: Error) -> Bool { error is CancellationError } }
nonisolated enum AgentRunDiagnostics { enum Reason: String { case unknown; static func classify(_ text: String) -> Self { .unknown } } }
nonisolated enum CrashReporting {
    static func diagnosticBreadcrumb(_ name: String, data: [String:String]) {}
    enum Level { case info }
    static func captureEvent(_ name: String, level: Level, tags: [String:String], extra: [String:String],
                             fingerprint: [String], cooldown: TimeInterval, includeInformational: Bool) {}
}
nonisolated enum SidekickDiagnostics {
    enum Stage { case question, answer, memoryWrite, memoryRead }
    enum Backend: String { case sentient, unknown }
    enum Count { case questions, bytes }
    enum Reason { case conflict, writeFailed }
    static func event(_ stage: Stage, taskID: UUID?, backend: Backend, duration: TimeInterval = 0, counts: [Count:Int] = [:]) {}
    static func failure(_ stage: Stage, reason: Reason, taskID: UUID?, backend: Backend) {}
}
nonisolated final class Gate: Sendable {
    let open = OSAllocatedUnfairLock(initialState: false)
    func release() { open.withLock { $0 = true } }
    func wait() async throws { while !open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) } }
}
nonisolated final class HTTPFixture: URLProtocol, @unchecked Sendable {
    struct State {
        var paths: [String] = []
        var phase = "running"
        var rejectPause = false
        var rejectResume = false
        var busyPauses = 0
        var delayedHeartbeat: Gate?
        var heartbeatEntered = false
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    let pendingRequest = OSAllocatedUnfairLock<Task<Void,Never>?>(initialState: nil)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let work = Task.detached { @Sendable [self, request] in
            do {
                let (status, data) = try await Self.response(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        pendingRequest.withLock { $0 = work }
    }
    override func stopLoading() { pendingRequest.withLock { $0?.cancel() } }
    static func data(_ object: [String:Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func response(_ request: URLRequest) async throws -> (Int, Data) {
        let path = request.url!.path
        let snapshot = state.withLock { state -> (String, Int, String?, Gate?) in
            state.paths.append(path)
            if path.hasSuffix("/pause") {
                if state.rejectPause { return (state.phase, 403, "run_expired", nil) }
                if state.busyPauses > 0 { state.busyPauses -= 1; return (state.phase, 409, "run_busy", nil) }
                state.phase = "waiting_for_user"
            }
            if path.hasSuffix("/resume") {
                if state.rejectResume { return (state.phase, 429, "daily_time_exhausted", nil) }
                state.phase = "running"
            }
            if path.hasSuffix("/finish") { state.phase = "finished" }
            if path.hasSuffix("/heartbeat") { state.heartbeatEntered = true }
            return (state.phase, 200, nil, path.hasSuffix("/heartbeat") ? state.delayedHeartbeat : nil)
        }
        if let gate = snapshot.3 { try await gate.wait() }
        if let code = snapshot.2 { return (snapshot.1, data(["error":["code":code]])) }
        if path == "/auth/v1/signup" { return (200, data(["access_token":"fake-access", "refresh_token":"fake-refresh", "expires_in":3600,
            "user":["id":"5C420A59-A169-4B8B-8018-DA459FF4CC32", "is_anonymous":true]])) }
        if path == "/v1/runs" { return (200, data(["run_id":"F280999B-C9B0-4360-A71D-2205827EFB5F", "run_token":String(repeating:"r",count:48),
            "model":"claude-sonnet-5-5", "remaining_seconds":3600, "phase":"running", "purpose":"sidekick",
            "server_time":"2099-10-30T00:00:00Z", "lease_expires_at":"2099-10-30T00:00:45Z", "maximum_output_tokens":4096])) }
        return (200, data(["phase":snapshot.0, "remaining_seconds":3600, "server_time":"2099-10-30T00:00:00Z", "lease_expires_at":"2099-10-30T00:00:45Z"]))
    }
}
'''
FIXTURE = r'''
@main struct Tests {
    static let checks = OSAllocatedUnfairLock(initialState: 0)
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks.withLock { $0 += 1 } }
    static let question = try! SidekickQuestion(error: nil, question: "Which fictional project?", answers: ["First", "Second"])
    static let answer = SidekickAnswer(text: "First", selectedAnswer: 0)
    static let startedTool = #"{"type":"item.started","item":{"id":"one","type":"command_execution"}}"#
    static let endedTool = #"{"type":"item.completed","item":{"id":"one","type":"command_execution"}}"#
    static func count(_ suffix: String) -> Int { HTTPFixture.state.withLock { $0.paths.filter { $0.hasSuffix(suffix) }.count } }
    static func client() -> HostedInferenceClient {
        let config = HostedInferenceConfiguration(gatewayURL: URL(string:"https://gateway.test")!, identityURL: URL(string:"https://identity.test")!, publishableKey:"public-fixture")
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [HTTPFixture.self]
        let credential = OSAllocatedUnfairLock<Data?>(initialState:nil)
        return HostedInferenceClient(configuration:{config}, session:URLSession(configuration:settings),
            credentials:.init(read:{credential.withLock{$0}},write:{ data in credential.withLock{$0=data}}))
    }
    static func scope<T:Sendable>(_ interaction: SidekickInteraction, _ service: HostedInferenceClient,
                                  _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await HostedInference.$clientOverride.withValue(service) {
            try await SidekickInteraction.$current.withValue(interaction) {
                try await HostedInference.withRun(purpose:.sidekick,operation:body)
            }
        }
    }
    static func until(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for:.milliseconds(1)) }
        preconditionFailure("Fixture did not reach expected boundary")
    }
    static func reset() { HTTPFixture.state.withLock { $0 = .init() } }
    static func main() async throws {
        reset()
        let interaction = SidekickInteraction { _ in
            check(HTTPFixture.state.withLock{$0.phase} == "waiting_for_user", "Question shown before server paused")
            try await Task.sleep(for:.milliseconds(20)); return answer
        }
        let value = try await scope(interaction, client()) {
            // Real local MCP callbacks lose task locals; attached authority must still pause/resume.
            let response = try await Task.detached {
                check(HostedInference.currentRun == nil, "Detached callback unexpectedly inherited lease")
                return try await interaction.ask(question)
            }.value
            check(HTTPFixture.state.withLock{$0.phase} == "running", "Answer released before server resumed")
            return response
        }
        check(value == answer, "Answer was lost")
        check(count("/pause") == 1 && count("/resume") == 1 && count("/finish") == 1, "Wrong user-wait lifecycle")
        check(!interaction.isWaiting && interaction.waitingSeconds >= 0.02, "Local waiting clock was not settled")

        reset(); HTTPFixture.state.withLock { $0.busyPauses = 2 }
        let busy = SidekickInteraction { _ in
            check(count("/pause") == 3, "Question shown before active request settled"); return answer
        }
        _ = try await scope(busy, client()) { try await busy.ask(question) }
        check(count("/resume") == 1 && count("/finish") == 1, "Busy-pause recovery broke lifecycle")

        for rejected in ["pause", "resume"] {
            reset(); HTTPFixture.state.withLock { $0.rejectPause = rejected == "pause"; $0.rejectResume = rejected == "resume" }
            let shown = OSAllocatedUnfairLock(initialState:false)
            let rejectedInteraction = SidekickInteraction { _ in shown.withLock{$0=true}; return answer }
            do { _ = try await scope(rejectedInteraction, client()) { try await rejectedInteraction.ask(question) }; preconditionFailure("Rejected wait succeeded") }
            catch is HostedInference.Failure { checks.withLock{$0 += 1} }
            check(shown.withLock{$0} == (rejected == "resume"), "Pause rejection still asked user")
            check(!rejectedInteraction.isWaiting && count("/finish") == 1, "Rejected wait leaked state")
        }

        reset()
        let entered = OSAllocatedUnfairLock(initialState:false)
        let cancel = SidekickInteraction { _ in entered.withLock{$0=true}; try await Task.sleep(for:.seconds(30)); return answer }
        let work = Task { try await scope(cancel, client()) { try await cancel.ask(question) } }
        try await until { entered.withLock{$0} }; work.cancel()
        do { _ = try await work.value; preconditionFailure("Cancelled answer was accepted") } catch is CancellationError { checks.withLock{$0 += 1} }
        check(count("/resume") == 0 && count("/finish") == 1 && !cancel.isWaiting, "Cancellation resumed or leaked waiting lease")

        reset()
        let active = SidekickInteraction { _ in answer }
        _ = try await scope(active, client()) {
            try active.observeToolEvent(startedTool)
            do { _ = try await active.ask(question); preconditionFailure("Asked with active tool") }
            catch SidekickQuestion.ValidationError.invalidQuestion { checks.withLock{$0 += 1} }
            check(count("/pause") == 0, "Active tool was paused")
            try active.observeToolEvent(endedTool)
            return try await active.ask(question)
        }
        check(count("/pause") == 1 && count("/resume") == 1, "Completed tool could not ask")

        // An older heartbeat response must not undo a newer pause and suppress resume.
        reset()
        let heartbeatGate = Gate(), answerGate = Gate()
        HTTPFixture.state.withLock { $0.delayedHeartbeat = heartbeatGate }
        let waiting = OSAllocatedUnfairLock(initialState:false)
        let raced = SidekickInteraction { _ in waiting.withLock{$0=true}; try await answerGate.wait(); return answer }
        let service = client()
        _ = try await scope(raced, service) {
            let run = HostedInference.currentRun!
            let heartbeat = Task { try await service.control(run, action:"heartbeat") }
            try await until { HTTPFixture.state.withLock{$0.heartbeatEntered} }
            let questionTask = Task { try await raced.ask(question) }
            // Permit a concurrent pause to finish on the old implementation. A fixed client may
            // serialize controls, in which case pause waits behind this heartbeat instead.
            try await Task.sleep(for:.milliseconds(100))
            heartbeatGate.release(); try await heartbeat.value
            try await until { waiting.withLock{$0} }
            answerGate.release()
            let answer = try await questionTask.value
            check(HTTPFixture.state.withLock{$0.phase} == "running", "Stale heartbeat suppressed server resume after real Sidekick answer")
            return answer
        }
        check(count("/resume") == 1 && count("/finish") == 1, "Raced wait did not settle")
        print("Hosted Sidekick production interaction: \(checks.withLock{$0}) checks passed")
    }
}
'''
recovery = (APP / "Notch Magic/SidekickRecovery.swift").read_text()
models = "\n".join(declaration(recovery, key) for key in ("nonisolated struct SidekickQuestion:", "nonisolated struct SidekickAnswer:"))
with tempfile.TemporaryDirectory(prefix="sentient-hosted-waits-") as directory:
    directory = Path(directory); source = directory / "Tests.swift"; binary = directory / "tests"
    source.write_text(STUBS + "\n" + models + "\n" + FIXTURE)
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6", str(source),
        str(APP / "Notch Magic/SidekickInteraction.swift"),
        str(APP / "Cloud/HostedInference/HostedInference.swift"),
        str(APP / "Cloud/HostedInference/HostedInferenceClient.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
