#!/usr/bin/env python3
"""Exercise actual file ingestion, SwiftData persistence and ProactiveCycle without real models.

The writer/provider collaborators are synthetic; production input identity, checkpoint migration,
cycle sequencing and cleanup run unchanged. Each scenario uses an isolated temporary directory.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def member(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


MAIN = r'''
@main enum CheckpointRecoveryTests {
    static func seed(_ store: CycleStore) async {
        for folder in ["Documents", "Project"] {
            let note = NoteDraft(kind: .file, sourceID: "file:synthetic", folder: folder,
                itemDate: Date(timeIntervalSince1970: 1), text: "Synthetic retained context",
                title: "Synthetic title", reminderFlagged: false)
            Fixture.check(await store.advance(bucketKey: folder, note: note, to: ItemKey(order: 1)) == .saved,
                          "legacy variant is durably seeded")
        }
    }
    static func main() async throws {
        let phase = CommandLine.arguments[1], root = Fixture.root
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("queue.store")))
        let store = CycleStore(modelContainer: container)
        try await CycleStore.$acceptanceStore.withValue(store) {
            try await InitialAnalysisRecovery.$replayCloudStages.withValue(true) {
                if phase.hasPrefix("reader") {
                    let parent = root.appendingPathComponent("Documents"), child = parent.appendingPathComponent("Project"), other = root.appendingPathComponent("Other")
                    if phase != "reader-reopen" {
                        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
                        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                        for file in [child.appendingPathComponent("same-name.md"), other.appendingPathComponent("same-name.md")] {
                            try "Synthetic useful context for a project".write(to: file, atomically: true, encoding: .utf8)
                        }
                    }
                    let files = FilesConnector(roots: [.custom(parent), .custom(child), .custom(child), .custom(other)])
                    Fixture.check(try files.buckets(since: [:]).count == 3, "duplicate root selections do not reset the same bucket twice")
                    if phase == "reader-junk" { Fixture.state.set("junk", true) }
                    if phase == "reader-error" { Fixture.state.set("inferenceFailure", true) }
                    if phase == "reader-cancel" {
                        Fixture.state.set("slow", true)
                        let task = Task { await IterativeRun(modelPath: "synthetic", store: store).run([files], mode: .auto) }
                        while Fixture.state.count("inferences") == 0 { try await Task.sleep(for: .milliseconds(1)) }
                        task.cancel(); _ = await task.value
                        Fixture.check(await store.notes().isEmpty, "cancellation does not commit a summary")
                        Fixture.check(await store.pointerState("file:custom:" + parent.path) == nil, "cancellation does not advance the file marker")
                        Fixture.state.set("slow", false)
                    }
                    let before = Fixture.state.count("inferences")
                    let result = await IterativeRun(modelPath: "synthetic", store: store).run([files], mode: phase == "reader-reset" ? .initial : .auto)
                    let expected = phase == "reader-reopen" ? 0 : 2
                    Fixture.check(Fixture.state.count("inferences") - before == expected, "one model attempt per file path despite nested roots; unrelated same-name file remains distinct")
                    Fixture.check(result.done == expected && result.total == expected, "processed counts exclude repeat root discoveries")
                    let notes = await store.notes()
                    Fixture.check(notes.count == (["reader-junk", "reader-error"].contains(phase) ? 0 : 2), "only one survivor row per analyzed file, and rejected items persist no notes")
                    for folder in [parent, child, other] {
                        let source = FilesSource(root: folder, label: folder.lastPathComponent)
                        let mark = await store.pointerState(source.cursorKey)
                        Fixture.check(mark != nil && mark?.floor == nil, "each selected root completes its own durable progress")
                    }
                    if phase == "reader-error" { Fixture.check(result.failed == 2, "an overlapping root does not count an inference failure twice") }
                    if phase == "reader-cycle" {
                        Fixture.check(await ProactiveCycle().run(progress: { _ in }) == nil,
                                      "real file reader output completes knowledge publication and its recovery checkpoint")
                        Fixture.check(Fixture.state.count("research") == 1 && Fixture.state.count("writes") == 1,
                                      "overlapping folders reach Proactive after one knowledge write")
                        Fixture.check(await store.notes().isEmpty, "full cycle consumes the exact summaries produced by file ingestion")
                    }
                    return
                }
                if phase != "cycle-reopen" { await seed(store) }
                let checkpoint = VaultMergeCheckpoint()
                if phase == "cycle-new-version" { Fixture.state.set("newVersionDuringWrite", true) }
                if phase == "cycle-retry" || phase == "cycle-save-for-reopen" { Fixture.state.set("judgeFailure", true) }
                if phase == "cycle-writer-failure" {
                    Fixture.state.set("writerFailure", true)
                    try FileManager.default.createDirectory(at: VaultGenerator.vaultRoot, withIntermediateDirectories: true)
                    try "# Pre-existing knowledge".write(to: VaultGenerator.vaultRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                }
                if phase == "cycle-storage-failure" {
                    let outside = root.appendingPathComponent("unchanged.json")
                    try "keep".write(to: outside, atomically: true, encoding: .utf8)
                    try FileManager.default.createSymbolicLink(at: checkpoint.file, withDestinationURL: outside)
                }
                if phase == "cycle-cleanup-failure" { await store.failNextConsumedCleanupForTesting() }
                let cycle = ProactiveCycle()
                let failure = await cycle.run(progress: { _ in })
                let notesAfterAttempt = await store.notes()
                if phase == "cycle-storage-failure" {
                    Fixture.check(failure?.knowledgePublished == true && failure?.stage == .vault, "real recovery I/O failure preserves a verified publication result")
                    Fixture.check(verifiedInitialReadiness(failure: failure, diskFull: false), "actual coordinator condition unlocks saved knowledge despite later bookkeeping failure")
                    Fixture.check(Fixture.state.count("KnowledgeBase.recoveryFailed") == 1 && Fixture.state.count("KnowledgeBase.failed") == 0, "published knowledge is not counted as a failed build")
                    Fixture.check(Fixture.state.count("judges") == 0 && notesAfterAttempt.count == 2, "unsafe storage is still an honest failure and retains pending input")
                    Fixture.check(try String(contentsOf: root.appendingPathComponent("unchanged.json"), encoding: .utf8) == "keep", "checkpoint does not follow or alter a symlink target")
                } else if phase == "cycle-writer-failure" {
                    Fixture.check(failure != nil && failure?.knowledgePublished == false, "writer failure is not certified as successful publication")
                    Fixture.check(!verifiedInitialReadiness(failure: failure, diskFull: false), "an old README cannot certify the failed initial publication")
                    Fixture.check(notesAfterAttempt.count == 2, "failed writer preserves all pending variants")
                } else if phase == "cycle-save-for-reopen" {
                    Fixture.check(failure?.stage == .deciding, "post-publication failure retains a recovery checkpoint for fresh-process test")
                    Fixture.check(FileManager.default.fileExists(atPath: checkpoint.file.path) && notesAfterAttempt.count == 2, "published versions and pending notes survive until the next process")
                } else {
                    if phase == "cycle-retry" || phase == "cycle-cleanup-failure" {
                        let pending = await store.notes()
                        Fixture.check(pending.count == 2 && FileManager.default.fileExists(atPath: checkpoint.file.path), "later-stage or cleanup failure retains notes and merge coverage")
                        Fixture.state.set("diagnosticFailed", false)
                        Fixture.check(await cycle.run(progress: { _ in }) == nil, "retry completes the remaining cycle")
                    } else { Fixture.check(failure == nil, "conflicting legacy rows complete through the actual cycle") }
                    Fixture.check(Fixture.state.count("writes") == (phase == "cycle-reopen" ? 0 : 1), "completed exact input versions are not merged again on retry or relaunch")
                    Fixture.check(Fixture.state.count("research") > 0, "Proactive preparation is reached")
                    let remaining = await store.notes()
                    Fixture.check(remaining.count == (phase == "cycle-new-version" ? 1 : 0), "cleanup removes only the input versions actually consumed")
                    if phase == "cycle-new-version" { Fixture.check(remaining[0].text == "New unconsumed version", "same-source content arriving during publication stays pending") }
                    Fixture.check(!FileManager.default.fileExists(atPath: checkpoint.file.path), "successful cleanup retires the merge checkpoint")
                }
                Fixture.check(!verifiedInitialReadiness(failure: nil, diskFull: true), "disk-full never certifies initial completion")
                let fullDisk = CycleFailure(message: "Synthetic", kind: .diskFull, stage: .vault, reason: .unknown, knowledgePublished: true)
                Fixture.check(!verifiedInitialReadiness(failure: fullDisk, diskFull: false), "checkpoint disk-full classification remains a hard readiness failure")
            }
        }
        print("PASS \(Fixture.state.count("checks")) assertions for \(phase)")
    }
}
'''


def main():
    cloud = (APP / "Vault/VaultCloud.swift").read_text()
    cloud_note = member(cloud, "nonisolated struct CloudNote:")
    coordinator = (APP / "Ingestion/ProcessingCoordinator.swift").read_text()
    start = coordinator.index("        if request.fullCycle && knowledgeReady")
    end = coordinator.index("\n        let complete =", start)
    readiness = '''
@MainActor func verifiedInitialReadiness(failure: CycleFailure?, diskFull: Bool) -> Bool {
    struct Request { let fullCycle = true }
    struct Result { let progress: RunProgress; let failure: CycleFailure? }
    let request = Request(), defaults = UserDefaults.standard
    var progress = RunProgress(); progress.diskFull = diskFull
    let result = Result(progress: progress, failure: failure)
    var initialComplete = false
    let knowledgeReady = true
''' + coordinator[start:end] + '''
    return initialComplete
}
'''
    environment = dict(os.environ)
    for candidate in [Path("/Applications/Xcode-beta.app"), Path("/Applications/Xcode.app")]:
        if candidate.exists():
            environment["DEVELOPER_DIR"] = str(candidate / "Contents/Developer")
            break
    platform = Path(environment["DEVELOPER_DIR"]) / "Platforms/MacOSX.platform/Developer"
    with tempfile.TemporaryDirectory(prefix="sentient-checkpoint-regression-") as temporary:
        root = Path(temporary)
        fixture = root / "Tests.swift"
        fixture.write_text((ROOT / "Scripts/Fixtures/CheckpointRecovery.swift").read_text() + "\n" + cloud_note + readiness + MAIN)
        binary = root / "tests"
        sources = [APP / name for name in [
            "Sources/DataSource.swift", "Sources/FilesSource.swift", "Ingestion/Connectors/FilesConnector.swift",
            "Ingestion/Connector.swift", "Ingestion/ItemKey.swift", "Ingestion/RunProgress.swift", "Ingestion/IterativeRun.swift",
            "Ingestion/CycleStore.swift", "Ingestion/InitialAnalysisRecovery.swift", "Sources/GmailReadState.swift",
            "Sources/HostedConnectorReadState.swift", "Vault/VaultInput.swift", "Vault/VaultValidation.swift",
            "Proactive/VaultMergeCheckpoint.swift", "Proactive/ProactiveCycle.swift"]]
        subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-parse-as-library", "-default-isolation", "MainActor", "-swift-version", "5",
                        "-external-plugin-path", f"{platform}/usr/lib/swift/host/plugins#{platform}/usr/bin/swift-plugin-server",
                        *map(str, sources), str(fixture), "-o", str(binary)], check=True, env=environment)
        phases = ["reader", "reader-reopen", "reader-reset", "reader-junk", "reader-error", "reader-cancel", "reader-cycle",
                  "cycle-legacy", "cycle-retry", "cycle-new-version", "cycle-storage-failure", "cycle-writer-failure",
                  "cycle-cleanup-failure", "cycle-save-for-reopen", "cycle-reopen"]
        for phase in phases:
            shared = "reader" if phase in ["reader", "reader-reopen", "reader-reset"] else "cycle-save-for-reopen" if phase == "cycle-reopen" else phase
            data = root / shared
            data.mkdir(exist_ok=True)
            subprocess.run([str(binary), phase, str(data)], check=True, env=environment, timeout=40)


if __name__ == "__main__":
    main()
