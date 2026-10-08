#!/usr/bin/env python3
"""Run production URL parsing, pipe reading and Claude browser IPC in a macOS sandbox.

Optional --claude PATH also exercises production ClaudeCLI.startLogin against that real CLI.
No browser or account login: external network, Keychain, real profiles and /usr/bin/open
are blocked. The disposable executable path includes spaces and an apostrophe.
"""
import argparse
import json
import re
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / 'Sentient OS macOS'
parser = argparse.ArgumentParser()
parser.add_argument('--claude', type=Path)
args = parser.parse_args()

source = (APP / 'Cloud/ClaudeCLI.swift').read_text()
start = source.index('    static func startLogin(')
end = source.index('\n    /// The login ground truth', start)
login = source[start:end]

fixture = r'''
import Foundation
import Darwin

nonisolated enum CodexCLI {
    enum Availability { case notInstalled }
    enum CLIError: Error { case notAvailable(Availability), launchFailed(String) }
    static func richEnvironment(binDir: String) -> [String: String] { ProcessInfo.processInfo.environment }
}
nonisolated enum ClaudeCLI {
    static var baseEnv: [String: String] { [:] }
    static func locateBinary() -> String? { ProcessInfo.processInfo.environment["TEST_CLAUDE"] }
__LOGIN__
}
nonisolated final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var exited = false
    func receive(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    func end() { lock.lock(); defer { lock.unlock() }; exited = true }
    var links: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    var ended: Bool { lock.lock(); defer { lock.unlock() }; return exited }
}
@main struct Tests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); count += 1; print("PASS: \(message)")
    }
    static func until(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for capture or cleanup")
    }
    static func link(_ provider: LoginLink.Provider) -> String {
        var url = URLComponents(string: provider == .chatgpt
            ? "https://auth.openai.com/oauth/authorize" : "https://claude.com/cai/oauth/authorize")!
        url.queryItems = [URLQueryItem(name: "state", value: "TEST-state_-"),
            URLQueryItem(name: "client_id", value: "TEST-client"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: "TEST-challenge_-"),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: provider == .chatgpt
                ? "http://localhost:1455/auth/callback" : "http://localhost:34567/callback")]
        return url.string!
    }
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == ClaudeLoginBrowser.helperArgument {
            exit(ClaudeLoginBrowser.runHelper(arguments: CommandLine.arguments))
        }
        for provider in [LoginLink.Provider.chatgpt, .claude] {
            let text = link(provider)
            check(LoginLink.authorizationURL(text, provider: provider)?.absoluteString == text,
                  "Automatic URL preserves every byte")
            var decoder = LoginLink.Decoder(provider: provider)
            let bytes = Data(("diagnostic line\nOpen this URL:\n" + text + "\n").utf8)
            var results: [URL] = []
            for byte in bytes {
                if let url = decoder.append(Data([byte])) { results.append(url) }
            }
            check(results.map(\.absoluteString) == [text], "Byte-by-byte output reconstructs one complete link")
            check(decoder.append(Data((text + "\n").utf8)) == nil, "Duplicate output is delivered once")
            var eof = LoginLink.Decoder(provider: provider)
            check(eof.append(Data(text.utf8)) == nil && eof.append(Data(), endOfFile: true)?.absoluteString == text,
                  "Final unterminated line is delivered at EOF")
            var oversized = LoginLink.Decoder(provider: provider)
            _ = oversized.append(Data(repeating: 65, count: 100_000))
            check(oversized.append(Data(("\n" + text + "\r\n").utf8))?.absoluteString == text,
                  "Oversized diagnostic is bounded without losing the next link")
            var parts = URLComponents(string: text)!
            parts.queryItems = parts.queryItems!.map { $0.name == "redirect_uri"
                ? URLQueryItem(name: $0.name, value: "https://platform.claude.com/oauth/code/callback") : $0 }
            check(LoginLink.authorizationURL(parts.string!, provider: provider) == nil,
                  "Manual-code fallback URL is never offered as an automatic link")
            for invalid in [text.replacingOccurrences(of: "https://", with: "http://"),
                            text + "&state=another", text.replacingOccurrences(of: "S256", with: "plain"),
                            text.replacingOccurrences(of: "localhost", with: "example.com")] {
                check(LoginLink.authorizationURL(invalid, provider: provider) == nil,
                      "Untrusted or ambiguous authorization URL is rejected")
            }
        }
        let text = link(.chatgpt)
        let stream = Pipe(), output = Observations()
        // Use a real child because Foundation owns/closes the pipe's writing handle at launch.
        let emitter = Process()
        emitter.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        emitter.arguments = ["%s", text]
        emitter.standardOutput = stream
        try emitter.run()
        LoginLink.read(stream) { output.receive($0) }
        emitter.waitUntilExit()
        await until { output.links.count == 1 }
        check(output.links.first?.absoluteString == text, "Production pipe reader drains actual child output")

        let captured = Observations()
        let browser = try ClaudeLoginBrowser { captured.receive($0) }
        let fifo = browser.environment[ClaudeLoginBrowser.pipeEnvironmentKey]!
        let launcher = browser.environment["BROWSER"]!
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: launcher)
        helper.arguments = [link(.claude)]
        helper.environment = ProcessInfo.processInfo.environment.merging(browser.environment) { _, new in new }
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run(); helper.waitUntilExit()
        await until { captured.links.count == 1 }
        check(helper.terminationStatus != 0, "Sandbox prevents opening a browser")
        check(captured.links.first?.absoluteString == link(.claude),
              "Native helper captures exact URL even when browser launch fails")
        check(FileManager.default.fileExists(atPath: fifo), "IPC exists while the attempt waits")
        browser.stop(); browser.stop()
        await until { !FileManager.default.fileExists(atPath: launcher) }
        check(!FileManager.default.fileExists(atPath: fifo), "Repeated cleanup removes launcher and FIFO")
        let afterCancel = Process()
        afterCancel.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
        afterCancel.arguments = [ClaudeLoginBrowser.helperArgument, link(.claude)]
        afterCancel.environment = helper.environment
        try afterCancel.run(); afterCancel.waitUntilExit()
        check(afterCancel.terminationStatus == 1, "Helper arriving after cancellation exits without blocking")

        if ClaudeCLI.locateBinary() != nil {
            let live = Observations()
            let proc = try ClaudeCLI.startLogin(onURL: { live.receive($0) }, onExit: { live.end() })
            defer { if proc.isRunning { proc.terminate(); proc.waitUntilExit() } }
            await until { !live.links.isEmpty || !proc.isRunning }
            check(live.links.count == 1 && proc.isRunning, "Real Claude captures a link and stays waiting")
            let url = live.links[0]
            check(LoginLink.authorizationURL(url.absoluteString, provider: .claude) == url,
                  "Real Claude supplies an automatic callback URL")
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "redirect_uri" }!.value!
            var target = URLComponents(string: redirect)!; target.path = "/"
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(from: target.url!)
            check((response as? HTTPURLResponse)?.statusCode == 404 && proc.isRunning,
                  "Captured return address reaches the real waiting Claude server")
            proc.terminate(); proc.waitUntilExit()
            await until { live.ended }
            check(live.ended, "Real CLI termination runs production cleanup callback")
        }
        print("RESULT: \(count) login-link checks passed; no account authenticated")
    }
}
'''.replace('__LOGIN__', login)

with tempfile.TemporaryDirectory(prefix="sentient login's ") as tmp:
    directory = Path(tmp).resolve()
    profile = directory / 'profile'
    profile.mkdir(mode=0o700)
    swift = directory / 'Fixture.swift'
    swift.write_text(fixture)
    binary = directory / 'login probe'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
                    '-parse-as-library', str(APP / 'Cloud/LoginLink.swift'),
                    str(APP / 'Cloud/ClaudeLoginBrowser.swift'), str(swift), '-o', str(binary)], check=True)
    home = Path.home()
    sandbox = directory / 'probe.sb'
    # JSON's string quoting is also valid for these sandbox path literals; not shell commands.
    q = lambda path: json.dumps(str(path))
    # Foundation uses Darwin's per-user temp directory even when TMPDIR is overridden.
    helper_paths = '^' + re.escape(str(directory.parent)) + '/sentient-login-[A-F0-9-]+(/.*)?$'
    sandbox.write_text(f'''(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
(deny file-write*)
(allow file-write* (subpath {q(directory)}) (regex {q(helper_paths)}) (literal "/dev/null"))
(deny file-read* (subpath {q(home / '.claude')}) (literal {q(home / '.claude.json')})
 (subpath {q(home / 'Library/Keychains')}))
(deny mach-lookup (global-name "com.apple.securityd"))
(deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/osascript"))
''')
    env = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(directory),
           'CLAUDE_CONFIG_DIR': str(profile), 'DISABLE_AUTOUPDATER': '1', 'DISABLE_TELEMETRY': '1',
           'DISABLE_ERROR_REPORTING': '1', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'TERM': 'dumb'}
    if args.claude:
        env['TEST_CLAUDE'] = str(args.claude.resolve())
    subprocess.run(['/usr/bin/sandbox-exec', '-f', str(sandbox), str(binary)], env=env,
                   cwd=directory, check=True, timeout=30)
