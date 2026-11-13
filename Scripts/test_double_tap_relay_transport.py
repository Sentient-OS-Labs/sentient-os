#!/usr/bin/env python3
"""Verify TCP relay arguments, private payload cleanup, headers, timing, and failure mapping."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import Foundation

enum CodexCLI {
    struct ExecResult { let status: Int32; let stdout: String; let stderr: String }
    static var status: Int32 = 0
    static var cancel = false
    static var directory: URL?
    static var calls = 0
    static let output = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n"
    static func executeAsync(binary: String, args: [String], stdinText: String?, cwd: String?,
                             timeout: TimeInterval, includeCustomProviderKey: Bool,
                             onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ExecResult {
        calls += 1
        precondition(binary == "/usr/bin/curl" && args.first == "-q")
        precondition(args.contains("--http2") && !args.contains("--http3") && !args.contains("--location"))
        precondition(!args.contains("--insecure") && args.contains("=https"))
        precondition(!includeCustomProviderKey && timeout < 30)
        precondition(!args.joined().contains("private-identity") && !args.joined().contains("private-knowledge"))
        func value(_ flag: String) -> String { args[args.firstIndex(of: flag)! + 1] }
        precondition(value("--max-time") == "25" && value("--max-filesize") == "1048576")
        let payload = URL(fileURLWithPath: String(value("--data-binary").dropFirst()))
        let headers = URL(fileURLWithPath: String(value("--header").dropFirst()))
        directory = payload.deletingLastPathComponent()
        let payloadText = try String(contentsOf: payload, encoding: .utf8)
        let headerText = try String(contentsOf: headers, encoding: .utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory!.path)
        precondition(payloadText == "private-knowledge")
        precondition(headerText.contains("private-identity"))
        precondition(attributes[.posixPermissions] as? Int == 0o700)
        if cancel { throw CancellationError() }
        try "HTTP/1.1 100 Continue\r\n\r\nHTTP/2 200\r\nx-relay-model: fixture-model\r\n\r\n"
            .write(toFile: value("--dump-header"), atomically: false, encoding: .utf8)
        output.components(separatedBy: .newlines).forEach(onStdoutLine)
        return ExecResult(status: status, stdout: output, stderr: "")
    }
}
@main struct Checks {
    static func main() async throws {
        var checks = 0
        func check(_ result: Bool, _ label: String) { precondition(result, label); checks += 1 }
        var request = URLRequest(url: URL(string: "https://fixture.invalid/v1/draft")!)
        request.httpMethod = "POST"
        request.httpBody = Data("private-knowledge".utf8)
        request.setValue("Bearer private-identity", forHTTPHeaderField: "Authorization")
        let response = try await DoubleTapRelayTransport.response(for: request, started: Date())
        check(response.http.statusCode == 200, "final response wins over interim status")
        check(response.http.value(forHTTPHeaderField: "x-relay-model") == "fixture-model", "served model retained")
        check(response.body == CodexCLI.output, "complete SSE body preserved")
        check(response.firstText != nil, "first text measured as it arrives")
        check(!FileManager.default.fileExists(atPath: CodexCLI.directory!.path), "private request cleaned after success")
        CodexCLI.status = 28
        do {
            _ = try await DoubleTapRelayTransport.response(for: request, started: Date())
            preconditionFailure("expected timeout")
        } catch let error as URLError { check(error.code == .timedOut, "curl deadline maps to network timeout") }
        check(!FileManager.default.fileExists(atPath: CodexCLI.directory!.path), "private request cleaned after timeout")
        CodexCLI.cancel = true
        do {
            _ = try await DoubleTapRelayTransport.response(for: request, started: Date())
            preconditionFailure("expected cancellation")
        } catch is CancellationError { check(true, "cancellation preserved") }
        check(!FileManager.default.fileExists(atPath: CodexCLI.directory!.path), "private request cleaned after cancellation")
        let denied = try DoubleTapRelayTransport.parseHeaders("HTTP/2 429\r\nretry-after: 60\r\n\r\n", url: request.url!)
        check(denied.statusCode == 429, "HTTP rejection remains available to relay error handling")
        do {
            _ = try DoubleTapRelayTransport.parseHeaders("broken response", url: request.url!)
            preconditionFailure("expected malformed response")
        } catch let error as URLError { check(error.code == .badServerResponse, "malformed headers rejected") }
        print("PASS: \(checks) HTTP/2 relay checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-relay-transport-') as directory:
    root = Path(directory)
    source = root / 'fixture.swift'
    source.write_text(FIXTURE)
    binary = root / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(source),
                    str(ROOT / 'Sentient OS macOS/Double Tap/DoubleTapRelayTransport.swift'),
                    '-o', str(binary)], check=True, timeout=60)
    subprocess.run([str(binary)], check=True, timeout=20)
