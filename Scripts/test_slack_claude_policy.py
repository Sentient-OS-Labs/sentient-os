#!/usr/bin/env python3
"""Run exported Claude Slack policies with the real CLI and loopback-only fake services.

No real Slack call or model inference occurs. Authentication is synthetic, and headers are
never recorded. Reuses the connector fixture transport; only Claude's model envelope differs.
"""
import argparse
import json
import os
import subprocess
import threading
import re
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from test_connector_read_policy import Fixture, make_handler, SLACK


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipes", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--claude", default=str(Path.home()/".local/bin/claude"))
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    recipes = json.loads(options.recipes.read_text())
    fixture = Fixture()
    base_handler = make_handler(fixture)

    class Handler(base_handler):
        def handle(self):
            try: super().handle()
            except (BrokenPipeError, ConnectionResetError): pass

        def do_GET(self):
            self.reply({}, 405)

        def do_POST(self):
            if not self.path.startswith("/v1/messages"):
                return super().do_POST()
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            if "count_tokens" in self.path:
                return self.reply({"input_tokens": 10})
            fixture.requests.append(body)
            call = fixture.sent < fixture.force_count
            fixture.sent += 1
            block = ({"type": "tool_use", "id": "toolu_fixture_"+str(fixture.sent), "name": fixture.force,
                      "input": {}} if call else {"type": "text", "text": ""})
            message = {"id": "msg_fixture", "type": "message", "role": "assistant", "content": [],
                "model": body.get("model", "fixture"), "stop_reason": None,
                "usage": {"input_tokens": 10, "output_tokens": 1}}
            events = [("message_start", {"message": message}),
                ("content_block_start", {"index": 0, "content_block": block}),
                ("content_block_delta", {"index": 0, "delta":
                    {"type": "input_json_delta", "partial_json": json.dumps(fixture.force_args)} if call
                    else {"type": "text_delta", "text": "Fixture complete."}}),
                ("content_block_stop", {"index": 0}),
                ("message_delta", {"delta": {"stop_reason": "tool_use" if call else "end_turn", "stop_sequence": None},
                                   "usage": {"output_tokens": 10}}), ("message_stop", {})]
            data = "".join(f"event: {kind}\ndata: {json.dumps({'type':kind, **payload})}\n\n" for kind,payload in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    results = []

    def run(label, recipe, name, expected, arguments=None, missing_helper=False, repetitions=1):
        fixture.reset()
        fixture.tools = [dict(tool, name=tool["name"].removeprefix("slack."))
                         for tool in fixture.tools if tool.get("_meta", {}).get("connector_id") == SLACK]
        fixture.force = "mcp__claude_ai_Slack__" + name
        fixture.force_args = arguments or {}
        fixture.force_count = repetitions
        args = list(recipes["claude-slack-" + recipe])
        if recipe == "computer": del args[1]  # fixture prompt is supplied on stdin
        index = args.index("--settings") + 1
        settings = json.loads(args[index])
        settings["allowedMcpServers"] = [{"serverName": "claude_ai_Slack"}]
        run_ids = []
        def fresh_run(_):
            value = str(uuid.uuid4()).upper()
            run_ids.append(value)
            return value
        for group in settings.get("hooks", {}).get("PreToolUse", []):
            for hook in group["hooks"]:
                hook["command"] = re.sub(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", fresh_run, hook["command"])
        if missing_helper:
            for group in settings.get("hooks", {}).get("PreToolUse", []):
                for hook in group["hooks"]:
                    hook["command"] = "/missing-sentient-fixture || { echo 'Fixture policy unavailable' >&2; exit 2; }"
        args[index] = json.dumps(settings)
        if "--mcp-config" in args:
            index = args.index("--mcp-config")
            del args[index:index+2]
        args += ["--strict-mcp-config", "--mcp-config", json.dumps({"mcpServers": {
            "claude_ai_Slack": {"type": "http", "url": base+"/mcp"}}}), "--no-session-persistence"]
        env = dict(os.environ)
        env.pop("ANTHROPIC_AUTH_TOKEN", None)
        env.update({"ANTHROPIC_API_KEY": "synthetic-fixture", "ANTHROPIC_BASE_URL": base,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
            "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"})
        with (options.output/f"{label}.stdout.jsonl").open("w") as out, (options.output/f"{label}.stderr.log").open("w") as err:
            result = subprocess.run([options.claude, *args], input="Perform the synthetic fixture operation.",
                text=True, cwd=options.output, env=env, stdout=out, stderr=err, timeout=40)
        for run_id in run_ids:
            Path(f"/private/tmp/sentient-slack-send-{os.getuid()}-{run_id}").unlink(missing_ok=True)
        passed = result.returncode == 0 and len(fixture.requests) == repetitions + 1 and fixture.calls == expected
        results.append({"name": label, "passed": passed, "exit": result.returncode,
                        "modelRequests": len(fixture.requests), "calls": list(fixture.calls)})
        print(f"{'PASS' if passed else 'FAIL'} {label}: calls={fixture.calls}", flush=True)

    message = {"channel_id": "CFIXTURE", "message": "Synthetic fixture"}
    try:
        run("source-read", "source", "slack_search_public_and_private", ["slack_search_public_and_private"])
        run("source-send-denied", "source", "slack_send_message", [], message)
        run("task-read-send-denied", "task-read", "slack_send_message", [], message)
        run("send", "action", "slack_send_message", ["slack_send_message"], message)
        run("draft", "draft", "slack_send_message_draft", ["slack_send_message_draft"], message)
        run("draft-send-denied", "draft", "slack_send_message", [], message)
        run("delete-denied", "action", "slack_delete_message", [])
        run("new-write-denied", "action", "slack_future_write", [])
        run("draft-consumption-denied", "action", "slack_send_message", [], {**message, "draft_id": "existing-fixture"})
        run("broadcast-denied", "action", "slack_send_message", [], {**message, "reply_broadcast": True})
        run("computer-send", "computer", "slack_send_message", ["slack_send_message"], message)
        run("computer-new-write-denied", "computer", "slack_future_write", [])
        run("computer-broadcast-denied", "computer", "slack_send_message", [], {**message, "reply_broadcast": True})
        run("missing-helper-denied", "action", "slack_send_message", [], message, missing_helper=True)
        run("duplicate-send-denied", "action", "slack_send_message", ["slack_send_message"], message, repetitions=2)
        run("reviewed-message", "approved", "slack_send_message", ["slack_send_message"], {**message, "message": "Approved fixture"})
        run("altered-message-denied", "approved", "slack_send_message", [], {**message, "message": "Altered fixture"})
    finally:
        server.shutdown()
        server.server_close()
        (options.output/"results.json").write_text(json.dumps(results, indent=2))
    return 0 if results and all(result["passed"] for result in results) else 1

if __name__ == "__main__": raise SystemExit(main())
