#!/usr/bin/env python3
"""Exercise generic hosted commits and the real Google caller with disk-backed SwiftData.

The complete production store is compiled unchanged. Shared synthetic collaborators
come from the Gmail recovery fixture; the Google commit body is extracted verbatim.
Only unique temporary stores are opened. No provider, account or app data is used.
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


FIXTURE = r'''
nonisolated enum BeforeStore {
    @TaskLocal static var signal: QueueGate?
}
nonisolated func waitForGate(_ gate: QueueGate) {
    precondition(gate.entered.wait(timeout: .now() + 10) == .success, "Fixture queue gate timed out")
}
@main enum HostedReadStorageTests {
    nonisolated static let oldDate = Date(timeIntervalSince1970: 1_790_000_000)
    nonisolated static let newDate = Date(timeIntervalSince1970: 1_792_843_421)
    nonisolated static let bucket = "calendar"
    nonisolated static let oldMark = ItemKey(order: oldDate.timeIntervalSince1970, tiebreak: "prior")
    nonisolated static let newMark = ItemKey(order: newDate.timeIntervalSince1970, tiebreak: "")
    nonisolated static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw TestFailure.message(message) }
        print("PASS \(message)")
    }
    nonisolated static func makeStore(_ path: URL) throws -> CycleStore {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: path))
        return CycleStore(modelContainer: container)
    }
    nonisolated static func note(_ id: String) -> NoteDraft {
        NoteDraft(kind: .file, sourceID: id, folder: "Fixture", itemDate: newDate,
                  text: "Synthetic safe summary \(id)", title: nil, reminderFlagged: false)
    }
    static func assertOld(_ store: CycleStore, _ context: String) async throws {
        let notes = await store.notes().filter { $0.bucketKey == bucket }.map(\.sourceID)
        let checkpoint = try await store.mcpCheckpoint(bucket)
        try check(notes == ["old"] && checkpoint?.mark == oldMark && checkpoint?.origin == "fixture:0",
                  context + " retains old summary, checkpoint and origin")
    }
    static func seed(_ store: CycleStore) async throws {
        let saved = try await store.commitMCPRead(bucketKey: bucket, notes: [note("old")], through: oldMark,
                                                 origin: "fixture:0", replaceNotes: true)
        try check(saved == .saved, "baseline summary and checkpoint save together")
    }
    static func cancelQueued(_ store: CycleStore, googleCaller: Bool, replace: Bool) async throws {
        let gate = QueueGate(), checked = QueueGate()
        let holder = Task.detached { await store.holdForFixture(gate) }
        await Task.detached { waitForGate(gate) }.value
        // This signal occurs after the actual caller's cancellation check, before its actor hop.
        let queued = Task.detached {
            try await CycleStore.$acceptanceStore.withValue(store) {
                if googleCaller {
                    try await BeforeStore.$signal.withValue(checked) {
                        try await GoogleSourceRead.commit(bucket: bucket, notes: [note("new")], through: newDate,
                                                          origin: "fixture:0", replace: replace)
                    }
                } else {
                    try Task.checkCancellation()
                    checked.entered.signal()
                    _ = try await store.commitMCPRead(bucketKey: bucket, notes: [note("new")], through: newMark,
                                                      origin: "fixture:0", replaceNotes: replace)
                }
            }
        }
        // SwiftData can synchronously enqueue an actor hop on its context queue.
        // Cancel/release independently of MainActor, where the real caller runs.
        await Task.detached {
            waitForGate(checked)
            queued.cancel()
            gate.release.signal()
        }.value
        await holder.value
        do {
            try await queued.value
            throw TestFailure.message("Cancelled queued hosted commit succeeded")
        } catch is CancellationError {
            try check(true, "queued \(googleCaller ? "Google caller" : "store caller") replacement=\(replace) throws CancellationError")
        }
        try await assertOld(store, "queued cancellation")
    }
    static func main() async throws {
        let phase = CommandLine.arguments[1]
        let path = URL(fileURLWithPath: CommandLine.arguments[2])
        // ModelContext chooses its executor at creation. Construct off-main so holding
        // the store does not prevent the genuine MainActor Google caller from entering.
        let store = try await Task.detached { try makeStore(path) }.value
        if phase == "reopen" {
            try await assertOld(store, "fresh process after cancellation")
            return
        }
        try await seed(store)
        switch phase {
        case "cancel-store", "cancel-google":
            for replace in [false, true] {
                try await cancelQueued(store, googleCaller: phase == "cancel-google", replace: replace)
            }
        case "save-controls":
            // Caller source-origin failure remains distinct from a storage/cancellation error.
            Origin.shared.set("fixture:1")
            do {
                try await CycleStore.$acceptanceStore.withValue(store) {
                    try await GoogleSourceRead.commit(bucket: bucket, notes: [note("new")], through: newDate,
                                                      origin: "fixture:0", replace: true)
                }
                throw TestFailure.message("Changed source origin accepted")
            } catch MCPSource.MCPError.connectionChanged {
                try check(true, "Google caller rejects a changed source origin")
            }
            try await assertOld(store, "changed account")
            Origin.shared.set("fixture:0")
            await store.failNextMCPCommitForTesting()
            do {
                try await CycleStore.$acceptanceStore.withValue(store) {
                    try await GoogleSourceRead.commit(bucket: bucket, notes: [note("new")], through: newDate,
                                                      origin: "fixture:0", replace: true)
                }
                throw TestFailure.message("Injected disk-full replacement accepted")
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
                try check(true, "Google caller preserves the typed disk-full error")
            }
            try await assertOld(store, "failed replacement rollback")
            try await CycleStore.$acceptanceStore.withValue(store) {
                try await GoogleSourceRead.commit(bucket: bucket, notes: [note("new")], through: newDate,
                                                  origin: "fixture:0", replace: true)
            }
            let notes = await store.notes().filter { $0.bucketKey == bucket }.map(\.sourceID)
            let checkpoint = try await store.mcpCheckpoint(bucket)
            try check(notes == ["new"] && checkpoint?.mark == newMark,
                      "successful retry atomically replaces summary and advances its boundary")
        default: throw TestFailure.message("Unknown phase")
        }
    }
}
'''


def main():
    environment = dict(os.environ)
    if not environment.get("DEVELOPER_DIR"):
        for candidate in [Path("/Applications/Xcode-beta.app"), Path("/Applications/Xcode.app")]:
            if candidate.exists():
                environment["DEVELOPER_DIR"] = str(candidate / "Contents/Developer")
                break
    developer = Path(environment.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    collaborators = (ROOT / "Scripts/test_gmail_import_recovery.swift").read_text().split("@main enum GmailImportRecoveryTests")[0]
    collaborators = collaborators.replace(
        'static func origin(bucket: String) -> String { Origin.shared.get() }',
        'static func origin(bucket: String) -> String { BeforeStore.signal?.entered.signal(); return Origin.shared.get() }')
    commit = member((APP / "Sources/GoogleSourceRead.swift").read_text(), "static func commit(")
    # The app's default-isolation setting makes this method MainActor. Retain it
    # explicitly while the shared synthetic GoogleSourceRead type is nonisolated.
    caller = "extension GoogleSourceRead {\n@MainActor " + commit + "\n}\n"
    with tempfile.TemporaryDirectory(prefix="sentient-hosted-read-storage-") as directory:
        root = Path(directory)
        fixture = root / "HostedReadStorageFixture.swift"
        fixture.write_text(collaborators + caller + FIXTURE)
        binary = root / "hosted-read-storage"
        sources = [APP / "Ingestion/ItemKey.swift", APP / "Ingestion/CycleStore.swift",
                   APP / "Sources/GmailReadState.swift", APP / "Sources/GmailConnect.swift",
                   APP / "Ingestion/InitialAnalysisRecovery.swift", fixture]
        subprocess.run(["xcrun", "swiftc", "-DDEBUG", "-parse-as-library", "-default-isolation", "MainActor",
                        "-swift-version", "5", "-module-name", "HostedReadStorageFixture",
                        "-external-plugin-path", f"{platform}/usr/lib/swift/host/plugins#{platform}/usr/bin/swift-plugin-server",
                        *map(str, sources), "-o", str(binary)], check=True, env=environment)
        for phase in ["cancel-store", "cancel-google", "save-controls"]:
            store = root / (phase + ".store")
            subprocess.run([str(binary), phase, str(store)], check=True, env=environment, timeout=30)
            if phase != "save-controls":
                subprocess.run([str(binary), "reopen", str(store)], check=True, env=environment, timeout=30)
        print("PASS hosted read storage: cancellation, exact Google caller, rollback and fresh-process persistence")


if __name__ == "__main__":
    main()
