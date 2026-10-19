#!/usr/bin/env python3
"""Offline checks of the real Sidekick memory store and tool lifecycle.

All files and preferences are isolated. No app launch, model calls, or user data.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import Foundation
import Darwin

nonisolated func Log(_ message: String) {}

extension URL {
    nonisolated static var sentientSupport: URL { fatalError("Tests must inject their memory path") }
}
private enum CheckFailure: Error { case failed(String) }
@MainActor private var checks = 0
@MainActor private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    checks += 1
    if try !condition() { throw CheckFailure.failed(message) }
}
@MainActor private func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() }
    catch { checks += 1; return }
    throw CheckFailure.failed(message)
}
@MainActor private final class Changes { var values: [Bool] = [] }

@main private struct MemoryChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "test.sentient.sidekick-memory." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = root.appendingPathComponent("Sidekick/SidekickMemory.md")
        let legacy = "  # My instructions\n\n- Prefer Safari.\n- Keep café drafts concise :)\n\n"
        defaults.set(legacy, forKey: CustomInstructions.sidekickKey)
        defaults.set(Data("obsolete ownership".utf8), forKey: SidekickInstructionStore.metadataKey)

        let migrated = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        try check(migrated.text == legacy, "Migration changed whitespace or Unicode")
        try check(try Data(contentsOf: file) == Data(legacy.utf8), "Migration is not byte-for-byte")
        try check(defaults.object(forKey: SidekickInstructionStore.metadataKey) == nil, "Obsolete ownership metadata survived")
        try check(defaults.bool(forKey: SidekickInstructionStore.migrationKey), "Migration was not marked complete")
        try check(migrated.revision.count == 64 && migrated.readError == nil, "Healthy snapshot missing revision")
        print("PASS: legacy text migrates verbatim into the shared Markdown file")

        // The file wins over defaults, including changes by an external editor.
        let external = "# Preferences\n\nUse Firefox.\n"
        try Data(external.utf8).write(to: file, options: .atomic)
        defaults.set("Stale defaults", forKey: CustomInstructions.sidekickKey)
        let fresh = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        try check(fresh.text == external, "External edit was not reread")
        try check(defaults.string(forKey: CustomInstructions.sidekickKey) == external, "Observation mirror is stale")
        try check(fresh.revision != migrated.revision, "Changed content retained old revision")
        do {
            try SidekickInstructionStore.write("Would overwrite the user", expectedRevision: migrated.revision,
                                               defaults: defaults, memoryURL: file)
            throw CheckFailure.failed("Stale agent write overwrote user text")
        } catch SidekickInstructionStore.Failure.stale { checks += 1 }
        try check(try String(contentsOf: file, encoding: .utf8) == external, "Rejected write changed the file")
        print("PASS: external/user edits are authoritative; stale full-document writes are rejected")

        try SidekickInstructionStore.saveUserEdit("User can edit any line.\n", defaults: defaults, memoryURL: file)
        let userEdit = try SidekickInstructionStore.read(defaults: UserDefaults(suiteName: suite)!, memoryURL: file)
        try check(userEdit.text == "User can edit any line.\n", "User edit did not persist across reread")
        defaults.set(Data("old".utf8), forKey: SidekickInstructionStore.metadataKey)
        SidekickInstructionStore.resetLearning(defaults: defaults)
        try check(try String(contentsOf: file, encoding: .utf8) == userEdit.text, "Rebuild discarded user-editable memory")
        try check(defaults.object(forKey: SidekickInstructionStore.metadataKey) == nil, "Reset retained retired metadata")

        // Canonically equivalent Unicode still has distinct file bytes and content hashes.
        let unicodeFile = root.appendingPathComponent("unicode/SidekickMemory.md")
        try SidekickInstructionStore.saveUserEdit("Café\n", defaults: defaults, memoryURL: unicodeFile)
        let composed = try SidekickInstructionStore.read(defaults: defaults, memoryURL: unicodeFile)
        let decomposedText = "Cafe\u{301}\n"
        let decomposed = try SidekickInstructionStore.write(decomposedText, expectedRevision: composed.revision,
                                                           defaults: defaults, memoryURL: unicodeFile)
        try check(try Data(contentsOf: unicodeFile) == Data(decomposedText.utf8), "Save changed exact Unicode representation")
        try check(try SidekickInstructionStore.read(defaults: defaults, memoryURL: unicodeFile).revision == decomposed.revision,
                  "Returned revision does not match the bytes actually saved")

        // The main agent saves now, without waiting for completion or retaining a staged proposal.
        let changes = Changes()
        let agent = SidekickPersonalization(snapshot: userEdit, taskID: UUID(), request: "Remember I prefer afternoons",
            defaults: defaults, memoryURL: file, onChange: { changes.values.append($0) })
        let saved = try agent.stage(.init(operation: .write,
            markdown: userEdit.text + "Prefer afternoon meetings.\n", revision: userEdit.revision))
        let first = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        try check(saved.hasPrefix("Saved SidekickMemory.md."), "Tool did not confirm an immediate save")
        try check(saved.contains(first.revision), "Saved revision missing from tool response")
        try check(first.text.contains("Prefer afternoon meetings."), "Successful tool call did not persist immediately")
        try check(changes.values == [true, false], "Memory update indicator remained pending")
        agent.discardProposal()
        agent.recordScreenshots(count: 3)
        agent.recordAnswer(UUID(), text: "Actually, only weekdays")
        try await agent.presentStagedUpdate()
        try check(try String(contentsOf: file, encoding: .utf8) == first.text, "Later task activity rolled back saved memory")
        let read = try agent.stage(.init(operation: .read, markdown: nil, revision: nil))
        try check(read.contains(first.revision) && read.contains("afternoon"), "Tool read is not current")
        _ = try agent.stage(.init(operation: .write, markdown: first.text + "Weekdays only.\n", revision: first.revision))
        let second = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        try check(second.text.hasSuffix("Weekdays only.\n"), "A second update in one task failed")
        try check(agent.finish(success: false) == 2, "Failure did not preserve count of already-saved updates")
        try check(try String(contentsOf: file, encoding: .utf8) == second.text, "Stop/failure lost saved memory")
        try check(agent.finish(success: true) == 0, "Repeated finish was not idempotent")
        do {
            _ = try agent.stage(.init(operation: .write, markdown: "Late result", revision: second.revision))
            throw CheckFailure.failed("Ended task could write memory")
        } catch SidekickPersonalization.Failure.unavailable { checks += 1 }
        try check(try String(contentsOf: file, encoding: .utf8) == second.text, "Late result changed saved text")
        print("PASS: immediate and repeated main-agent updates persist through later work, stop and failure")

        // External deletion after migration starts empty, rather than reviving a defaults copy.
        try FileManager.default.removeItem(at: file)
        let deleted = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        try check(deleted.text.isEmpty, "Deleted document was restored from obsolete defaults")
        try check(try Data(contentsOf: file).isEmpty, "Deleted memory did not remain empty")

        // An existing file always wins during the first migration too.
        defaults.removeObject(forKey: SidekickInstructionStore.migrationKey)
        defaults.set("Old instructions", forKey: CustomInstructions.sidekickKey)
        try Data("Existing memory".utf8).write(to: file, options: .atomic)
        try check(try SidekickInstructionStore.read(defaults: defaults, memoryURL: file).text == "Existing memory",
                  "Migration overwrote an existing Markdown file")

        // Invalid UTF-8 cannot silently turn into empty memory or be overwritten by a failed read.
        let invalid = Data([0xff, 0xfe, 0x00, 0x81])
        try invalid.write(to: file, options: .atomic)
        let unreadable = SidekickInstructionStore.snapshot(defaults: defaults, memoryURL: file)
        try check(unreadable.readError != nil && unreadable.revision.isEmpty, "Read error looks like valid empty memory")
        try check(unreadable.promptBlock.contains("UNAVAILABLE"), "Read failure absent from agent context")
        try expectFailure("Unreadable file was overwritten") {
            try SidekickInstructionStore.saveUserEdit("Do not write", defaults: defaults, memoryURL: file)
        }
        try check(try Data(contentsOf: file) == invalid, "Failed read destroyed existing data")
        try check(defaults.string(forKey: CustomInstructions.sidekickKey) == "Existing memory", "Failed read destroyed the last observation")
        print("PASS: existing and deleted files are respected; read failures remain explicit and nondestructive")

        // Real failed atomic replace: the existing file stays readable, but its directory is unwritable.
        try Data("Before failed write".utf8).write(to: file, options: .atomic)
        let before = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        if geteuid() != 0 {
            let directory = file.deletingLastPathComponent()
            let failedChanges = Changes()
            let failedAgent = SidekickPersonalization(snapshot: before, taskID: UUID(), request: nil,
                defaults: defaults, memoryURL: file, onChange: { failedChanges.values.append($0) })
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            do {
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
                try expectFailure("Failed atomic write claimed success") {
                    _ = try SidekickInstructionStore.write("Unsaved replacement", expectedRevision: before.revision,
                                                          defaults: defaults, memoryURL: file)
                }
                try check(try String(contentsOf: file, encoding: .utf8) == before.text, "Failed atomic write damaged prior contents")
                try check(defaults.string(forKey: CustomInstructions.sidekickKey) == before.text, "Failed write changed the mirror")
                try expectFailure("Tool swallowed failed write") {
                    _ = try failedAgent.stage(.init(operation: .write, markdown: "Unsaved tool write", revision: before.revision))
                }
                try check(failedChanges.values == [true, false], "Failed tool write left update indicator active")
                try check(failedAgent.finish(success: true) == 0, "Failed tool write was counted as a save")
            }
            print("PASS: failed atomic writes preserve the prior file and surface an error")
        } else {
            print("SKIP: directory permission denial cannot be exercised as root")
        }

        // Failed initial migration preserves the old instructions and remains retryable.
        let failedSuite = suite + ".migration"
        let failedDefaults = UserDefaults(suiteName: failedSuite)!
        defer { failedDefaults.removePersistentDomain(forName: failedSuite) }
        failedDefaults.set(legacy, forKey: CustomInstructions.sidekickKey)
        failedDefaults.set(Data("old metadata".utf8), forKey: SidekickInstructionStore.metadataKey)
        let blocker = root.appendingPathComponent("blocked-parent")
        try Data("A file cannot contain memory".utf8).write(to: blocker)
        let blockedFile = blocker.appendingPathComponent("SidekickMemory.md")
        try expectFailure("Initial migration silently succeeded through an invalid parent") {
            _ = try SidekickInstructionStore.read(defaults: failedDefaults, memoryURL: blockedFile)
        }
        try check(!failedDefaults.bool(forKey: SidekickInstructionStore.migrationKey), "Failed migration marked complete")
        try check(failedDefaults.string(forKey: CustomInstructions.sidekickKey) == legacy, "Failed migration lost legacy instructions")
        try check(failedDefaults.object(forKey: SidekickInstructionStore.metadataKey) != nil, "Failed migration removed old metadata prematurely")
        try FileManager.default.removeItem(at: blocker)
        let retried = try SidekickInstructionStore.read(defaults: failedDefaults, memoryURL: blockedFile)
        try check(retried.text == legacy && Data(contentsOf: blockedFile) == Data(legacy.utf8), "Retried migration lost the original document")
        print("PASS: failed initial migration preserves legacy data and retries successfully")

        let cancelled = SidekickPersonalization(snapshot: before, taskID: UUID(), request: nil,
            defaults: defaults, memoryURL: file, onChange: { _ in })
        let job = Task { @MainActor in
            do {
                _ = try cancelled.stage(.init(operation: .write, markdown: "Cancelled", revision: before.revision))
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        job.cancel()
        let wasCancelled = await job.value
        try check(wasCancelled, "A cancelled task wrote memory")
        try check(try String(contentsOf: file, encoding: .utf8) == before.text, "Cancelled task changed memory")

        let validRead: [String: Any] = ["operation": "read", "markdown": NSNull(), "revision": NSNull()]
        try check(try SidekickPersonalization.decode(validRead).operation == .read, "Read schema rejected")
        let validWrite: [String: Any] = ["operation": "write", "markdown": "", "revision": before.revision]
        try check(try SidekickPersonalization.decode(validWrite).markdown == "", "Explicit clear-memory write rejected")
        try check(SidekickPersonalization.rejectionCode(SidekickInstructionStore.Failure.stale) == "settings_changed",
                  "Stale memory writes have no fixed diagnostic reason")
        let privateError = NSError(domain: "PRIVATE", code: 99, userInfo: [NSLocalizedDescriptionKey: "/Users/private/Secret.md"])
        try check(SidekickPersonalization.rejectionCode(privateError) == "memory_io", "I/O failure missing fixed diagnostic reason")
        let safeMessage = SidekickPersonalization.failureMessage(privateError)
        try check(!safeMessage.contains("PRIVATE") && !safeMessage.contains("Secret.md"), "Failure helper leaked raw error content")
        for arguments: [String: Any] in [
            ["operation": "read"],
            ["operation": "delete", "markdown": NSNull(), "revision": NSNull()],
            ["operation": "write", "markdown": NSNull(), "revision": before.revision],
            ["operation": "write", "markdown": "text", "revision": ""],
            ["operation": "read", "markdown": "text", "revision": NSNull()],
            ["operation": "read", "markdown": NSNull(), "revision": NSNull(), "extra": true]
        ] {
            try expectFailure("Malformed memory request was accepted") { _ = try SidekickPersonalization.decode(arguments) }
        }
        print("PASS: cancelled tasks cannot write; schema rejects malformed requests and permits an explicit empty document")

        // A mounted editor must not recreate Application Support or its mirror during uninstall.
        let existingBytes = try Data(contentsOf: file)
        defaults.set("Mirror intentionally unchanged during teardown", forKey: CustomInstructions.sidekickKey)
        let domainBefore = NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!)
        let removedRoot = root.appendingPathComponent("removed-support")
        let removedFile = removedRoot.appendingPathComponent("Sidekick/SidekickMemory.md")
        SidekickInstructionStore.beginTeardown()
        for target in [file, removedFile] {
            do {
                _ = try SidekickInstructionStore.read(defaults: defaults, memoryURL: target)
                throw CheckFailure.failed("Teardown allowed a read")
            } catch SidekickInstructionStore.Failure.unavailable { checks += 1 }
            do {
                _ = try SidekickInstructionStore.write("Must not save", defaults: defaults, memoryURL: target)
                throw CheckFailure.failed("Teardown allowed a write")
            } catch SidekickInstructionStore.Failure.unavailable { checks += 1 }
        }
        try check(SidekickInstructionStore.snapshot(defaults: defaults, memoryURL: removedFile).readError != nil,
                  "Teardown snapshot looked like readable memory")
        // The default URL accessor is a fatal fixture: these must fail before resolving it.
        do {
            _ = try SidekickInstructionStore.read(defaults: defaults)
            throw CheckFailure.failed("Teardown resolved the production support root")
        } catch SidekickInstructionStore.Failure.unavailable { checks += 1 }
        do {
            _ = try SidekickInstructionStore.write("Must not resolve root", defaults: defaults)
            throw CheckFailure.failed("Teardown write resolved the production support root")
        } catch SidekickInstructionStore.Failure.unavailable { checks += 1 }
        try check(try Data(contentsOf: file) == existingBytes, "Teardown changed existing memory")
        try check(!FileManager.default.fileExists(atPath: removedRoot.path), "Teardown recreated the removed support root")
        try check(domainBefore.isEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: suite)!)), "Teardown changed preference contents")
        SidekickInstructionStore.endTeardown()
        let resumed = try SidekickInstructionStore.read(defaults: defaults, memoryURL: file)
        try check(Data(resumed.text.utf8) == existingBytes, "Aborted teardown could not reread existing memory")
        try SidekickInstructionStore.saveUserEdit("Editing resumed", defaults: defaults, memoryURL: file)
        try check(try String(contentsOf: file, encoding: .utf8) == "Editing resumed", "Aborted teardown did not restore editing")
        _ = try SidekickInstructionStore.read(defaults: defaults, memoryURL: removedFile)
        try check(FileManager.default.fileExists(atPath: removedFile.path), "Aborted teardown did not restore normal file creation")
        print("PASS: teardown prevents file/defaults resurrection and aborted teardown restores normal access")
        print("Checked \(checks) Sidekick memory assertions; failures=0")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-sidekick-memory-") as directory:
    root = Path(directory)
    source = root / "MemoryChecks.swift"
    source.write_text(FIXTURE)
    binary = root / "memory-checks"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-parse-as-library",
        str(APP / "Notch Magic/SidekickInstructionStore.swift"),
        str(APP / "Notch Magic/SidekickPersonalization.swift"),
        str(APP / "System/CustomInstructions.swift"),
        str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(root)], check=True, timeout=30,
                   env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")})
