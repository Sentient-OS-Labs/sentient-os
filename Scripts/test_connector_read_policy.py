#!/usr/bin/env python3
"""Exercise production connector argv with a real Codex CLI and loopback-only fixtures.

First run the Debug app with SENTIENT_SELFTEST=connectorlab LAB_CMD=policycheck and
LAB_POLICY_OUTPUT=/tmp/connector-args.json. Then run this script with --recipes pointing
to that file. No model service or real connector action is used. The existing CLI login
may be consulted for startup, but all model and hosted-connector requests go to the local
fake server. Headers and credentials are never recorded. Temporary connector scaffolding.
"""

import argparse
import copy
import json
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DRIVE = "connector_5f3c8c41a1e54ad7a76272c89e2554fa"
GMAIL = "connector_2128aebfecb84f64a069897515042a44"
CALENDAR = "connector_947e0d954944416db111db556030eea6"
OTHER = "connector_00000000000000000000000000000001"


def tool(name, connector, title, read=False):
    return {
        "name": name, "title": title, "description": "Synthetic fixture operation.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": read, "destructiveHint": False, "openWorldHint": False},
        "_meta": {
            "connector_id": connector,
            "connector_name": {DRIVE: "Drive", GMAIL: "Gmail", CALENDAR: "Calendar"}.get(connector, "Other"),
            "_codex_apps": {"resource_uri": f"connector://{connector}/tools/{name}",
                            "contains_mcp_source": True, "connector_id": connector},
        },
    }


class Fixture:
    def __init__(self):
        self.reset()

    def reset(self):
        self.calls, self.requests = [], []
        self.force, self.sent = None, False
        self.tools = [
            tool("gdrive.search", DRIVE, "search", True),
            tool("gdrive.create_file", DRIVE, "create_file"),
            tool("gdrive.new_write", DRIVE, "new_write"),
            tool("gmail.search_emails", GMAIL, "search_emails", True),
            tool("gmail.create_draft", GMAIL, "create_draft"),
            tool("gcal.search_events", CALENDAR, "search_events", True),
            tool("other.write", OTHER, "write"),
            tool("orphan.write", None, "write"),
        ]
        self.tools[-1]["_meta"] = {}


def make_handler(fixture):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, value, status=200):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if "connectors/directory" in self.path:
                self.reply({"apps": [{"id": DRIVE, "name": "Drive", "description": "fixture"}], "nextToken": None})
            elif "models" in self.path:
                self.reply({"models": []})
            else:
                # Never return download URLs or proxy a request to a real service.
                self.reply({}, 404)

        def do_DELETE(self):
            self.reply({})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            if "method" in body:
                if "id" not in body:
                    self.reply({}, 202)
                    return
                method = body["method"]
                if method == "initialize":
                    result = {"protocolVersion": body["params"]["protocolVersion"], "capabilities": {"tools": {}},
                              "serverInfo": {"name": "sentient-fixture", "version": "1"}}
                elif method == "tools/list":
                    result = {"tools": fixture.tools}
                elif method == "tools/call":
                    fixture.calls.append(body["params"]["name"])
                    result = {"content": [{"type": "text", "text": "Fixture call completed."}], "isError": False}
                else:
                    result = {}
                self.reply({"jsonrpc": "2.0", "id": body["id"], "result": result})
                return
            if not self.path.endswith("/responses"):
                self.reply({})
                return
            fixture.requests.append(body)
            if fixture.force and not fixture.sent:
                fixture.sent = True
                namespace, name = fixture.force
                item = {"type": "function_call", "id": "fc_fixture", "call_id": "call_fixture",
                        "namespace": namespace, "name": name, "arguments": "{}"}
            else:
                item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                        "content": [{"type": "output_text", "text": "Fixture complete."}]}
            rid = "resp_" + uuid.uuid4().hex
            response = {"id": rid, "object": "response", "status": "completed", "output": [item],
                        "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}
            events = [
                ("response.created", {"response": {"id": rid, "object": "response", "status": "in_progress", "output": []}}),
                ("response.output_item.added", {"output_index": 0, "item": item}),
                ("response.output_item.done", {"output_index": 0, "item": item}),
                ("response.completed", {"response": response}),
            ]
            data = "".join(f"event: {kind}\ndata: {json.dumps({'type': kind, **payload})}\n\n"
                           for kind, payload in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipes", type=Path, required=True)
    parser.add_argument("--codex", default=str(Path.home() / ".local/bin/codex"))
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    recipes = json.loads(options.recipes.read_text())
    fixture = Fixture()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(fixture))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    results = []

    def run(label, recipe, namespace, name, expected_calls, mutate=None, old_policy=False):
        fixture.reset()
        if mutate:
            mutate(fixture.tools)
        fixture.force = ("mcp__codex_apps__" + namespace, name)
        args = copy.copy(recipes[recipe][:-1])
        args[args.index("-m") + 1] = "fixture"
        if old_policy:
            index = next(i for i, value in enumerate(args) if value.startswith("apps = "))
            del args[index - 1:index + 1]
            args += ["-c", f"apps.{DRIVE}.open_world_enabled=false", "-c", f"apps.{DRIVE}.destructive_enabled=false"]
        overrides = [
            'model_provider="fixture"',
            f'model_providers.fixture={{name="Fixture",base_url="{base}/v1",wire_api="responses",requires_openai_auth=false}}',
            f'chatgpt_base_url="{base}"', 'features.apps=true', 'features.code_mode=false',
            'features.tool_search=false', 'analytics.enabled=false', 'web_search="disabled"',
            'model_providers.fixture.request_max_retries=0',
        ]
        if "--ignore-user-config" not in args:
            args.append("--ignore-user-config")
        args += ["--ephemeral", *[x for value in overrides for x in ("-c", value)], "-"]
        with (options.output / f"{label}.stdout.jsonl").open("w") as out, (options.output / f"{label}.stderr.log").open("w") as err:
            process = subprocess.run([options.codex, *args], input="Perform the synthetic fixture operation.",
                                     text=True, stdout=out, stderr=err, cwd=options.output, timeout=40)
        # Require two actual model requests so an early startup failure cannot pass a deny test.
        passed = process.returncode == 0 and len(fixture.requests) == 2 and fixture.calls == expected_calls
        surface = {t["name"]: [v["name"] for v in t.get("tools", [])]
                   for t in fixture.requests[0].get("tools", []) if t.get("name", "").startswith("mcp__")} if fixture.requests else {}
        if recipe != "action" and not old_policy:
            passed = passed and all("write" not in name and "create" not in name
                                    for tools in surface.values() for name in tools)
        outputs = [v.get("output") for r in fixture.requests for v in r.get("input", [])
                   if v.get("type") == "function_call_output"]
        result = {"name": label, "passed": passed, "exit": process.returncode,
                  "calls": list(fixture.calls), "surface": surface, "call_outputs": outputs}
        results.append(result)
        print(f"{'PASS' if passed else 'FAIL'} {label}: connector calls={fixture.calls}", flush=True)

    try:
        run("old-policy-permits-create", "drive", "drive", "gdrive_create_file", ["gdrive.create_file"], old_policy=True)
        run("drive-read", "drive", "drive", "gdrive_search", ["gdrive.search"])
        run("drive-create-denied", "drive", "drive", "gdrive_create_file", [])
        run("new-write-denied", "drive", "drive", "gdrive_new_write", [])
        run("gmail-read", "gmail", "gmail", "_search_emails", ["gmail.search_emails"])
        run("calendar-read", "calendar", "calendar", "gcal_search_events", ["gcal.search_events"])
        run("research-read", "research", "drive", "gdrive_search", ["gdrive.search"])
        run("research-create-denied", "research", "drive", "gdrive_create_file", [])
        run("drive-excluded-from-gmail-read", "gmail", "drive", "gdrive_create_file", [])
        run("inherited-approval-replaced", "inherited", "drive", "gdrive_create_file", [])
        run("changed-read-hint-denied", "drive", "drive", "gdrive_search", [],
            lambda tools: tools[0]["annotations"].update(readOnlyHint=False))
        run("missing-read-hint-denied", "drive", "drive", "gdrive_search", [],
            lambda tools: tools[0]["annotations"].pop("readOnlyHint"))
        run("missing-identity-denied", "drive", "drive", "gdrive_search", [],
            lambda tools: tools[0].update(_meta={}))
        run("user-fired-create", "action", "drive", "gdrive_create_file", ["gdrive.create_file"])
    finally:
        server.shutdown()
        server.server_close()
        (options.output / "results.json").write_text(json.dumps(results, indent=2))
    return 0 if results and all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
