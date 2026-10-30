#!/usr/bin/env python3
"""Opt-in Google acceptance through the actual Debug connection UI and local gateway.

Requires the account owner's authorization before running. Use separate read-only auth configs
for Gmail, Google Calendar and Google Drive. No real model calls, writes, broad content reads,
production identities or production database are used. OAuth still grants persistent provider
access and Composio's project retention policy applies. Interact with each sheet and click Done.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
import urllib.request

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--key-file", type=Path, required=True)
parser.add_argument("--config-file", type=Path, required=True)
parser.add_argument("--services", nargs="+", choices=["gmail", "google-calendar", "google-drive"], default=["gmail", "google-calendar", "google-drive"])
args = parser.parse_args()
config = json.loads(args.config_file.read_text())
if set(config.get("auth_configs", {})) != {"gmail", "google-calendar", "google-drive"}:
    raise SystemExit("Exactly the three read-only Google acceptance configs are required")
root = Path(tempfile.mkdtemp(prefix="sentient-connectors-live-")).resolve()
root.chmod(0o700)
(root / ".fixture").write_text("1\n")
(root / "runtime").mkdir(mode=0o700)
suite = "ai.sentient.connector-fixture." + str(uuid.uuid4())
environment = dict(os.environ, COMPOSIO_ACCEPTANCE_ROOT=str(root),
                   COMPOSIO_DEV_KEY_FILE=str(args.key_file.resolve()), COMPOSIO_DEV_CONFIG_FILE=str(args.config_file.resolve()))
server = subprocess.Popen(["node", "test/support/app-server.mjs", "--live-composio"], cwd=REPO / "HostedInference",
                          env=environment, stdout=subprocess.PIPE, stderr=(root / "server.stderr").open("w"), text=True)
gateway = None
def phase(name, timeout=900):
    app_env = dict(os.environ, SENTIENT_SELFTEST="hostedconnectors", LAB_HOSTED_CONNECTOR_ROOT=str(root),
                   LAB_HOSTED_CONNECTOR_GATEWAY=gateway, LAB_HOSTED_CONNECTOR_SUITE=suite,
                   LAB_HOSTED_CONNECTOR_SERVICES=",".join(args.services),
                   LAB_HOSTED_CONNECTOR_PHASE=name, SENTIENT_CODEX_RUNTIME_ROOT=str(root / "runtime"))
    print("Running " + name, flush=True)
    with (root / (name + ".log")).open("w") as output:
        result = subprocess.run([str(args.app.resolve())], env=app_env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    receipt = root / (name + ".json")
    if result.returncode or not receipt.exists() or not json.loads(receipt.read_text())["passed"]:
        raise RuntimeError("Acceptance phase failed: " + name)
    print("PASS " + name, flush=True)
try:
    ready = json.loads(server.stdout.readline())
    gateway = ready["url"]
    token = root / "principal-token"
    token.write_text(ready["principal_token"])
    token.chmod(0o600)
    (root / "gateway-url").write_text(gateway)
    print("Private acceptance evidence: " + str(root), flush=True)
    for service in args.services:
        phase("live-connect-" + service)
    phase("live-read", 180)
    status = json.load(urllib.request.urlopen(gateway + "/__fixture/status", timeout=10))
    assert status["modelCalls"] == 0, "Real-account test must not call the inference fixture"
    tools = {"gmail": "gmail_search", "google-calendar": "google_calendar_list", "google-drive": "drive_search"}
    assert {row["tool"] for row in status["operations"]} == {tools[service] for service in args.services}
    (root / "gateway-evidence.json").write_text(json.dumps(status, indent=2) + "\n")
finally:
    if gateway:
        # Delete only this test principal's exact connections. Do not revoke shared OAuth grants.
        try:
            phase("live-cleanup", 60)
        except Exception:
            print("Cleanup remains pending in the private acceptance database: " + str(root), flush=True)
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
