#!/usr/bin/env python3
"""Exercise Clear chat through the signed app's native confirmation, using disposable data.

The app presses its own native Cancel/Clear buttons. Independently inspect the resulting
SQLite store, legacy defaults, saved instructions, knowledge files and captured UI states.
No user history, provider calls, or production preferences are used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile

sys.dont_write_bytecode = True
import test_sidekick_app as app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, default=Path("/tmp/sentient-clear-chat-ui"))
    parser.add_argument("--hold-seconds", type=int, default=0)
    args = parser.parse_args()
    root = None
    try:
        app.require(0 <= args.hold_seconds <= 600, "Hold must be between 0 and 600 seconds")
        _, executable = app.resolve_app(args.app)
        args.artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-app-clear-", dir=args.artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_text("1\n")
        (root / "vault").mkdir(mode=0o700)
        knowledge = b"# Synthetic knowledge\n\nThis knowledge must survive Clear chat.\n"
        (root / "vault/README.md").write_bytes(knowledge)
        manifest = app.fixture(root, "chatgpt")
        manifest["ui_hold_seconds"] = args.hold_seconds
        app.save_json(root / "fixture.json", manifest)
        runtime = Path.home() / "Library/Application Support/SentientOS/Private Codex"
        print(f"Clear chat fixture: {root}", flush=True)
        app.run_stage(executable, root, manifest, runtime, "seed", 60)
        receipt = app.run_stage(executable, root, manifest, runtime, "ui-clear", args.hold_seconds + 180)
        result = app.read_json(root / "clear-ui-manifest.json")
        app.require(result["old_generation"] != result["new_generation"] == receipt["generation"],
                    "Clear did not rotate the persisted generation")
        state = app.snapshot(root)
        app.require(state["generation"] == result["new_generation"] and not state["records"] and not state["tasks"],
                    "Cleared records returned after process exit")
        database = root / "support/Sidekick/Conversation.sqlite"
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            for table in ["summaries", "read_events", "tasks", "events"]:
                app.require(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0,
                            f"Clear left rows in {table}")
            app.require(connection.execute("SELECT legacy_imported, read_through FROM state").fetchone() == (1, 0),
                        "Cleared legacy history can reimport or retained read state")
        defaults = app.preferences(manifest)
        app.require("sidekick.history" not in defaults and "sidekick.errors" not in defaults,
                    "Legacy history survived clear")
        app.require((root / "support/Sidekick/SidekickMemory.md").read_text() == app.MEMORY,
                    "Clear changed saved Sidekick instructions")
        app.require((root / "vault/README.md").read_bytes() == knowledge, "Clear changed the knowledge base")
        expected = {"01-chat-before-clear", "02-clear-confirmation", "03-overview-after-clear", "04-empty-conversation"}
        app.require({s["name"] for s in result["snapshots"]} == expected, "Missing visual states")
        for snapshot in result["snapshots"]:
            path = root / snapshot["file"]
            app.require(path.resolve().is_relative_to(root / "ui-snapshots"), "Capture escaped fixture")
            data = path.read_bytes()
            app.require(data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) == snapshot["bytes"]
                        and hashlib.sha256(data).hexdigest() == snapshot["sha256"], "Capture mismatch")
            app.require(snapshot["capture_method"] == "desktop_independent_own_window"
                        and snapshot["sampled_colors"] > 32 and snapshot["nonblack_fraction"] > .035,
                        "Capture did not contain the rendered owned window")
        app.require(result["provider_calls"] == 0 and all(result["checks"].values()), "App checks failed")
        output = {"passed": True, "root": str(root), "native_checks": len(receipt["checks"]),
                  "snapshots": len(result["snapshots"]), "provider_calls": 0,
                  "history_and_summaries_empty": True, "knowledge_and_instructions_unchanged": True}
        app.save_json(root / "clear-ui-result.json", output)
        print(json.dumps(output, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        if root:
            app.save_json(root / "clear-ui-result.json", {"passed": False, "error": str(error)})
        print(f"FAIL: {error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
