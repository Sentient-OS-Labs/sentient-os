#!/usr/bin/env python3
"""Test real helper takeover and native capture through the signed app's debug lab.

Start the competing helper first (for example with Codex computer use). This test never
quits it itself: production Sentient must do that. --suspend simulates an unresponsive
helper and resumes it on failure. No provider calls, user-app actions or TCC changes.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--foreign-app", type=Path,
                        default=Path.home() / ".codex/computer-use/Codex Computer Use.app")
    parser.add_argument("--suspend", action="store_true")
    args = parser.parse_args()
    app = args.app.expanduser().resolve()
    foreign = args.foreign_app.expanduser().resolve()
    foreign_info = plistlib.loads((foreign / "Contents/Info.plist").read_bytes())
    assert foreign_info["CFBundleIdentifier"] == "com.openai.sky.CUAService"
    private = Path.home() / "Library/Application Support/SentientOS/Private Codex"
    assert not foreign.is_relative_to(private.resolve()), "Do not suspend Sentient's helper"
    expected = str(foreign / "Contents/MacOS" / foreign_info["CFBundleExecutable"])
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines()
    pids = [int(parts[0]) for row in rows if len(parts := row.strip().split(None, 1)) == 2 and parts[1] == expected]
    assert len(pids) == 1, "Start exactly one competing helper before this test"
    pid = pids[0]
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    root = Path(tempfile.mkdtemp(prefix="sentient-helper-takeover-")).resolve()
    (root / "evidence").mkdir()
    env = os.environ.copy()
    env.update(SENTIENT_SELFTEST="nativecua", LAB_ROOT=str(root), LAB_COMMAND="helper-takeover", LAB_NAME="takeover")
    print(f"Artifacts: {root}", flush=True)
    if args.suspend:
        os.kill(pid, signal.SIGSTOP)
    try:
        with (root / "run.log").open("w") as output:
            subprocess.run([str(executable)], env=env, stdout=output, stderr=subprocess.STDOUT,
                           timeout=45, check=True)
        result = json.loads((root / "evidence/takeover.json").read_text())
        checks = ["passiveConflictHidden", "passiveCheckPreservedOtherHelper", "foregroundGateReady",
                  "foreignHelpersTerminated", "privateHelperReused", "privateHelperPath", "captureVerified"]
        assert "error" not in result, result.get("error")
        assert all(result.get(key) is True for key in checks), result
        print(f"PASS: {len(checks)} live takeover checks and actual native capture; "
              f"{result['finished'] - result['started']:.2f}s", flush=True)
    finally:
        # Never signal a reused PID: match the same executable again before resuming.
        if args.suspend:
            live = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
            if live.stdout.strip() == expected:
                try:
                    os.kill(pid, signal.SIGCONT)
                except ProcessLookupError:
                    pass


if __name__ == "__main__":
    main()
