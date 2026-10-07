#!/usr/bin/env python3
"""Exercise Google read origins and the mailbox-processing collection hook.

Only source reads and the store actor are fixtures, controlled with continuations.
An in-memory spy records the processing hook before each read. No prompts, accounts,
preferences, network requests, or disk-backed data are used.
"""
from pathlib import Path
import subprocess
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"


def declaration(source, signature):
    start = source.index(signature)
    depth = 0
    opening = start
    for opening in range(start, len(source)):
        depth += (source[opening] == '(') - (source[opening] == ')')
        if source[opening] == '{' and depth == 0:
            break
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


production = []
for service, count_label in [('Gmail', 'Weeks'), ('Calendar', 'Months')]:
    source = (APP / 'Sources' / f'{service}Connect.swift').read_text()
    names = ['private struct ReadResult', 'enum Progress', 'static func runInitial(',
             'private static func readInitial(', 'static func runIterative(', 'private static func readIterative(']
    if service == 'Gmail':
        names += ['private struct Window', 'private struct WindowResult']
    methods = '\n'.join(declaration(source, name) for name in names)
    initial_line = next(line.strip() for line in source.splitlines() if f'let initial{count_label} =' in line)
    bucket_line = next(line.strip() for line in source.splitlines() if 'let bucketKey =' in line)
    shared = f'''
    {bucket_line}
    {initial_line}
    enum {service}Error: Error {{ case dateMath }}
    private static func label(_ date: Date) -> String {{ "fixture" }}
    private static func draft(_ result: ReadResult, itemDate: Date, label: String) -> NoteDraft {{ NoteDraft() }}
    '''
    if service == 'Gmail':
        shared += '''
        private static func read(prompt: String) async throws -> ReadResult? { await ReadGate.shared.read(); return nil }
        private static func weeklyPrompt(query: String, label: String) -> String { query }
        private static func qDate(_ date: Date) -> String { "fixture" }
        '''
    else:
        shared += '''
        private static func read(prompt: String, window: DateInterval) async throws -> ReadResult? { await ReadGate.shared.read(); return nil }
        private static func readPrompt(range: String, label: String) -> String { range }
        private static func iso(_ date: Date) -> String { "fixture" }
        '''
    production.append(f'enum {service}Connect {{\n{shared}\n{methods}\n}}')
source = (APP / 'Sources/GoogleSourceRead.swift').read_text()
production.append('enum GoogleSourceRead { enum Failure: Error { case storage }\n' +
                  declaration(source, 'static func commit(') + '\n' + declaration(source, 'static func origin(') + '\n}')
mcp_source = (APP / 'Sources/MCPSource.swift').read_text()
mcp_run = declaration(mcp_source, 'static func run(slug: String, mode: ReadMode,')
assert mcp_run.count('HostedConnectorSetup.processingStarted(') == 1
assert (mcp_run.index('let backend = ModelBackend.current') <
        mcp_run.index('ModelBackend.$runOverride.withValue(backend)') <
        mcp_run.index('HostedConnectorSetup.processingStarted(slug: slug, backend: backend)') <
        mcp_run.index('try requireReadable(slug)'))
for entrypoint in ('static func runInitial(', 'static func runIterative('):
    assert 'try await run(slug: slug,' in declaration(mcp_source, entrypoint)
FIXTURE = r'''
import Foundation

enum ModelBackend: String, Sendable {
    case chatgpt, claude
    @TaskLocal static var runOverride: Self?
    static var current: Self { runOverride ?? BackendPreference.shared.get() }
}
final class BackendPreference: @unchecked Sendable {
    static let shared = BackendPreference()
    private let lock = NSLock()
    private var backend: ModelBackend = .chatgpt
    func set(_ value: ModelBackend) { lock.lock(); defer { lock.unlock() }; backend = value }
    func get() -> ModelBackend { lock.lock(); defer { lock.unlock() }; return backend }
}
enum MCPSource { enum MCPError: Error { case clockMovedBackwards, connectionChanged } }
struct NoteDraft: Sendable {}
struct ItemKey: Sendable, Equatable { let order: TimeInterval; let tiebreak: String }
struct Checkpoint: Sendable { let mark: ItemKey; let origin: String }
func Log(_ text: String) {}

final class ProcessingSpy: @unchecked Sendable {
    struct Event {
        let kind: String
        let slug: String?
        let backend: ModelBackend
        let pinned: Bool
    }
    static let shared = ProcessingSpy()
    private let lock = NSLock()
    private var events: [Event] = []
    func reset() { lock.lock(); defer { lock.unlock() }; events = [] }
    func record(kind: String, slug: String? = nil, backend: ModelBackend = .current) {
        lock.lock(); defer { lock.unlock() }
        events.append(Event(kind: kind, slug: slug, backend: backend,
                            pinned: ModelBackend.runOverride == backend))
    }
    func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
}
@MainActor enum HostedConnectorSetup {
    static func processingStarted(slug: String, backend: ModelBackend = .current) {
        ProcessingSpy.shared.record(kind: "hook", slug: slug, backend: backend)
    }
}

final class Generation: @unchecked Sendable {
    static let shared = Generation()
    private let lock = NSLock()
    private var number = 0
    func reset() { lock.lock(); defer { lock.unlock() }; number = 0 }
    func bump() { lock.lock(); defer { lock.unlock() }; number += 1 }
    func origin() -> String { lock.lock(); defer { lock.unlock() }; return "fixture:\(number)" }
}
enum ConnectorRegistry {
    static func readOrigin(slug: String, backend: ModelBackend) -> String { Generation.shared.origin() }
}
actor ReadGate {
    static let shared = ReadGate()
    private var paused = false
    private var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func reset(paused: Bool) {
        precondition(waiters.isEmpty); self.paused = paused; calls = 0; started = nil
        ProcessingSpy.shared.reset()
    }
    func read() async {
        ProcessingSpy.shared.record(kind: "read")
        calls += 1
        started?.resume(); started = nil
        if paused { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilStarted() async { if calls == 0 { await withCheckedContinuation { started = $0 } } }
    func release() { paused = false; let held = waiters; waiters = []; for waiter in held { waiter.resume() } }
    func count() -> Int { calls }
}
actor CycleStore {
    static let shared = CycleStore()
    enum Outcome { case saved, diskFull }
    private var checkpoint: Checkpoint? = Checkpoint(mark: ItemKey(order: 1, tiebreak: ""), origin: "fixture:0")
    private var commits = 0
    private var paused = false
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var blockedCommit: CheckedContinuation<Void, Never>?
    func reset(paused: Bool = false, checkpointPresent: Bool = true) {
        precondition(blockedCommit == nil)
        checkpoint = checkpointPresent ? Checkpoint(mark: ItemKey(order: 1, tiebreak: ""), origin: "fixture:0") : nil
        commits = 0; self.paused = paused; entered = false; enteredWaiter = nil
    }
    func mcpCheckpoint(_ bucket: String) throws -> Checkpoint? { checkpoint }
    func commitMCPRead(bucketKey: String, notes: [NoteDraft], through mark: ItemKey,
                       origin: String, replaceNotes: Bool) async -> Outcome {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        if paused { await withCheckedContinuation { blockedCommit = $0 } }
        checkpoint = Checkpoint(mark: mark, origin: origin); commits += 1
        return .saved
    }
    func waitUntilCommitEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func releaseCommit() { paused = false; blockedCommit?.resume(); blockedCommit = nil }
    func commitCount() -> Int { commits }
}

@main struct Harness {
    enum Source: String, CaseIterable, Sendable {
        case gmail, calendar
        var initialReads: Int { self == .gmail ? 4 : 12 }
        func read(initial: Bool) async throws {
            switch self {
            case .gmail:
                if initial { _ = try await GmailConnect.runInitial() }
                else { _ = try await GmailConnect.runIterative() }
            case .calendar:
                if initial { _ = try await CalendarConnect.runInitial() }
                else { _ = try await CalendarConnect.runIterative() }
            }
        }
    }
    static func main() async throws {
        var checks = 0
        for source in Source.allCases {
            for initial in [false, true] {
                Generation.shared.reset()
                await CycleStore.shared.reset()
                await ReadGate.shared.reset(paused: false)
                try await source.read(initial: initial)
                let baseline = try await CycleStore.shared.mcpCheckpoint(source.rawValue)!
                precondition(baseline.origin == "fixture:0" && baseline.mark.order > 1)
                let baselineReads = await ReadGate.shared.count()
                precondition(baselineReads == (initial ? source.initialReads : 1))
                checks += 1; print("PASS \(source.rawValue) \(initial ? "initial" : "iterative") unchanged origin commits")

                Generation.shared.reset()
                await CycleStore.shared.reset()
                await ReadGate.shared.reset(paused: true)
                let reading = Task { try await source.read(initial: initial) }
                await ReadGate.shared.waitUntilStarted()
                Generation.shared.bump()
                await ReadGate.shared.release()
                do { try await reading.value; fatalError("Changed read origin was accepted") }
                catch MCPSource.MCPError.connectionChanged {}
                let previous = try await CycleStore.shared.mcpCheckpoint(source.rawValue)!
                let commits = await CycleStore.shared.commitCount()
                precondition(previous.origin == "fixture:0" && previous.mark.order == 1 && commits == 0)
                await ReadGate.shared.reset(paused: false)
                try await source.read(initial: false)
                let backfilled = try await CycleStore.shared.mcpCheckpoint(source.rawValue)!
                let backfillReads = await ReadGate.shared.count()
                precondition(backfillReads == source.initialReads && backfilled.origin == "fixture:1")
                checks += 1; print("PASS \(source.rawValue) \(initial ? "initial" : "iterative") pending-read invalidation preserves checkpoint and backfills")
            }
            Generation.shared.reset()
            await CycleStore.shared.reset(paused: true)
            await ReadGate.shared.reset(paused: false)
            let committing = Task { try await source.read(initial: false) }
            await CycleStore.shared.waitUntilCommitEntered()
            Generation.shared.bump()
            await CycleStore.shared.releaseCommit()
            try await committing.value
            let oldGeneration = try await CycleStore.shared.mcpCheckpoint(source.rawValue)!
            precondition(oldGeneration.origin == "fixture:0" && Generation.shared.origin() == "fixture:1")
            await ReadGate.shared.reset(paused: false)
            try await source.read(initial: false)
            let final = try await CycleStore.shared.mcpCheckpoint(source.rawValue)!
            let fullReads = await ReadGate.shared.count()
            precondition(fullReads == source.initialReads && final.origin == "fixture:1")
            checks += 1; print("PASS \(source.rawValue) store-actor invalidation retains captured origin and backfills")
        }
        for backend in [ModelBackend.chatgpt, .claude] {
            BackendPreference.shared.set(backend)
            for source in Source.allCases {
                for mode in ["initial", "iterative", "missing-checkpoint", "changed-origin"] {
                    Generation.shared.reset()
                    await CycleStore.shared.reset(checkpointPresent: mode != "missing-checkpoint")
                    await ReadGate.shared.reset(paused: false)
                    if mode == "changed-origin" { Generation.shared.bump() }
                    // The production entrypoint must establish its own pinned scope.
                    // Do not give it an outer TaskLocal override that could mask a missing one.
                    try await source.read(initial: mode == "initial")
                    let events = ProcessingSpy.shared.snapshot()
                    let hooks = events.filter { $0.kind == "hook" }
                    let reads = events.filter { $0.kind == "read" }
                    precondition(reads.count == (mode == "iterative" ? 1 : source.initialReads))
                    precondition(reads.allSatisfy { $0.backend == backend && $0.pinned })
                    if source == .gmail {
                        precondition(hooks.count == 1 && events.first?.kind == "hook")
                        precondition(hooks[0].slug == "gmail" && hooks[0].backend == backend && hooks[0].pinned)
                    } else {
                        precondition(hooks.isEmpty)
                    }
                    checks += 1
                    print("PASS \(backend.rawValue) \(source.rawValue) \(mode) \(source == .gmail ? "collect hook once before reads" : "no collect hook")")
                }
            }
        }
        print("Checked \(checks) Google read origin and processing-hook cases; failures=0")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='sentient-google-read-origin-') as directory:
    root = Path(directory)
    swift = root / 'Fixture.swift'
    swift.write_text(FIXTURE + '\n' + '\n'.join(production))
    binary = root / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
