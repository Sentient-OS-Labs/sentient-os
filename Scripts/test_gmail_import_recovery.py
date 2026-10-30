#!/usr/bin/env python3
"""Run production Gmail imports against real disk-backed SwiftData stores.

Compiles the complete production files unchanged. Only unrelated collaborators and
the external model read are fixtures. Separate processes verify durable recovery;
no user's preferences, mailbox, model, or Application Support directory is used.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sentient OS macOS"


def main():
    environment = dict(os.environ)
    if not environment.get("DEVELOPER_DIR"):
        for candidate in [Path("/Applications/Xcode-beta.app"), Path("/Applications/Xcode.app")]:
            if candidate.exists():
                environment["DEVELOPER_DIR"] = str(candidate / "Contents/Developer")
                break
    developer = Path(environment.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    if not (platform / "usr/lib/swift/host/plugins/libSwiftDataMacros.dylib").exists():
        raise SystemExit("Select a full Xcode installation with DEVELOPER_DIR; real SwiftData macro plugins are required.")
    with tempfile.TemporaryDirectory(prefix="sentient-gmail-recovery-") as temporary:
        root = Path(temporary)
        binary = root / "gmail-recovery"
        sources = [
            APP / "Ingestion/ItemKey.swift",
            APP / "Ingestion/CycleStore.swift",
            APP / "Sources/GmailReadState.swift",
            APP / "Sources/GmailConnect.swift",
            ROOT / "Scripts/test_gmail_import_recovery.swift",
            APP / "Ingestion/InitialAnalysisRecovery.swift",
        ]
        compiler = [
            "xcrun", "swiftc", "-DDEBUG", "-parse-as-library",
            "-default-isolation", "MainActor", "-swift-version", "5",
            "-module-name", "GmailImportRecoveryFixture",
            "-external-plugin-path", f"{platform}/usr/lib/swift/host/plugins#{platform}/usr/bin/swift-plugin-server",
        ]
        subprocess.run([*compiler, *map(str, sources), "-o", str(binary)], check=True, env=environment)

        # Create the pre-change schema in its own process, then open it with the
        # complete current production actor. Only the new optional field differs.
        models = (APP / "Ingestion/CycleStore.swift").read_text().split("// MARK: - The actor")[0]
        assert "    var gmailReadState: Data? = nil\n" in models
        legacy = root / "LegacyModels.swift"
        legacy.write_text(models.replace("    var gmailReadState: Data? = nil\n", ""))
        collaborators = (ROOT / "Scripts/test_gmail_import_recovery.swift").read_text().split("extension CycleStore {")[0]
        old_main = root / "LegacyMain.swift"
        old_main.write_text(collaborators + r'''
@main enum LegacyWriter {
    static func main() throws {
        let schema = Schema([BucketPointer.self, CycleNote.self, AppleMailReceipt.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema,
            url: URL(fileURLWithPath: CommandLine.arguments[1])))
        let context = ModelContext(container)
        let row = BucketPointer(bucketKey: "gmail", mark: ItemKey(order: 1_790_000_000, tiebreak: "prior"))
        row.mcpReadOrigin = "fixture:0"
        context.insert(row)
        context.insert(CycleNote(bucketKey: "gmail", kind: .gmail, sourceID: "gmail:legacy", folder: "Gmail",
            itemDate: Date(timeIntervalSince1970: 1_790_000_000), text: "Synthetic legacy summary", title: nil, reminderFlagged: false))
        try context.save()
    }
}
''')
        old_binary = root / "legacy-writer"
        subprocess.run([*compiler, str(sources[0]), str(sources[2]), str(legacy), str(old_main), "-o", str(old_binary)],
                       check=True, env=environment)
        subprocess.run([str(old_binary), str(root / "migration.store")], check=True, env=environment, timeout=30)
        for phase in ["migration", "write-partial", "reopen-partial", "finish-partial", "reopen-complete", "transactions", "pipeline", "origins", "initial-write", "initial-restart", "initial-reopen-complete"]:
            # Recovery crosses a real process boundary and a different calendar/timezone.
            phase_environment = dict(environment, TZ="Pacific/Kiritimati" if phase == "reopen-partial" else "UTC")
            subprocess.run([str(binary), phase, str(root)], check=True, env=phase_environment, timeout=90)
        print("PASS Gmail import recovery: production code, real SwiftData, fresh-process recovery")


if __name__ == "__main__":
    main()
