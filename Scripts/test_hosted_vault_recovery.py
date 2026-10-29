#!/usr/bin/env python3
"""Run the production vault slice method and checkpoint against controlled failed writers."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'Sentient OS macOS'
source = (APP / 'Vault/VaultGenerator.swift').read_text()
start = source.index('    func runCodexInStaging(')
# The first default closure precedes the method body; use its return type as the boundary.
body = source.index('async throws -> CodexCLI.Envelope {', start)
end = source.index('{', body) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
fixture = r'''
import Foundation
nonisolated func Log(_ value: String) {}
nonisolated enum ModelBackend: Sendable {
    case sentient, claude
    @TaskLocal static var runOverride: Self?
    static var current: Self { runOverride ?? .sentient }
}
nonisolated enum CodexCLI {
    enum Model: Sendable { case opus }
    struct Invocation: Sendable {
        var claudeModel = Model.opus
        var hostedVaultRoot: String?
        var webSearch = true
        var includeUserConfig = true
    }
    struct Envelope: Sendable {}
    enum CLIError: Error { case usageLimit(String, String?), timedOut, failed }
}
nonisolated enum FrontierRun {
    @TaskLocal static var writer: (@Sendable (CodexCLI.Invocation) throws -> Void)?
    static func run(_ invocation: CodexCLI.Invocation, onLine: (@Sendable (String) -> Void)?) async throws -> CodexCLI.Envelope {
        try writer?(invocation); return .init()
    }
}
actor VaultGenerator {
    enum Progress: Sendable { case calling, writing(notes: Int) }
    struct ResumeToken: Sendable {
        let sessionID: String?
        let stagingPath: String
        var sliceIndex: Int? = nil
        var sliceBudget: Int? = nil
        var sliceItemLimit: Int? = nil
        var sessionScope: String? = nil
        static func scope(for backend: ModelBackend) -> String { backend == .sentient ? "sentient:claude:v1" : "claude:v1" }
    }
    enum VaultError: Error { case usageLimit(message: String, resume: ResumeToken), interrupted(resume: ResumeToken) }
    nonisolated static func census(of directory: URL) -> (notes: Int, folders: Int) { (1, 0) }
    __METHOD__
}
@main struct RecoveryTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        let failures: [any Error] = [CodexCLI.CLIError.usageLimit("quota", "unsafe-partial-session"),
            CodexCLI.CLIError.timedOut, CodexCLI.CLIError.failed, CancellationError()]
        for (index, failure) in failures.enumerated() {
            let staging = root.appendingPathComponent("case-\(index)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let original = staging.appendingPathComponent("README.md")
            try "completed slice".write(to: original, atomically: true, encoding: .utf8)
            try "retained source snapshot".write(to: staging.appendingPathComponent(".corpus.json"), atomically: true, encoding: .utf8)
            let writer: @Sendable (CodexCLI.Invocation) throws -> Void = { invocation in
                precondition(invocation.hostedVaultRoot == staging.path && !invocation.webSearch && !invocation.includeUserConfig)
                try "partial overwrite".write(to: original, atomically: true, encoding: .utf8)
                try "partial new file".write(to: staging.appendingPathComponent("partial.md"), atomically: true, encoding: .utf8)
                throw failure
            }
            var token: VaultGenerator.ResumeToken?
            do {
                _ = try await FrontierRun.$writer.withValue(writer) {
                    try await VaultGenerator().runCodexInStaging(.init(), staging: staging, sliceIndex: 2, sliceBudget: 200, sliceItemLimit: 3)
                }
                check(false, "Failed writer reported success")
            } catch VaultGenerator.VaultError.usageLimit(_, let resume) { token = resume }
              catch VaultGenerator.VaultError.interrupted(let resume) { token = resume }
            check(token?.sliceIndex == 2, "Skipped incomplete slice")
            check(token?.sessionID == nil, "Retained a partial hosted session")
            check(token?.sessionScope == "sentient:claude:v1", "Lost runtime namespace")
            check(token?.sliceBudget == 200 && token?.sliceItemLimit == 3, "Changed slice partition")
            check(try String(contentsOf: original, encoding: .utf8) == "completed slice", "Did not restore last successful slice")
            check(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("partial.md").path), "Retained partial new file")
            check(try String(contentsOf: staging.appendingPathComponent(".corpus.json"), encoding: .utf8) == "retained source snapshot", "Lost retry corpus")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        check(!leftovers.contains { $0.contains("-checkpoint-") }, "Leaked checkpoint copies")
        print("PASS: \(checks) production hosted slice recovery checks")
    }
}
'''.replace('__METHOD__', method)
with tempfile.TemporaryDirectory(prefix='sentient-hosted-recovery-') as temporary:
    root = Path(temporary)
    (root / 'main.swift').write_text(fixture)
    binary = root / 'tests'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', str(root / 'main.swift'),
                    str(APP / 'Vault/VaultSliceCheckpoint.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root / 'data')], check=True)
