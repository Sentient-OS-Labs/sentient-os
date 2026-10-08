#!/usr/bin/env python3
"""Exercise production resume routing and cache provenance without accounts or models.

Extracts the real Vault entry points, token serialization/validation, slicing loops,
and hosted cache/origin selectors. Frontier calls terminate with a synthetic usage
limit; preferences, connector metadata, and publication are inert fixtures. Only
synthetic staging files are written, inside an automatically removed temp folder.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    depth = 0
    for opening in range(start, len(source)):
        depth += (source[opening] == '(') - (source[opening] == ')')
        if source[opening] == '{' and depth == 0:
            break
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


generator = (APP / 'Vault/VaultGenerator.swift').read_text()
cloud = (APP / 'Vault/VaultCloud.swift').read_text()
census = (APP / 'Cloud/ConnectorCensus.swift').read_text()
registry = (APP / 'Cloud/ConnectorRegistry.swift').read_text()
production = 'actor VaultGenerator {\n' + '\n'.join(declaration(generator, name) for name in [
    'struct Result:', 'enum Progress:', 'struct ResumeToken:', 'enum VaultError:',
    'func runCodexInStaging(', 'func generate(', 'private func generatePinned(',
]) + r'''
    static var vaultRoot: URL { Fixture.root.appendingPathComponent("Knowledge") }
    static var stagingParent: URL { Fixture.root }
    static let stagingPrefix = ".sentientos-vault-staging-"
    static func newStagingDir(seedFrom: URL? = nil) throws -> URL {
        let url = stagingParent.appendingPathComponent(stagingPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func census(of directory: URL) -> (notes: Int, folders: Int) { (1, 0) }
    static func vaultFingerprint(_ directory: URL) -> String { "fixture-fingerprint" }
    static func diagnosticShape(_ directory: URL) -> (files: Int, bytes: Int, indexPresent: Bool)? { nil }
    static func swapStagingIntoVault(_ directory: URL) throws { fatalError("Fixture never publishes") }
    private let vaultPromptCore = "BUILD"
    private let agenticOutputInstructions = ""
    static func corpusMessage(_ notes: [CloudNote], partial: Bool, closing: String) -> String {
        notes.map(\.sourceID).joined(separator: ",")
    }
}
actor VaultCloud {
    private var createResume: VaultGenerator.ResumeToken?
    private var updateResume: VaultGenerator.ResumeToken?
    private(set) var lastConsumedSourceIDs: Set<String> = []
    private static let createResumeKey = "vault.create.resume"
    private static let updateResumeKey = "vault.update.resume"
    static func updatePrompt(skeleton: String, notes: [CloudNote]) -> String { "UPDATE " + notes.map(\.sourceID).joined(separator: ",") }
    static func skeleton(of: URL) -> String { "" }
    private func markDirty() async { fatalError("Fixture never publishes") }
''' + '\n'.join(declaration(cloud, name) for name in [
    'init()', 'private static func loadResume(', 'private func setCreateResume(',
    'private func setUpdateResume(', 'private static func mailHashes(',
    'private func validatedResume(', 'private static func persistResume(',
    'enum CloudError:', 'func create(', 'private func createPinned(',
    'func update(', 'private func updatePinned(',
]) + '\n}\n'
production += 'enum ConnectorCensus { struct DetectedConnector { enum Origin { case claude, chatgpt, direct } }\n' + declaration(census, 'private static func storageKey(').replace('private static', 'static', 1) + '\n}\n'
production += 'enum ConnectorRegistry {\n' + '\n'.join(declaration(registry, name) for name in ['static func readOrigin(', 'static func readGenerationKey(']) + '\n}\n'

FIXTURE = r'''
import Foundation
enum Fixture {
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[1], isDirectory: true)
}
final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] as? Data }
    func integer(forKey key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key] as? Int ?? 0 }
    func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] as? String }
    func set(_ value: Any, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
    func removeObject(forKey key: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key) }
    func reset() { lock.lock(); defer { lock.unlock() }; values.removeAll() }
}
enum ModelBackend: String, Sendable, CaseIterable {
    case chatgpt, claude, custom
    @TaskLocal static var runOverride: Self?
    static var current: Self { runOverride ?? Self(rawValue: UserDefaults.standard.string(forKey: "backend") ?? "") ?? .chatgpt }
}
enum CodexRuntime {
    static let sessionScope = "private-codex-v1"
    static var accountIdentity: String? { UserDefaults.standard.string(forKey: "account") }
}
enum DirectMCPStore {
    struct Connection { let id = "fixture-direct"; let generation = 3 }
    static func connection(_ slug: String) -> Connection? { slug == "direct-fixture" ? Connection() : nil }
}
enum SourceKind: String, Codable, Sendable { case file, appleMail }
struct CloudNote: Codable, Sendable {
    var kind = SourceKind.file
    let sourceID: String
    var text = "retained summary"
    var title: String? = nil
    var itemDate: Date? = nil
}
enum AppleMailSource { static func digest(_ string: String) -> String { string } }
enum AppleMailEvidence {
    static func validatedCloud(_ notes: [CloudNote]) async -> [CloudNote] {
        // Simulate a settings change while the attempt crosses its first await.
        if let next = UserDefaults.standard.string(forKey: "switch-backend") {
            UserDefaults.standard.set(next, forKey: "backend")
        }
        await Task.yield()
        return notes
    }
}
enum CodexCLI {
    struct Invocation: Sendable {
        let prompt: String
        enum ClaudeModel { case opus }; var claudeModel: ClaudeModel? = nil
        enum Sandbox { case workspaceWrite }; var sandbox: Sandbox = .workspaceWrite
        enum Effort { case high }; var effort: Effort = .high
        var feature = ""; var cwd: String? = nil; var timeout: Double = 60
        var resumeSessionID: String? = nil; var diag: [String: String] = [:]
    }
    struct Envelope: Sendable { var inputTokens: Int? = nil; var outputTokens: Int? = nil }
    enum CLIError: Error { case usageLimit(message: String, sessionID: String?) }
}
actor FrontierRun {
    static let shared = FrontierRun()
    private var calls: [(CodexCLI.Invocation, ModelBackend)] = []
    static func run(_ invocation: CodexCLI.Invocation, onLine: (@Sendable (String) -> Void)?) async throws -> CodexCLI.Envelope {
        await shared.record(invocation, backend: ModelBackend.current)
        throw CodexCLI.CLIError.usageLimit(message: "fixture", sessionID: "fresh-session")
    }
    private func record(_ invocation: CodexCLI.Invocation, backend: ModelBackend) { calls.append((invocation, backend)) }
    func reset() { calls = [] }
    func onlyCall() -> (CodexCLI.Invocation, ModelBackend) { precondition(calls.count == 1); return calls[0] }
}
enum CorpusSlicer {
    static let budget = 1
    static func slice(_ notes: [CloudNote]) -> [[CloudNote]] { notes.map { [$0] } }
    static func saveCorpus(_ notes: [CloudNote], in directory: URL) throws {
        try JSONEncoder().encode(notes).write(to: directory.appendingPathComponent("corpus.json"))
    }
    static func loadCorpus(from directory: URL) -> [CloudNote]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("corpus.json")) else { return nil }
        return try? JSONDecoder().decode([CloudNote].self, from: data)
    }
    static func deleteCorpus(in directory: URL) { fatalError("Fixture never publishes") }
}
@MainActor final class VaultActivity { static let shared = VaultActivity(); let editorBusy = false }
enum Analytics { static func signal(_ name: String) {} }
enum Diagnostics {
    enum Event { case vaultFailed, vaultOutputInvalid }; enum Phase { case publish, validate }
    enum Count { case filesBefore, filesAfter, bytesBefore, bytesAfter, items }
    static func report(_ event: Event, phase: Phase, reason: String, error: Error? = nil, counts: [Count: Int] = [:]) {}
}
enum CrashReporting { static func diagnosticBreadcrumb(_ name: String, data: [String: String]) {} }
func Log(_ line: String) {}
func ErrorLabel(_ error: Error) -> String { "fixture" }

@main struct Harness {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); checks += 1; print("PASS \(name)")
        }
        let defaults = UserDefaults.standard
        let vault = VaultGenerator.vaultRoot
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let knowledge = vault.appendingPathComponent("Existing.md")
        try "User knowledge retained".write(to: knowledge, atomically: true, encoding: .utf8)
        let staging = try VaultGenerator.newStagingDir()
        let notes = [CloudNote(sourceID: "retained-first"), CloudNote(sourceID: "retained-second")]
        try CorpusSlicer.saveCorpus(notes, in: staging)
        let legacyJSON = #"{"sessionID":"old-session","stagingPath":"STAGING","sliceIndex":1,"inputSourceIDs":["obsolete-input"]}"#.replacingOccurrences(of: "STAGING", with: staging.path)
        let legacy = try JSONDecoder().decode(VaultGenerator.ResumeToken.self, from: Data(legacyJSON.utf8))
        for backend in ModelBackend.allCases {
            check(legacy.matchingRuntime(backend) == nil, "unscoped \(backend.rawValue) session rejected")
            var current = legacy; current.sessionScope = VaultGenerator.ResumeToken.scope(for: backend)
            let decoded = try JSONDecoder().decode(VaultGenerator.ResumeToken.self, from: JSONEncoder().encode(current))
            check(decoded.matchingRuntime(backend)?.sessionID == "old-session", "scoped \(backend.rawValue) survives restart")
            for other in ModelBackend.allCases where other != backend {
                check(decoded.matchingRuntime(other) == nil, "\(backend.rawValue) cannot resume on \(other.rawValue)")
            }
        }
        var formerPrivate = legacy; formerPrivate.sessionScope = "chatgpt:former-private-home"
        check(formerPrivate.matchingRuntime(.chatgpt) == nil, "former private home session rejected")

        for operation in ["generate", "create", "update"] {
            for matching in [false, true] {
                defaults.reset(); defaults.set("chatgpt", forKey: "backend")
                defaults.set("Saved task transcript", forKey: "sidekick.history")
                var token = legacy
                if matching { token.sessionScope = VaultGenerator.ResumeToken.scope(for: .chatgpt) }
                let key = "vault.\(operation == "update" ? "update" : "create").resume"
                defaults.set(try JSONEncoder().encode(token), forKey: key)
                await FrontierRun.shared.reset()
                do {
                    switch operation {
                    case "generate": _ = try await VaultGenerator().generate(notes: notes, resume: token)
                    case "create": _ = try await VaultCloud().create(notes: notes)
                    default: _ = try await VaultCloud().update(notes: notes)
                    }
                    preconditionFailure("Fixture must hit usage limit")
                } catch let VaultGenerator.VaultError.usageLimit(_, saved) {
                    check(saved.sessionScope == VaultGenerator.ResumeToken.scope(for: .chatgpt), "direct build stamps runtime scope")
                } catch VaultCloud.CloudError.usageLimit { }
                let (invocation, backend) = await FrontierRun.shared.onlyCall()
                check(backend == .chatgpt && invocation.resumeSessionID == (matching ? "old-session" : nil), "\(operation) \(matching ? "matching" : "legacy") resume routing")
                if !matching {
                    check(invocation.diag["slice_index"] == "0" && invocation.prompt.contains("retained-first"), "\(operation) restarts unfinished first slice")
                }
                if operation != "generate" {
                    let saved = try JSONDecoder().decode(VaultGenerator.ResumeToken.self, from: defaults.data(forKey: key)!)
                    check(saved.sessionScope == VaultGenerator.ResumeToken.scope(for: .chatgpt), "\(operation) persists new runtime scope")
                    if !matching { check(saved.inputSourceIDs == notes.map(\.sourceID), "\(operation) retains all current summaries") }
                }
                check(try String(contentsOf: knowledge, encoding: .utf8) == "User knowledge retained" && defaults.string(forKey: "sidekick.history") == "Saved task transcript", "\(operation) preserves live knowledge and task history")
            }
        }
        for operation in ["create", "update"] {
            defaults.reset(); defaults.set("chatgpt", forKey: "backend"); defaults.set("claude", forKey: "switch-backend")
            await FrontierRun.shared.reset()
            do {
                if operation == "create" { _ = try await VaultCloud().create(notes: notes) }
                else { _ = try await VaultCloud().update(notes: notes) }
                preconditionFailure("Fixture must hit usage limit")
            } catch VaultCloud.CloudError.usageLimit { }
            let (_, backend) = await FrontierRun.shared.onlyCall()
            check(backend == .chatgpt && ModelBackend.current == .claude, "\(operation) pins backend across settings change")
        }

        defaults.reset()
        check(ConnectorCensus.storageKey(for: .chatgpt) == nil, "signed out census cannot reuse any prior account")
        check(ConnectorCensus.storageKey(for: .claude) == "mcp.connectors.claude", "Claude census key preserved")
        defaults.set("account-a", forKey: "account")
        let cacheA = ConnectorCensus.storageKey(for: .chatgpt)!
        check(cacheA == "mcp.connectors.chatgpt.private-codex-v1.account-a", "new runtime census excludes legacy namespaces")
        let originA = ConnectorRegistry.readOrigin(slug: "gmail", backend: .chatgpt)
        defaults.set("account-b", forKey: "account")
        check(ConnectorCensus.storageKey(for: .chatgpt) != cacheA && ConnectorRegistry.readOrigin(slug: "gmail", backend: .chatgpt) != originA, "account changes invalidate census and read origin")
        check(originA.contains(CodexRuntime.sessionScope) && originA != "v1:chatgpt:0", "new runtime invalidates former Google and identity cache origin")
        defaults.set(4, forKey: ConnectorRegistry.readGenerationKey("gmail", "chatgpt"))
        check(ConnectorRegistry.readOrigin(slug: "gmail", backend: .chatgpt).hasSuffix(":4"), "reconnect generation remains effective")
        check(ConnectorRegistry.readOrigin(slug: "gmail", backend: .claude) == "v1:claude:0", "Claude read origin preserved")
        check(ConnectorRegistry.readOrigin(slug: "direct-fixture", backend: .chatgpt) == "direct:fixture-direct:3", "direct connector origin preserved")
        print("Checked \(checks) private runtime session/cache cases; failures=0")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='sentient-private-session-') as directory:
    root = Path(directory)
    source = root / 'Fixture.swift'
    source.write_text(FIXTURE + '\n' + production)
    binary = root / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True, timeout=30)
