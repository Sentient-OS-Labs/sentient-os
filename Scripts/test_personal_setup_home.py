#!/usr/bin/env python3
"""Exercise Sidekick-first Home in the signed DEBUG app's isolated native fixture.

No provider calls, analysis, account connections, production preference writes or
other-app screenshots. Existing SidekickAppLab validates isolation before AppState.
"""
import argparse
import json
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
import test_sidekick_app as app


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()) / "sentient-personal-setup-home")
    parser.add_argument("--runtime-root", type=Path,
                        default=Path.home() / "Library/Application Support/SentientOS/Private Codex")
    parser.add_argument("--manual-review", action="store_true",
                        help="Hold the isolated Home for up to 90 seconds; create the printed continue file after native inspection")
    parser.add_argument("--presentation-capture", action="store_true",
                        help="Also capture the empty Home at 1280x760 and verify the entire window is on screen")
    args = parser.parse_args()
    root = None
    try:
        _, executable = app.resolve_app(args.app)
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-app-personal-", dir=artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_bytes(b"1\n")
        (root / "vault").mkdir(mode=0o700)
        fixture = app.fixture(root, "chatgpt")
        if args.manual_review:
            (root / "personal-setup-manual-review").write_text("1\n")
        if args.presentation_capture:
            (root / "personal-setup-presentation-capture").write_text("1\n")
        runtime = args.runtime_root.expanduser().resolve()
        print(f"Personal setup fixture: {root}", flush=True)
        if args.manual_review:
            print(f"When personal-setup-review-ready.json appears, inspect the owned window, then create: {root / 'continue-personal-setup-review'}", flush=True)
        app.run_stage(executable, root, fixture, runtime, "seed", 60)
        receipt = app.run_stage(executable, root, fixture, runtime, "ui-personal-setup", 180 if args.manual_review else 90)
        manifest = app.read_json(root / "personal-setup-manifest.json")
        captures = manifest.get("captures", [])
        app.require(manifest.get("completed") is True and len(captures) == (11 if args.presentation_capture else 10)
                    and manifest.get("provider_calls") == 0, "Incomplete native fixture")
        app.require(manifest.get("capture_scope") == "current_process_windows_only", "Unexpected screenshot scope")
        for capture in captures:
            path = (root / capture["file"]).resolve()
            app.require(path.parent == root / "polish-snapshots", "Capture escaped the owned fixture")
            app.require(path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
                        and path.stat().st_size > 4096, "Missing or empty UI image")
        result = {"passed": True, "root": str(root), "checks": len(receipt["checks"]),
                  "captures": [str(root / item["file"]) for item in captures], "provider_calls": 0}
        app.save_json(root / "personal-setup-runner-result.json", result)
        print(json.dumps(result, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        print(f"FAIL: {error}", flush=True)
        if root:
            app.save_json(root / "personal-setup-runner-result.json",
                          {"passed": False, "root": str(root), "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
