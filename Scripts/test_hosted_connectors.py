#!/usr/bin/env python3
"""Run the actual Debug app/CLIs against production gateways and SQL with synthetic services.

Requires --app /absolute/path/to/Contents/MacOS/Sentient OS. Never reads a user mailbox,
uses a real provider key, drives the desktop, or writes the normal preferences/data store.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import urllib.request
import uuid
import hashlib
import tarfile

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
args = parser.parse_args()
root = Path(tempfile.mkdtemp(prefix="sentient-connectors-")).resolve()
root.chmod(0o700)
(root / ".fixture").write_text("1\n")
release = json.loads((REPO / "Sentient OS macOS/Cloud/BundledCodexRelease.json").read_text())
package = "cli-" + release["cli"]["version"]
installed = Path.home() / "Library/Application Support/SentientOS/Private Codex/releases" / package
# Copy verified software only, never the user's .codex login, sessions, plugins or settings.
destination = root / "runtime/releases" / package
if installed.is_dir():
    shutil.copytree(installed, destination)
else:
    artifact = release["cli"]
    archive = Path(tempfile.gettempdir()) / ("sentient-verified-" + artifact["sha256"] + ".tgz")
    if not archive.exists():
        subprocess.run(["curl", "-fsSL", "--connect-timeout", "10", "--max-time", "120", "--output", str(archive),
                        "https://sentient-downloads.sentient-doubletap-relay.workers.dev/releases/" + artifact["filename"]], check=True)
    if archive.stat().st_size != artifact["bytes"] or hashlib.sha256(archive.read_bytes()).hexdigest() != artifact["sha256"]:
        raise SystemExit("Approved CLI archive failed integrity verification")
    expected = {item["path"]: item for item in artifact["files"]}
    destination.mkdir(parents=True)
    with tarfile.open(archive, "r:gz") as package_archive:
        for member in package_archive.getmembers():
            name = member.name.removeprefix("./")
            if member.isdir():
                continue
            if not member.isfile() or name not in expected:
                raise SystemExit("Unexpected archive entry")
            output = destination / name
            output.parent.mkdir(parents=True, exist_ok=True)
            data = package_archive.extractfile(member).read()
            if len(data) != expected[name]["bytes"] or hashlib.sha256(data).hexdigest() != expected[name]["sha256"]:
                raise SystemExit("CLI member failed integrity verification")
            output.write_bytes(data)
            output.chmod(0o755 if expected[name]["executable"] else 0o644)
server = subprocess.Popen(["node", "test/support/app-server.mjs"], cwd=REPO / "HostedInference",
                          stdout=subprocess.PIPE, stderr=(root / "server.stderr").open("w"), text=True)
try:
    gateway = json.loads(server.stdout.readline())["url"]
    suite = "ai.sentient.connector-fixture." + str(uuid.uuid4())
    for phase in ["lifecycle", "source-first", "source-complete", "structured", "bridge", "policy", "recovery", "bounded", "summary-cli", "render"]:
        if phase == "source-complete":
            urllib.request.urlopen(gateway + "/__fixture/fail-next", timeout=10).close()
        if phase == "bounded":
            urllib.request.urlopen(gateway + "/__fixture/many-pages", timeout=10).close()
        if phase == "summary-cli":
            urllib.request.urlopen(gateway + "/__fixture/one-page", timeout=10).close()
        environment = dict(os.environ, SENTIENT_SELFTEST="hostedconnectors", LAB_HOSTED_CONNECTOR_ROOT=str(root),
                           LAB_HOSTED_CONNECTOR_GATEWAY=gateway, LAB_HOSTED_CONNECTOR_SUITE=suite,
                           LAB_HOSTED_CONNECTOR_PHASE=phase, SENTIENT_CODEX_RUNTIME_ROOT=str(root / "runtime"))
        with (root / (phase + ".log")).open("w") as output:
            result = subprocess.run([str(args.app.resolve())], env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=180)
        receipt = root / (phase + ".json")
        if result.returncode or not receipt.exists() or not json.loads(receipt.read_text())["passed"]:
            raise SystemExit(f"FAIL {phase}; inspect {root}")
        print(f"PASS {phase}: actual app boundary", flush=True)
    status = json.load(urllib.request.urlopen(gateway + "/__fixture/status", timeout=10))
    (root / "gateway-evidence.json").write_text(json.dumps(status, indent=2) + "\n")
    assert status["modelCalls"] >= 4 and status["toolResults"] >= 2, status
    assert status["selectionCalls"] >= 1 and status["summaryCalls"] >= 1, status
    assert any(row["status"] == "failed" for row in status["operations"]), status
    assert all(row["phase"] == "completed" for row in status["runs"]), status
    print(f"PASS hosted connectors: real SwiftData restart, real Claude structured tools, real Codex/Claude bridge. Evidence: {root}")
finally:
    if 'gateway' in locals():
        try:
            status = json.load(urllib.request.urlopen(gateway + "/__fixture/status", timeout=10))
            (root / "gateway-evidence.json").write_text(json.dumps(status, indent=2) + "\n")
        except Exception:
            pass
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
