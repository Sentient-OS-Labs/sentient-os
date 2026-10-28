#!/usr/bin/env python3
"""Compile the production vault and reader search against disposable Markdown files.

Runs on Windows and macOS with Swift 6.2+ installed. The reader's computed search
property is compiled unchanged without SwiftUI; only the app's vault location and
writing-style filename are supplied by the fixture. No user vault is accessed.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

APP = Path(__file__).resolve().parents[1] / "Sentient OS macOS"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--swiftc", default=shutil.which("swiftc"), help="Swift compiler path")
args = parser.parse_args()
if not args.swiftc:
    parser.error("swiftc is not on PATH; install Swift or pass --swiftc PATH")

view = (APP / "Views/Knowledge/KnowledgeView.swift").read_text(encoding="utf-8")
start = view.index("    private var searchResults: [VaultNode] {")
opening = view.index("{", start)
depth, end = 1, opening + 1
while depth:
    depth += (view[end] == "{") - (view[end] == "}")
    end += 1
search_property = view[start:end]

fixture = r'''
import Foundation
#if os(Windows)
import ucrt
#else
import Darwin
#endif

enum VaultGenerator {
    static var vaultRoot: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
}
enum WritingStyle { static let fileName = "writingstyle.md" }

struct ReaderFixture {
    var vault: KnowledgeVault?
    var search: String
    var results: [String] { searchResults.map(\.name) }
__SEARCH_PROPERTY__
}

@main struct KnowledgeSearchTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = VaultGenerator.vaultRoot
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("README.md", "# Overview\n\nOur planning board.\n")
        try write("Travel.md", "# Holidays\n\nPassport renewal before the next trip.\n")
        try write("Nested/Work.md", "# Launch Notes\n\nPrepare a café meeting and discuss C++ (draft).\n")
        try write("Metadata.md", "---\nprivate-tag: metadata-only\n---\n# Visible heading\n\nVisible body.\n")
        try write("writingstyle.md", "# Writing samples\n\nexcluded-secret\n")
        try write("Nested/WRITINGSTYLE.MD", "excluded-secret")
        try write(".hidden.md", "excluded-secret")
        try write(".hidden/Secret.md", "excluded-secret")
        try write("Ignore.txt", "excluded-secret")
        let broken = root.appendingPathComponent("Broken.md")
        try Data([0xFF, 0xFE, 0xFF]).write(to: broken)

        guard let vault = KnowledgeVault.load() else { fatalError("Fixture vault failed to load") }
        var checks = 0
        var failures = 0
        func check(_ label: String, _ actual: [String], _ expected: [String]) {
            checks += 1
            if actual == expected { print("PASS: \(label)") }
            else {
                failures += 1
                print("FAIL: \(label): expected \(expected), got \(actual)")
            }
        }
        func results(_ query: String, in snapshot: KnowledgeVault? = vault) -> [String] {
            ReaderFixture(vault: snapshot, search: query).results
        }
        check("filename matches remain case-insensitive", results("TRAVEL"), ["Travel"])
        check("body-only match from issue #317", results("passport"), ["Travel"])
        check("displayed H1 title is searchable", results("holidays"), ["Travel"])
        check("nested note bodies are searchable", results("meeting"), ["Work"])
        check("Unicode content matches case-insensitively", results("CAFÉ"), ["Work"])
        check("query metacharacters are literal", results("C++ (draft)"), ["Work"])
        check("leading and trailing whitespace is ignored", results("  passport\n"), ["Travel"])
        check("empty search has no results", results(""), [])
        check("whitespace-only search has no results", results(" \t\n"), [])
        check("unmatched query has no results", results("unmatched-needle"), [])
        check("missing vault has no results", results("passport", in: nil), [])
        check("Overview content is included", results("planning board"), ["README"])
        check("frontmatter is excluded from displayed-content search", results("metadata-only"), [])
        check("visible body after frontmatter is included", results("visible body"), ["Metadata"])
        check("writing samples, hidden entries and non-Markdown files stay excluded", results("excluded-secret"), [])
        check("unreadable text keeps its filename match", results("broken"), ["Broken"])

        try write("Travel.md", "# Travel\n\nPassport renewal and travel reservations.\n")
        try write("Nested/Work.md", "# Work\n\nTravel policy.\n")
        guard let updated = KnowledgeVault.load() else { fatalError("Reload failed") }
        check("multiple fields match a note only once, in existing alphabetical order",
              results("travel", in: updated), ["Travel", "Work"])
        check("old snapshot remains stable after an edit", results("holidays"), ["Travel"])
        check("reload drops the old title", results("holidays", in: updated), [])
        check("reload includes edited content", results("reservations", in: updated), ["Travel"])

        try write("Added.md", "# Added\n\nA newly-created-needle.\n")
        guard let created = KnowledgeVault.load() else { fatalError("Create reload failed") }
        check("reload includes newly created notes", results("newly-created-needle", in: created), ["Added"])
        try fm.removeItem(at: root.appendingPathComponent("Added.md"))
        guard let deleted = KnowledgeVault.load() else { fatalError("Delete reload failed") }
        check("reload removes deleted notes", results("newly-created-needle", in: deleted), [])

        try fm.removeItem(at: root.appendingPathComponent("Travel.md"))
        check("search uses the loaded snapshot without rereading note files",
              results("reservations", in: updated), ["Travel"])
        print("Knowledge search: \(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sentient knowledge search ") as directory:
    temp = Path(directory)
    harness = temp / "KnowledgeSearchTests.swift"
    harness.write_text(fixture.replace("__SEARCH_PROPERTY__", search_property), encoding="utf-8")
    binary = temp / ("knowledge-search.exe" if sys.platform == "win32" else "knowledge-search")
    compiler_args = [args.swiftc, "-swift-version", "5", "-default-isolation", "MainActor"]
    if sys.platform == "darwin":
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True,
        ).strip()
        compiler_args += ["-sdk", sdk]
    subprocess.run(compiler_args + [
        str(APP / "Views/Knowledge/VaultTree.swift"), str(harness), "-o", str(binary),
    ], check=True)
    result = subprocess.run([str(binary), str(temp / "Vault")])
    sys.exit(result.returncode)
