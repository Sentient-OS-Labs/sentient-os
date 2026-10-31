#!/usr/bin/env python3
"""Read live relay state and prepare a local version-upload package. Never uploads or deploys.

Requires a freshly verified --expected-version and an existing Wrangler dry-run bundle.
Use CLOUDFLARE_API_TOKEN or explicitly provide --wrangler-config. Credential values are never written.
"""
import argparse
import email.parser
import email.policy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--account-id", required=True)
parser.add_argument("--worker", required=True)
parser.add_argument("--expected-version", required=True)
parser.add_argument("--bundle", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--wrangler-config", type=Path)
args = parser.parse_args()
if not re.fullmatch(r"[a-f0-9]{32}", args.account_id) or not re.fullmatch(r"[a-z0-9-]{1,100}", args.worker):
    raise SystemExit("Invalid account or Worker identifier")
credential = os.environ.get("CLOUDFLARE_API_TOKEN")
if not credential and args.wrangler_config:
    match = re.search(r'oauth_token\s*=\s*"([^\"]+)"', args.wrangler_config.read_text())
    credential = match[1] if match else None
if not credential:
    raise SystemExit("Provide Cloudflare read credentials; nothing was changed")
base = f"https://api.cloudflare.com/client/v4/accounts/{args.account_id}/workers/scripts/{args.worker}"


def get(path):
    request = urllib.request.Request(base + path, headers={"Authorization": "Bearer " + credential})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read(8_000_001)
        if len(data) > 8_000_000:
            raise SystemExit("Unexpectedly large Worker response")
        return data, response.headers


deployment = json.loads(get("/deployments")[0])["result"]["deployments"][0]
if deployment["versions"] != [{"version_id": args.expected_version, "percentage": 100}]:
    raise SystemExit("Live deployment changed. Review it before preparing a replacement")
settings = json.loads(get("/settings")[0])["result"]
raw, headers = get("/content/v2")
parts = email.parser.BytesParser(policy=email.policy.default).parsebytes(
    ("Content-Type: " + headers["content-type"] + "\r\n\r\n").encode() + raw)
modules = [p.get_payload(decode=True) for p in parts.iter_parts()]
expected = json.loads((ROOT / "HostedInference/relay/provenance.json").read_text())["legacy_sha256"]
if len(modules) != 1 or hashlib.sha256(modules[0]).hexdigest() != expected:
    raise SystemExit("Live relay source differs from the reviewed snapshot. Integrate that change first")
if hashlib.sha256((ROOT / "HostedInference/relay/legacy-doubletap.mjs").read_bytes()).hexdigest() != expected:
    raise SystemExit("Local relay snapshot changed")
secret_names = sorted(b["name"] for b in settings["bindings"] if b["type"] == "secret_text")
objects = [b for b in settings["bindings"] if b["type"] == "durable_object_namespace"]
if len(objects) != 1 or objects[0]["name"] != "COUNTERS" or objects[0]["class_name"] != "Counter":
    raise SystemExit("Review changed Durable Object bindings before packaging")
if "ANTHROPIC_API_KEY" not in secret_names or "OPENAI_API_KEY" not in secret_names:
    raise SystemExit("The expected existing relay secrets are not present")
if any(b["type"] not in ["secret_text", "durable_object_namespace", "plain_text"] for b in settings["bindings"]):
    raise SystemExit("Review new binding types before packaging")
output = args.output.resolve()
output.mkdir(mode=0o700, parents=True, exist_ok=False)
shutil.copyfile(args.bundle, output / "index.mjs")
bindings = [b for b in settings["bindings"] if b["type"] == "plain_text" and b["name"] != "SENTIENT_HOSTED_ROUTES_ENABLED"]
bindings.append({"name": "SENTIENT_HOSTED_ROUTES_ENABLED", "type": "plain_text", "text": "false"})
metadata = {k: settings[k] for k in ["compatibility_date", "compatibility_flags", "usage_model", "placement", "tags", "tail_consumers", "logpush"] if k in settings}
metadata.update(main_module="index.mjs", bindings=bindings, keep_bindings=["secret_text", "durable_object_namespace"],
                observability={"enabled": False}, annotations={"workers/message": "Hosted connector integration; admission remains disabled"})
(output / "upload-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
(output / "review.json").write_text(json.dumps({
    "worker": args.worker, "expected_deployment": deployment["id"], "expected_version": args.expected_version,
    "legacy_sha256": expected, "bundle_sha256": hashlib.sha256(args.bundle.read_bytes()).hexdigest(),
    "preserved_secret_names": secret_names, "preserved_durable_objects": objects,
    "hosted_routes_enabled": False, "observability_change": "Disabled to avoid recording hosted callback URLs and request context",
    "production_actions_performed": []}, indent=2) + "\n")
print("Prepared local review package:", output)
print("No upload, migration, secret change, funding change, or deployment was performed.")
