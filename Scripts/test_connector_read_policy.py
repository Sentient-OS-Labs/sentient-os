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
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DRIVE = "connector_5f3c8c41a1e54ad7a76272c89e2554fa"
GMAIL = "connector_2128aebfecb84f64a069897515042a44"
CALENDAR = "connector_947e0d954944416db111db556030eea6"
OTHER = "connector_00000000000000000000000000000001"
SLACK = "asdk_app_00000000000000000000000000000002"


def tool(name, connector, title, read=False):
    return {
        "name": name, "title": title, "description": "Synthetic fixture operation.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": read, "destructiveHint": False, "openWorldHint": False},
        "_meta": {
            "connector_id": connector,
            "connector_name": {DRIVE: "Drive", GMAIL: "Gmail", CALENDAR: "Calendar", SLACK: "Slack"}.get(connector, "Other"),
            "_codex_apps": {"resource_uri": f"connector://{connector}/tools/{name}",
                            "contains_mcp_source": True, "connector_id": connector},
        },
    }


class Fixture:
    def __init__(self):
        self.reset()

    def reset(self):
        self.calls, self.requests = [], []
        self.force, self.sent = None, 0
        self.force_count = 1
        self.force_args = {}
        self.tools = [
            tool("gdrive.search", DRIVE, "search", True),
            tool("gdrive.create_file", DRIVE, "create_file"),
            tool("gdrive.new_write", DRIVE, "new_write"),
            tool("gdrive.get_profile", DRIVE, "get_profile", True),
            tool("gmail.search_emails", GMAIL, "search_emails", True),
            tool("gmail.create_draft", GMAIL, "create_draft"),
            tool("gcal.search_events", CALENDAR, "search_events", True),
            tool("other.write", OTHER, "write"),
            tool("orphan.write", None, "write"),
        ]
        self.tools[-1]["_meta"] = {}
        for name, read in [("slack_search_public_and_private", True), ("slack_read_thread", True),
                           ("slack_send_message", False), ("slack_send_message_draft", False),
                           ("slack_delete_message", False), ("slack_future_write", False)]:
            entry = tool("slack." + name, SLACK, name, read)
            entry["inputSchema"] = {"type": "object", "properties": {
                "channel_id": {"type": "string"}, "message": {"type": "string"},
                "draft_id": {"type": "string"}, "reply_broadcast": {"type": "boolean"}},
                "additionalProperties": False}
            if name == "slack_delete_message": entry["annotations"]["destructiveHint"] = True
            self.tools.append(entry)


def make_handler(fixture):
    class Handler(BaseHTTPRequestHandler):
        def handle(self):
            try: super().handle()
            except (BrokenPipeError, ConnectionResetError): pass

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
            if fixture.force and fixture.sent < fixture.force_count:
                fixture.sent += 1
                namespace, name = fixture.force
                item = {"type": "function_call", "id": "fc_fixture_"+str(fixture.sent), "call_id": "call_fixture_"+str(fixture.sent),
                        "namespace": namespace, "name": name, "arguments": json.dumps(fixture.force_args)}
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
    parser.add_argument("--only-prefix", help="Run only matching case names while investigating a failure")
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    recipes = json.loads(options.recipes.read_text())
    fixture = Fixture()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(fixture))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    results = []

    def run(label, recipe, namespace, name, expected_calls, mutate=None, old_policy=False, arguments=None, repetitions=1):
        if options.only_prefix and not label.startswith(options.only_prefix): return
        fixture.reset()
        if mutate:
            mutate(fixture.tools)
        fixture.force = ("mcp__codex_apps__" + namespace, name)
        fixture.force_args = arguments or {}
        fixture.force_count = repetitions
        args = copy.copy(recipes[recipe][:-1])
        run_ids = []
        def fresh_run(_):
            value = str(uuid.uuid4()).upper()
            run_ids.append(value)
            return value
        for index, value in enumerate(args):
            if value.startswith("hooks.") or value.startswith("hooks="):
                args[index] = re.sub(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", fresh_run, value)
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
        for run_id in run_ids:
            Path(f"/private/tmp/sentient-slack-send-{os.getuid()}-{run_id}").unlink(missing_ok=True)
        # Require a response after every forced call so startup failures cannot pass denials.
        passed = process.returncode == 0 and len(fixture.requests) == repetitions + 1 and fixture.calls == expected_calls
        surface = {t["name"]: [v["name"] for v in t.get("tools", [])]
                   for t in fixture.requests[0].get("tools", []) if t.get("name", "").startswith("mcp__")} if fixture.requests else {}
        if recipe not in ["action", "slack-action", "slack-draft", "slack-approved"] and not old_policy:
            passed = passed and all("write" not in name and "create" not in name
                                    for tools in surface.values() for name in tools)
        if recipe == "source" and fixture.requests:
            prohibited = ("exec_command", "shell", "view_image", "browser", "spawn_agent", "computer")
            names = [t.get("name", "") for t in fixture.requests[0].get("tools", [])]
            passed = passed and not any(any(word in name for word in prohibited) for name in names)
        outputs = [v.get("output") for r in fixture.requests for v in r.get("input", [])
                   if v.get("type") == "function_call_output"]
        result = {"name": label, "passed": passed, "exit": process.returncode,
                  "calls": list(fixture.calls), "surface": surface, "call_outputs": outputs}
        results.append(result)
        print(f"{'PASS' if passed else 'FAIL'} {label}: connector calls={fixture.calls}", flush=True)

    try:
        run("old-policy-permits-create", "drive", "drive", "gdrive_create_file", ["gdrive.create_file"], old_policy=True)
        run("drive-read", "drive", "drive", "gdrive_search", ["gdrive.search"])
        if "source" in recipes:
            run("source-read", "source", "drive", "gdrive_search", ["gdrive.search"])
            run("source-create-denied", "source", "drive", "gdrive_create_file", [])
        if "identity" in recipes:
            run("identity-read", "identity", "drive", "gdrive_get_profile", ["gdrive.get_profile"])
            run("identity-content-denied", "identity", "drive", "gdrive_search", [])
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
        run("action-destructive-denied", "action", "drive", "gdrive_create_file", [],
            lambda tools: tools[1]["annotations"].update(destructiveHint=True))
        if "slack-source" in recipes:
            message = {"channel_id": "CFIXTURE", "message": "Synthetic fixture"}
            run("slack-source-read", "slack-source", "slack", "_slack_search_public_and_private", ["slack.slack_search_public_and_private"])
            run("slack-source-send-denied", "slack-source", "slack", "_slack_send_message", [], arguments=message)
            run("slack-task-read-send-denied", "slack-task-read", "slack", "_slack_send_message", [], arguments=message)
            run("slack-send", "slack-action", "slack", "_slack_send_message", ["slack.slack_send_message"], arguments=message)
            run("slack-draft", "slack-draft", "slack", "_slack_send_message_draft", ["slack.slack_send_message_draft"], arguments=message)
            run("slack-draft-send-denied", "slack-draft", "slack", "_slack_send_message", [], arguments=message)
            run("slack-delete-denied", "slack-action", "slack", "_slack_delete_message", [])
            run("slack-new-write-denied", "slack-action", "slack", "_slack_future_write", [])
            run("slack-other-service-denied", "slack-action", "drive", "gdrive_create_file", [])
            run("slack-draft-consumption-denied", "slack-action", "slack", "_slack_send_message", [], arguments={**message, "draft_id": "existing-fixture"})
            run("slack-broadcast-denied", "slack-action", "slack", "_slack_send_message", [], arguments={**message, "reply_broadcast": True})
            run("slack-duplicate-send-denied", "slack-action", "slack", "_slack_send_message", ["slack.slack_send_message"], arguments=message, repetitions=2)
            run("slack-reviewed-message", "slack-approved", "slack", "_slack_send_message", ["slack.slack_send_message"], arguments={**message, "message": "Approved fixture"})
            run("slack-altered-message-denied", "slack-approved", "slack", "_slack_send_message", [], arguments={**message, "message": "Altered fixture"})
    finally:
        server.shutdown()
        server.server_close()
        (options.output / "results.json").write_text(json.dumps(results, indent=2))
    return 0 if results and all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
