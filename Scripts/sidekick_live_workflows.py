#!/usr/bin/env python3
"""Prepare/run a real Home composer workbench with isolated chat and real provider accounts.

Write JSON commands to the printed root/inbox to submit prompts or answer questions.
The signed DEBUG app writes transcripts, status, receipts and periodic Home screenshots.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import test_sidekick_app as acceptance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--provider", choices=["chatgpt", "claude"], required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    _, executable = acceptance.resolve_app(args.app)
    artifacts = args.artifacts.expanduser().resolve(); artifacts.mkdir(parents=True, exist_ok=True)
    runtime = (Path.home() / "Library/Application Support/SentientOS/Private Codex").resolve()
    if args.root:
        root = args.root.resolve()
        manifest = acceptance.read_json(root / "fixture.json")
        assert manifest["provider"] == args.provider
    else:
        root = Path(tempfile.mkdtemp(prefix=f"sentient-sidekick-app-live-{args.provider}-", dir=artifacts)).resolve()
        root.chmod(0o700); (root / acceptance.MARKER).write_text("1\n")
        (root / "vault").mkdir(mode=0o700)
        manifest = acceptance.fixture(root, args.provider)
        acceptance.run_stage(executable, root, manifest, runtime, "seed", 60)
    for folder in ["inbox", "commands", "home-captures"]:
        (root / folder).mkdir(exist_ok=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("SENTIENT_", "LAB_"))}
    env.update(SENTIENT_SELFTEST="sidekickapp", LAB_SIDEKICK_ROOT=str(root),
               LAB_SIDEKICK_STAGE="live-workflows", LAB_SIDEKICK_PROVIDER=args.provider,
               LAB_SIDEKICK_LIVE="1", SENTIENT_CODEX_RUNTIME_ROOT=str(runtime), SENTIENT_VAULT_ROOT=str(root / "vault"))
    (artifacts / f"{args.provider}-root.txt").write_text(str(root) + "\n")
    print(f"LIVE ROOT: {root}", flush=True)
    with (root / "live.stdout.log").open("ab") as out, (root / "live.stderr.log").open("ab") as err:
        process = subprocess.Popen([str(executable)], env=env, cwd=root, stdout=out, stderr=err, start_new_session=True)
        (root / "runner-pid.txt").write_text(str(process.pid))
        try:
            code = process.wait()
        except KeyboardInterrupt:
            acceptance.stop_owned(process, root)
            raise
    print(json.dumps({"root": str(root), "exit_code": code}), flush=True)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
