#!/usr/bin/env python3
"""Exercise production drafting with a poisoned connection-pool fixture and synthetic streams."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'
FIXTURE = r'''
import Foundation

func Log(_ text: String) {}
func ErrorLabel(_ error: Error) -> String { "fixture network error" }
enum Keychain {
    static func read(_ account: String) -> String? { nil }
    static func set(_ account: String, _ value: String) -> Bool { true }
    static func delete(_ account: String) -> Bool { true }
}
enum CustomInstructions {
    static let doubleTap = ""
    static let doubleTapByteLimit = 16_000
}
enum WritingStyle {
    static let fileName = "writingstyle.md"
    static func exists(in root: URL) -> Bool { false }
}
enum ScreenRelay {
    static let defaultURL = "http://fixture.invalid"
    static let urlKey = "fixture.relay"
    static var url: URL? { URL(string: defaultURL) }
    static func identity() throws -> String { String(repeating: "a", count: 32) }
}
enum DoubleTapRelayTransport {
    static func canUseHTTP2(for request: URLRequest) -> Bool { false }
    struct Response { let http: HTTPURLResponse; let body: String; let firstText: TimeInterval? }
    static func response(for request: URLRequest, started: Date) async throws -> Response {
        preconditionFailure("HTTP fixture must use native transport")
    }
}
enum Diagnostics {
    enum Event { case doubleTapFailed }
    enum Phase { case read, request, stream, parse }
    enum Count { case httpStatus, skipped }
    struct Operation { func markReported(_ error: Error) {} }
    static var current: Operation? { nil }
    static func step(_ phase: Phase, source: String) {}
    static func report(_ event: Event, phase: Phase, reason: String = "", error: Error? = nil,
                       source: String, counts: [Count: Int] = [:]) {}
}

// Each session owns a connection pool. A timed-out pool stays poisoned, reproducing
// the repeated failure seen when production used URLSession.shared for every draft.
final class URLSession {
    enum Mode { case success, timeout, incomplete, cancelled }
    static var nextMode = Mode.success
    static var created: [URLSession] = []
    static let shared = URLSession(configuration: .default)
    let configuration: URLSessionConfiguration
    var mode: Mode
    var invalidated = false
    var requests = 0
    init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
        mode = Self.nextMode
        Self.nextMode = .success
        Self.created.append(self)
    }
    func invalidateAndCancel() { invalidated = true }
    struct Bytes { let lines: AsyncThrowingStream<String, Error> }
    func bytes(for request: URLRequest) async throws -> (Bytes, URLResponse) {
        precondition(!invalidated)
        requests += 1
        if mode == .timeout { throw URLError(.timedOut) }
        if mode == .cancelled { throw CancellationError() }
        let complete = mode != .incomplete
        let lines = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(#"data: {"type":"response.output_text.delta","delta":"Synthetic reply"}"#)
            if complete {
                continuation.yield(#"data: {"type":"response.completed","response":{"status":"completed"}}"#)
            }
            continuation.finish()
        }
        return (Bytes(lines: lines), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/2", headerFields: ["x-relay-model": "fixture"])!)
    }
}

@main struct Tests {
    static func main() async throws {
        let vault = URL(fileURLWithPath: CommandLine.arguments[1])
        try "Synthetic knowledge".write(to: vault.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        URLSession.nextMode = .timeout
        do {
            _ = try await DoubleTapInference.draft(screenshot: Data([1]), vault: vault)
            preconditionFailure("expected timeout")
        } catch DoubleTapInference.Failure.network(let code) {
            check(code == .timedOut, "transport timeout stays distinct from model failures")
        }
        let poisoned = URLSession.created.last!
        check(poisoned.invalidated, "failed owned session is invalidated")
        check(poisoned.configuration.timeoutIntervalForResource == 35, "resource lifetime is bounded")
        check(poisoned.configuration.timeoutIntervalForRequest == 20, "idle timeout is preserved")
        check(poisoned.configuration.urlCache == nil, "drafts have no response cache")
        let result = try await DoubleTapInference.draft(screenshot: Data([1]), vault: vault)
        check(result.verdict == .reply("Synthetic reply"), "next tap succeeds after a poisoned pool")
        check(URLSession.created.last! !== poisoned && poisoned.requests == 1, "later taps use a fresh pool")
        check(URLSession.created.last!.invalidated, "successful owned session is invalidated")
        for mode in [URLSession.Mode.incomplete, .cancelled] {
            URLSession.nextMode = mode
            do {
                _ = try await DoubleTapInference.draft(screenshot: Data([1]), vault: vault)
                preconditionFailure("expected unsuccessful stream")
            } catch DoubleTapInference.Failure.incomplete {
                check(mode == .incomplete, "partial drafts remain rejected")
            } catch DoubleTapInference.Failure.cancelled {
                check(mode == .cancelled, "cancellation remains distinct")
            }
            check(URLSession.created.last!.invalidated, "all exit paths release the owned session")
        }
        let supplied = URLSession(configuration: .ephemeral)
        for _ in 0..<2 {
            _ = try await DoubleTapInference.draft(screenshot: Data([1]), vault: vault, session: supplied)
            check(!supplied.invalidated, "injected session remains caller-owned")
        }
        check(supplied.requests == 2, "injected session remains reusable")
        print("PASS: \(checks) Double Tap transport lifecycle checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-draft-transport-') as directory:
    root = Path(directory)
    source = root / 'fixture.swift'
    source.write_text(FIXTURE)
    binary = root / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(source),
                    str(APP / 'Double Tap/DoubleTapInference.swift'),
                    str(APP / 'Double Tap/DoubleTapProvider.swift'), '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary), str(root)], check=True, timeout=30)
