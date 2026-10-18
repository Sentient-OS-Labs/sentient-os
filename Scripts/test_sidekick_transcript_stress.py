#!/usr/bin/env python3
"""Run bounded real-Home stress against a private copy of the saved hang fixture.

The original SQLite file is read/copied only. Each invocation creates a fresh isolated
profile, so the same source can compare baseline/fixed signed builds. The 45-second
UI deadline terminates only the process group created by the existing app-lab runner.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import test_sidekick_app as app

DEFAULT_SOURCE = Path.home() / "Documents/Sentient Sidekick QA 2026-10-18/Evidence/hang-store-backup/Conversation.sqlite"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()) / "sentient-transcript-stress")
    parser.add_argument("--label", default="current")
    parser.add_argument("--cycles", type=int, choices=range(12, 21), default=12)
    parser.add_argument("--captures", action="store_true", help="Capture only the owned Home window after each reactivation")
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "Library/Application Support/SentientOS/Private Codex")
    args = parser.parse_args()
    root = None
    source = args.source.expanduser().resolve()
    source_digest = None
    try:
        _, executable = app.resolve_app(args.app)
        app.require(source.is_file(), "Missing saved hang-store backup")
        app.require(not Path(str(source) + "-wal").exists(), "Source must be a completed standalone backup, not a live WAL database")
        source_digest = digest(source)
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-app-stress-", dir=artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_bytes(b"1\n")
        (root / "vault").mkdir(mode=0o700)
        manifest = app.fixture(root, "chatgpt")
        manifest.update(stress_cycles=args.cycles, stress_label=args.label, stress_source_sha256=source_digest,
                        stress_captures=args.captures)
        app.save_json(root / "fixture.json", manifest)
        print(f"[{args.label}] stress fixture: {root}", flush=True)
        app.run_stage(executable, root, manifest, args.runtime_root.expanduser().resolve(), "seed", 60)
        target = root / "support/Sidekick/Conversation.sqlite"
        app.require(not target.exists(), "Seed unexpectedly initialized the destination store")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o600)
        app.require(digest(target) == source_digest, "Initial fixture clone is not byte-for-byte identical")
        app.save_json(root / "stress-clone.json", {"source_sha256": source_digest, "initial_clone_sha256": digest(target), "label": args.label})
        receipt = app.run_stage(executable, root, manifest, args.runtime_root.expanduser().resolve(), "ui-stress", 45)
        evidence = app.read_json(root / "stress-manifest.json")
        app.require(evidence.get("completed_cycles") == args.cycles and evidence.get("provider_calls") == 0,
                    "Stress task did not finish the requested provider-free cycles")
        app.require(evidence.get("own_window_captures") == (args.cycles if args.captures else 0), "Requested own-window captures did not finish")
        app.require(digest(source) == source_digest, "Original source backup changed")
        result = {"passed": True, "label": args.label, "root": str(root), "cycles": args.cycles,
                  "checks": len(receipt["checks"]), "elapsed_ms": evidence.get("elapsed_ms"),
                  "own_window_captures": evidence.get("own_window_captures"),
                  "latest_answers_visible": args.cycles - len(evidence.get("offscreen_latest_answer_cycles", [])),
                  "heartbeats": len(evidence.get("heartbeats", [])), "source_unchanged": True}
        app.save_json(root / "stress-runner-result.json", result)
        print(json.dumps(result, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        result = {"passed": False, "label": args.label, "root": str(root) if root else None, "error": str(error),
                  "source_unchanged": source_digest is not None and source.is_file() and digest(source) == source_digest}
        if root:
            heartbeat = root / "stress-heartbeat.json"
            if heartbeat.is_file():
                result["last_heartbeat"] = app.read_json(heartbeat)
            evidence = root / "stress-manifest.json"
            if evidence.is_file():
                summary = app.read_json(evidence)
                result["blank_transcript_cycles"] = summary.get("blank_transcript_cycles", [])
                result["offscreen_latest_answer_cycles"] = summary.get("offscreen_latest_answer_cycles", [])
            app.save_json(root / "stress-runner-result.json", result)
        print(json.dumps(result, indent=2), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
