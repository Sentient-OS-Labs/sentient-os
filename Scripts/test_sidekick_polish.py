#!/usr/bin/env python3
"""Five focused, own-window UI captures using the existing signed-app isolation fixture.
No providers, computer-use helper, real preference changes, or other-app screenshots.
"""
import argparse
import json
from pathlib import Path
import tempfile
import test_sidekick_app as app


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, default=Path(tempfile.gettempdir()) / "sentient-sidekick-polish")
    parser.add_argument("--runtime-root", type=Path, default=Path.home() / "Library/Application Support/SentientOS/Private Codex")
    args = parser.parse_args()
    root = None
    try:
        _, executable = app.resolve_app(args.app)
        artifacts = args.artifacts.expanduser().resolve()
        artifacts.mkdir(parents=True, exist_ok=True)
        root = Path(tempfile.mkdtemp(prefix="sentient-sidekick-app-polish-", dir=artifacts)).resolve()
        root.chmod(0o700)
        (root / app.MARKER).write_bytes(b"1\n")
        (root / "vault").mkdir(mode=0o700)
        fixture = app.fixture(root, "chatgpt")
        runtime = args.runtime_root.expanduser().resolve()
        print(f"Polish fixture: {root}", flush=True)
        app.run_stage(executable, root, fixture, runtime, "seed", 60)
        receipt = app.run_stage(executable, root, fixture, runtime, "ui-polish", 90)
        manifest = app.read_json(root / "polish-manifest.json")
        captures = manifest.get("captures", [])
        app.require(len(captures) == 5 and manifest.get("provider_calls") == 0, "Unexpected capture/provider count")
        for capture in captures:
            path = (root / capture["file"]).resolve()
            app.require(path.parent == root / "polish-snapshots", "Capture escaped owned fixture")
            app.require(path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n") and path.stat().st_size > 4096, "Missing/empty UI image")
        result = {"passed": True, "root": str(root), "checks": len(receipt["checks"]),
                  "captures": [str(root / capture["file"]) for capture in captures], "provider_calls": 0}
        app.save_json(root / "polish-runner-result.json", result)
        print(json.dumps(result, indent=2))
        return 0
    except (app.AcceptanceFailure, OSError, ValueError) as error:
        print(f"FAIL: {error}", flush=True)
        if root:
            app.save_json(root / "polish-runner-result.json", {"passed": False, "root": str(root), "error": str(error)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
