#!/usr/bin/env python3
"""Compile and execute the production vault validator and durable merge checkpoint.

All filesystem activity is in an owned temporary fixture. No model, account, network,
real knowledge base, preferences, or Keychain is used.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"

FIXTURE = r'''
import Foundation
import Darwin

@main @MainActor struct Tests {
    static var checks = 0
    static let fm = FileManager.default
    static func check(_ result: Bool, _ message: String) {
        precondition(result, message); checks += 1
    }
    static func expect(_ expected: VaultValidation.Failure, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Accepted unsafe staging: \(expected)") }
        catch let failure as VaultValidation.Failure { check(failure == expected, "Check \(checks): expected \(expected), got \(failure)") }
        catch { preconditionFailure("Unexpected error: \(error)") }
    }
    static func directory(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func write(_ root: URL, _ path: String, _ contents: String = "# Fictional knowledge\n") throws {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }
    static func newVault(_ parent: URL, _ name: String) throws -> URL {
        let root = try directory(parent, name); try write(root, "README.md"); return root
    }
    static func input(_ id: String = "file:/private/fictional-source", kind: String = "file",
                      folder: String = "/private/fictional-folder", title: String? = "Private title",
                      text: String = "Private source contents", date: Date? = Date(timeIntervalSince1970: 1234)) -> VaultMergeCheckpoint.Input {
        .init(sourceID: id, kind: kind, folder: folder, title: title, text: text, itemDate: date)
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("sentient-vault-integrity-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = try newVault(root, "original")
        try write(original, "writingstyle.md", "Samples from the fictional user")
        try write(original, "Projects/Ship.md", "Ship the fictional project")
        let originalBefore = try VaultValidation.fingerprint(original)
        let good = try newVault(root, "good")
        try write(good, "writingstyle.md", "Samples from the fictional user")
        try write(good, "Projects/Ship.md", "Ship the fictional project")
        let valid = try VaultValidation.validate(staging: good, replacing: original)
        check(valid.files == 3 && valid.paths.contains("Projects/Ship.md"), "Valid tree was not read completely")
        check(valid.bytes > 0 && valid.fingerprint.count == 64, "Missing validation summary")
        check(valid.fingerprint == originalBefore, "Content fingerprint depends on directory or mtime")
        let absent = root.appendingPathComponent("does-not-exist")
        _ = try VaultValidation.validate(staging: good, replacing: absent); checks += 1
        expect(.overlappingRoots) { _ = try VaultValidation.validate(staging: original, replacing: original) }
        let nested = try newVault(good, "nested")
        expect(.overlappingRoots) { _ = try VaultValidation.validate(staging: nested, replacing: good) }
        try fm.removeItem(at: nested)
        let noIndex = try directory(root, "no-index")
        try write(noIndex, "Other.md")
        expect(.missingIndex) { _ = try VaultValidation.validate(staging: noIndex) }
        let blank = try newVault(root, "blank")
        try write(blank, "README.md", " \n\t")
        expect(.emptyIndex) { _ = try VaultValidation.validate(staging: blank) }
        let unexpected = try newVault(root, "unexpected")
        for name in ["script.sh", ".sentient-corpus.json", ".DS_Store", "UPPER.MD"] {
            try write(unexpected, name, "untrusted")
            expect(.unexpectedFile) { _ = try VaultValidation.validate(staging: unexpected) }
            try fm.removeItem(at: unexpected.appendingPathComponent(name))
        }
        let badUTF8 = try newVault(root, "bad-utf8")
        try Data([0xff, 0xfe]).write(to: badUTF8.appendingPathComponent("Binary.md"))
        expect(.invalidMarkdown) { _ = try VaultValidation.validate(staging: badUTF8) }
        try Data([65, 0, 66]).write(to: badUTF8.appendingPathComponent("Binary.md"))
        expect(.invalidMarkdown) { _ = try VaultValidation.validate(staging: badUTF8) }
        let links = try newVault(root, "links")
        for destination in [original.appendingPathComponent("README.md"), links.appendingPathComponent("README.md"), original, absent] {
            let link = links.appendingPathComponent("Linked.md")
            try fm.createSymbolicLink(at: link, withDestinationURL: destination)
            expect(.symbolicLink) { _ = try VaultValidation.validate(staging: links) }
            try fm.removeItem(at: link)
        }
        let rootLink = root.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: good)
        expect(.symbolicLink) { _ = try VaultValidation.validate(staging: rootLink) }
        expect(.symbolicLink) { _ = try VaultValidation.validate(staging: good, replacing: rootLink) }
        let hardLink = links.appendingPathComponent("Hard.md")
        try fm.linkItem(at: original.appendingPathComponent("README.md"), to: hardLink)
        expect(.hardLink) { _ = try VaultValidation.validate(staging: links) }
        try fm.removeItem(at: hardLink)
        let fifo = links.appendingPathComponent("Pipe.md")
        check(fifo.path.withCString { mkfifo($0, 0o600) } == 0, "Could not create FIFO fixture")
        expect(.nonRegularFile) { _ = try VaultValidation.validate(staging: links) }
        try fm.removeItem(at: fifo)
        expect(.invalidRoot) { _ = try VaultValidation.validate(staging: good.appendingPathComponent("README.md")) }
        expect(.invalidRoot) { _ = try VaultValidation.validate(staging: URL(string: "https://example.invalid/vault")!) }

        var limits = VaultValidation.Limits()
        limits.maximumFileBytes = 10
        expect(.fileTooLarge) { _ = try VaultValidation.validate(staging: good, limits: limits) }
        limits = .init(); limits.maximumTotalBytes = 25
        expect(.treeTooLarge) { _ = try VaultValidation.validate(staging: good, limits: limits) }
        limits = .init(); limits.maximumFiles = 2
        expect(.tooManyFiles) { _ = try VaultValidation.validate(staging: good, limits: limits) }
        let deep = try newVault(root, "deep")
        try write(deep, "a/b/c/note.md")
        limits = .init(); limits.maximumDepth = 2
        expect(.tooDeep) { _ = try VaultValidation.validate(staging: deep, limits: limits) }
        limits = .init(); limits.maximumDirectories = 2
        expect(.tooManyDirectories) { _ = try VaultValidation.validate(staging: deep, limits: limits) }
        limits = .init(); limits.maximumTotalBytes = 0
        expect(.invalidLimits) { _ = try VaultValidation.validate(staging: good, limits: limits) }
        limits = .init(); limits.importantPaths = ["../outside.md"]
        expect(.invalidLimits) { _ = try VaultValidation.validate(staging: good, limits: limits) }
        limits = .init(); limits.minimumRetainedFraction = .nan
        expect(.invalidLimits) { _ = try VaultValidation.validate(staging: good, limits: limits) }
        let lostImportant = try newVault(root, "lost-important")
        expect(.missingImportantFile) { _ = try VaultValidation.validate(staging: lostImportant, replacing: original) }
        let many = try newVault(root, "many")
        for i in 1...10 { try write(many, "Notes/\(i).md") }
        expect(.catastrophicShrink) { _ = try VaultValidation.validate(staging: lostImportant, replacing: many) }
        let large = try newVault(root, "large")
        try write(large, "README.md", String(repeating: "x", count: 20_000))
        expect(.catastrophicShrink) { _ = try VaultValidation.validate(staging: lostImportant, replacing: large) }
        let edge = try newVault(root, "edge")
        for i in 1...9 { try write(edge, "Notes/\(i).md") }
        let exactlyFifth = try newVault(root, "fifth")
        try write(exactlyFifth, "Notes/kept.md")
        _ = try VaultValidation.validate(staging: exactlyFifth, replacing: edge); checks += 1
        check(try VaultValidation.fingerprint(original) == originalBefore, "Validation changed original knowledge")
        check(try String(contentsOf: original.appendingPathComponent("README.md"), encoding: .utf8) == "# Fictional knowledge\n", "Outside symlink target was modified")
        let originalDate = (try fm.attributesOfItem(atPath: good.appendingPathComponent("README.md").path))[.modificationDate]!
        try write(good, "README.md", "# Fictional knowledgf\n") // same byte count
        try fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: good.appendingPathComponent("README.md").path)
        let editedFingerprint = try VaultValidation.fingerprint(good)
        check(editedFingerprint != valid.fingerprint, "Same-size edit with restored mtime escaped content fingerprint")
        // Finder/Obsidian metadata is preserved only when it existed and is byte-identical.
        let metadataOriginal = try newVault(root, "metadata-original")
        try Data([0, 255, 31, 90]).write(to: metadataOriginal.appendingPathComponent(".DS_Store"))
        try write(metadataOriginal, ".obsidian/workspace.json", "{\"fixture\":true}")
        let metadataStage = root.appendingPathComponent("metadata-stage")
        try fm.copyItem(at: metadataOriginal, to: metadataStage)
        let metadataResult = try VaultValidation.validate(staging: metadataStage, replacing: metadataOriginal)
        check(metadataResult.files == 1 && metadataResult.paths == ["README.md"], "Metadata became knowledge notes")
        check(metadataResult.bytes > metadataResult.paths.count * 21, "Metadata was excluded from tree byte limit")
        check(metadataResult.fingerprint == (try VaultValidation.fingerprint(metadataOriginal)), "Metadata changed content identity")
        let markdownOnly = try newVault(root, "markdown-only")
        check(metadataResult.fingerprint == (try VaultValidation.fingerprint(markdownOnly)), "Metadata was included in knowledge fingerprint")
        try write(metadataStage, ".obsidian/new.json", "new output")
        expect(.unexpectedFile) { _ = try VaultValidation.validate(staging: metadataStage, replacing: metadataOriginal) }
        try fm.removeItem(at: metadataStage.appendingPathComponent(".obsidian/new.json"))
        try write(metadataStage, ".obsidian/workspace.json", "changed")
        expect(.unexpectedFile) { _ = try VaultValidation.validate(staging: metadataStage, replacing: metadataOriginal) }
        try fm.removeItem(at: metadataStage.appendingPathComponent(".obsidian/workspace.json"))
        expect(.missingImportantFile) { _ = try VaultValidation.validate(staging: metadataStage, replacing: metadataOriginal) }
        limits = .init(); limits.maximumTotalBytes = 25
        expect(.treeTooLarge) { _ = try VaultValidation.fingerprint(metadataOriginal, limits: limits) }
        let shrinkWithMetadata = try newVault(root, "shrink-metadata-old")
        try write(shrinkWithMetadata, "README.md", String(repeating: "x", count: 20_000))
        try write(shrinkWithMetadata, "metadata.dat", String(repeating: "y", count: 100_000))
        let shrinkStage = try newVault(root, "shrink-metadata-new")
        try write(shrinkStage, "metadata.dat", String(repeating: "y", count: 100_000))
        expect(.catastrophicShrink) { _ = try VaultValidation.validate(staging: shrinkStage, replacing: shrinkWithMetadata) }
        let weird = try newVault(root, "weird")
        try write(weird, "Notes/a|b\nc.md", "Safe filename, unusual separators")
        _ = try VaultValidation.validate(staging: weird); checks += 1

        // A successful merge is remembered even if the later proactive research fails or the app
        // restarts. Only exact consumed source inputs are covered; new arrivals remain pending.
        let largeInputs=(0..<10_001).map {input("large:\($0)")}
        let largeCheckpoint=VaultMergeCheckpoint(file:root.appendingPathComponent("large-checkpoint.json"))
        try largeCheckpoint.recordSuccessfulMerge(inputs:largeInputs,consumedSourceIDs:Set(largeInputs.map(\.sourceID)),resultingVaultFingerprint:valid.fingerprint)
        check(largeCheckpoint.coveredSourceIDs(in:largeInputs,vaultFingerprint:valid.fingerprint).count == largeInputs.count,
              "Large completed initial stage did not survive restart")
        check(try Data(contentsOf:largeCheckpoint.file).count < 1024,"Large-stage checkpoint should remain bounded")
        check(largeCheckpoint.coveredSourceIDs(in:Array(largeInputs.dropLast()),vaultFingerprint:valid.fingerprint).isEmpty,
              "Changed large-stage input set reused stale completion")
        var editedLarge=largeInputs;editedLarge[0]=input("large:0",text:"Changed content")
        check(largeCheckpoint.coveredSourceIDs(in:editedLarge,vaultFingerprint:valid.fingerprint).isEmpty,
              "Changed large-stage content reused stale completion")
        let checkpointURL = root.appendingPathComponent("checkpoint.json")
        let checkpoint = VaultMergeCheckpoint(file: checkpointURL)
        let a = input(), b = input("mail:second", kind: "mail", text: "Another summary")
        let accepted = [a, b]
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint).isEmpty, "Missing checkpoint skipped work")
        try checkpoint.recordSuccessfulMerge(inputs: accepted, consumedSourceIDs: [a.sourceID], resultingVaultFingerprint: valid.fingerprint)
        let reloaded = VaultMergeCheckpoint(file: checkpointURL)
        check(reloaded.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint) == [a.sourceID], "Restart lost completed merge or skipped new arrival")
        check(reloaded.coveredSourceIDs(in: [b, a], vaultFingerprint: valid.fingerprint) == [a.sourceID], "Reordering changed input identity")
        check(reloaded.coveredSourceIDs(in: accepted, vaultFingerprint: editedFingerprint).isEmpty, "Changed vault reused checkpoint")
        check(reloaded.coveredSourceIDs(in: [b], vaultFingerprint: valid.fingerprint).isEmpty, "Removed source was treated as pending coverage")
        for changed in [input(kind: "mail"), input(folder: "Other trust boundary"), input(title: "Other"),
                        input(text: "Edited summary"), input(date: Date(timeIntervalSince1970: 1234.25)),
                        input(title: nil), input(date: nil)] {
            check(reloaded.coveredSourceIDs(in: [changed], vaultFingerprint: valid.fingerprint).isEmpty, "Changed accepted input was skipped")
        }
        check(reloaded.coveredSourceIDs(in: [a, input(text: "Conflicting duplicate")], vaultFingerprint: valid.fingerprint).isEmpty, "Conflicting duplicate input was accepted")
        let saved = try Data(contentsOf: checkpointURL)
        let savedText = String(decoding: saved, as: UTF8.self)
        for privateString in [a.sourceID, a.folder, a.title!, a.text] {
            check(!savedText.contains(privateString), "Checkpoint leaked raw private input")
        }
        let permissions = (try fm.attributesOfItem(atPath: checkpointURL.path))[.posixPermissions] as! Int
        check(permissions & 0o777 == 0o600, "Recovery file is not private")
        try checkpoint.recordSuccessfulMerge(inputs: accepted, consumedSourceIDs: [], resultingVaultFingerprint: valid.fingerprint)
        check(try Data(contentsOf: checkpointURL) == saved, "Empty merge erased checkpoint")
        do {
            try checkpoint.recordSuccessfulMerge(inputs: accepted, consumedSourceIDs: ["unknown"], resultingVaultFingerprint: valid.fingerprint)
            preconditionFailure("Unknown source was committed")
        } catch VaultMergeCheckpoint.Failure.invalidInput { checks += 1 }
        do {
            try checkpoint.recordSuccessfulMerge(inputs: accepted, consumedSourceIDs: [a.sourceID], resultingVaultFingerprint: "partial")
            preconditionFailure("Invalid vault fingerprint was committed")
        } catch VaultMergeCheckpoint.Failure.invalidFingerprint { checks += 1 }
        check(try Data(contentsOf: checkpointURL) == saved, "Failed save destroyed old checkpoint")
        // Simulated retry: a is covered; only b gets merged, then both are bound to the new result.
        var merged = Set<String>()
        let covered = checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint)
        for note in accepted where !covered.contains(note.sourceID) { merged.insert(note.sourceID) }
        check(merged == [b.sourceID], "Retry repeated successful input merge")
        try checkpoint.recordSuccessfulMerge(inputs: accepted, consumedSourceIDs: covered.union(merged), resultingVaultFingerprint: editedFingerprint)
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: editedFingerprint) == [a.sourceID, b.sourceID], "Later merge lost earlier coverage")
        try checkpoint.clear()
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: editedFingerprint).isEmpty, "Successful cleanup did not clear coverage")
        try checkpoint.clear(); checks += 1
        try Data("{truncated".utf8).write(to: checkpointURL)
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint).isEmpty, "Corrupt checkpoint skipped work")
        try saved.write(to: checkpointURL)
        var object = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        object["inputDigest"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object).write(to: checkpointURL)
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint).isEmpty, "Mismatched input digest skipped work")
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: checkpointURL)
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint).isEmpty, "Unknown format skipped work")
        try fm.removeItem(at: checkpointURL)
        let outside = root.appendingPathComponent("outside.json")
        try saved.write(to: outside)
        try fm.createSymbolicLink(at: checkpointURL, withDestinationURL: outside)
        check(checkpoint.coveredSourceIDs(in: accepted, vaultFingerprint: valid.fingerprint).isEmpty, "Checkpoint followed symlink")
        do {
            try checkpoint.recordSuccessfulMerge(inputs: accepted, consumedSourceIDs: [a.sourceID], resultingVaultFingerprint: valid.fingerprint)
            preconditionFailure("Checkpoint wrote through symlink")
        } catch VaultMergeCheckpoint.Failure.unsafeStorage { checks += 1 }
        try checkpoint.clear()
        check(try Data(contentsOf: outside) == saved, "Clearing checkpoint deleted or changed symlink target")
        print("Vault integrity production helpers: \(checks) checks passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient-vault-integrity-build-") as directory:
    directory = Path(directory)
    source = directory / "VaultIntegrityTests.swift"
    source.write_text(FIXTURE)
    executable = directory / "tests"
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor", str(source),
                    str(APP / "Vault/VaultValidation.swift"),
                    str(APP / "Proactive/VaultMergeCheckpoint.swift"),
                    str(APP / "System/AppSupport.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
