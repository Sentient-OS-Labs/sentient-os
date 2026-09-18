#!/usr/bin/env python3
"""Exercise exported production direct-MCP recipes with both real CLIs and local fake models.

Only synthetic credentials are stored in a temporary Keychain item. The fixture never records
headers and never calls an external model or service. The app removes that item in finally.
"""

import argparse
import json
import os
import shlex
import subprocess
import threading
import uuid
import hashlib
import base64
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit, urlencode


class Fixture:
    def __init__(self):
        self.lock = threading.Lock()
        self.rotation = 0
        self.access = "synthetic-access-0"
        self.refresh = "synthetic-refresh-0"
        self.refresh_requests = 0
        self.challenge = None
        self.reset("read_item")

    def reset(self, target, reject_once=False, multiple=False):
        self.target = target
        self.calls = []
        self.requests = []
        self.sent = 0
        self.multiple = multiple
        self.reject_once = reject_once
        self.rejections = 0


def handler(fixture):
    class Handler(BaseHTTPRequestHandler):
        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                pass  # clients may close the optional notification stream immediately

        def log_message(self, *_):
            pass

        def reply(self, value, status=200, headers=None):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def stream(self, events):
            data = "".join(f"event: {kind}\ndata: {json.dumps(payload)}\n\n" for kind, payload in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            base = f"http://127.0.0.1:{self.server.server_port}"
            path = urlsplit(self.path).path
            if path == "/.well-known/oauth-protected-resource":
                self.reply({"resource": base + "/mcp", "authorization_servers": [base], "scopes_supported": ["mcp"]})
                return
            if path == "/.well-known/oauth-authorization-server":
                self.reply({"issuer": base, "authorization_endpoint": base + "/authorize", "token_endpoint": base + "/token",
                            "registration_endpoint": base + "/register", "code_challenge_methods_supported": ["S256"],
                            "token_endpoint_auth_methods_supported": ["none"]})
                return
            if path == "/authorize":
                params = parse_qs(urlsplit(self.path).query)
                fixture.challenge = params["code_challenge"][0]
                redirect = params["redirect_uri"][0] + "?" + urlencode({"code": "synthetic-code", "state": params["state"][0]})
                self.send_response(302)
                self.send_header("Location", redirect)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.reply({}, 405 if self.path == "/mcp" else 404)

        def do_DELETE(self):
            self.reply({})

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.path == "/token":
                form = parse_qs(raw.decode())
                credentials = fixture.second if form.get("client_id") == ["synthetic-second-client"] else fixture
                with credentials.lock:
                    if form.get("grant_type") == ["authorization_code"]:
                        verifier = form.get("code_verifier", [""])[0]
                        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
                        valid = form.get("code") == ["synthetic-code"] and challenge == fixture.challenge
                    else:
                        credentials.refresh_requests += 1
                        valid = form.get("refresh_token") == [credentials.refresh]
                    if not valid:
                        self.reply({"error": "invalid_grant"}, 400)
                        return
                    credentials.rotation += 1
                    prefix = "synthetic-second" if credentials is fixture.second else "synthetic"
                    credentials.access = f"{prefix}-access-{credentials.rotation}"
                    credentials.refresh = f"{prefix}-refresh-{credentials.rotation}"
                    self.reply({"access_token": credentials.access, "refresh_token": credentials.refresh,
                                "token_type": "Bearer", "expires_in": 300})
                return
            body = json.loads(raw or b"{}")
            if self.path == "/register":
                self.reply({"client_id": "synthetic-client", "token_endpoint_auth_method": "none",
                            "redirect_uris": body["redirect_uris"]}, 201)
                return
            if self.path == "/mcp":
                secondary = self.headers.get("Authorization") == "Bearer " + fixture.second.access
                if not secondary and self.headers.get("Authorization") != "Bearer " + fixture.access:
                    self.reply({"error": "invalid_token"}, 401, {"WWW-Authenticate": f'Bearer resource_metadata="http://127.0.0.1:{self.server.server_port}/.well-known/oauth-protected-resource"'})
                    return
                method = body.get("method")
                if "id" not in body:
                    self.reply({}, 202)
                    return
                if method == "initialize":
                    result = {"protocolVersion": body["params"]["protocolVersion"], "capabilities": {"tools": {}},
                              "serverInfo": {"name": "sentient-fixture", "version": "1"}}
                elif method == "tools/list":
                    result = {"tools": [{"name": name, "description": "Synthetic test operation", "inputSchema": {"type": "object", "properties": {}},
                                         "annotations": {"readOnlyHint": name == "read_item", "destructiveHint": name == "delete_item"}}
                                        for name in ("read_item", "create_item", "delete_item", "surprise_write")]}
                elif method == "tools/call":
                    if fixture.reject_once and fixture.rejections == 0:
                        fixture.rejections += 1
                        self.reply({"error": "invalid_token"}, 401)
                        return
                    account = ("second:" if secondary else "first:") if fixture.multiple else ""
                    fixture.calls.append(account + body["params"]["name"])
                    result = {"content": [{"type": "text", "text": "SYNTHETIC_OK"}], "isError": False}
                else:
                    result = {}
                self.reply({"jsonrpc": "2.0", "id": body["id"], "result": result})
                return
            if "count_tokens" in self.path:
                self.reply({"input_tokens": 100})
                return
            if self.path.startswith("/v1/messages"):
                fixture.requests.append(body)
                call = fixture.sent < (2 if fixture.multiple else 1)
                server_name = fixture.second_server_name if fixture.multiple and fixture.sent == 1 else fixture.server_name
                fixture.sent += 1
                if call:
                    names = [tool["name"] for tool in body.get("tools", []) if "sentient_" in tool.get("name", "")]
                    prefix = "mcp__" + server_name + "__" if fixture.multiple or not names else names[0].rsplit("__", 1)[0] + "__"
                    block = {"type": "tool_use", "id": "toolu_fixture_" + str(fixture.sent), "name": prefix + fixture.target, "input": {}}
                else:
                    block = {"type": "text", "text": "Fixture complete."}
                message = {"id": "msg_" + uuid.uuid4().hex, "type": "message", "role": "assistant", "content": [],
                           "model": body.get("model", "fixture"), "stop_reason": None,
                           "usage": {"input_tokens": 10, "output_tokens": 1}}
                events = [("message_start", {"type": "message_start", "message": message}),
                          ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": block}),
                          ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                          ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use" if call else "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 10}}),
                          ("message_stop", {"type": "message_stop"})]
                self.stream(events)
                return
            if self.path.endswith("/responses"):
                fixture.requests.append(body)
                if fixture.sent < (2 if fixture.multiple else 1):
                    server_name = fixture.second_server_name if fixture.multiple and fixture.sent == 1 else fixture.server_name
                    fixture.sent += 1
                    namespace = "mcp__" + server_name if fixture.multiple else next((t["name"] for t in body.get("tools", []) if "sentient_" in t.get("name", "")), "mcp__" + fixture.server_name)
                    item = {"type": "function_call", "id": "fc_fixture_" + str(fixture.sent), "call_id": "call_fixture_" + str(fixture.sent), "namespace": namespace,
                            "name": fixture.target, "arguments": "{}"}
                else:
                    item = {"type": "message", "id": "msg_fixture", "role": "assistant", "status": "completed",
                            "content": [{"type": "output_text", "text": "Fixture complete."}]}
                rid = "resp_" + uuid.uuid4().hex
                response = {"id": rid, "object": "response", "status": "completed", "output": [item],
                            "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}
                self.stream([(kind, {"type": kind, **payload}) for kind, payload in [
                    ("response.created", {"response": {"id": rid, "object": "response", "status": "in_progress", "output": []}}),
                    ("response.output_item.added", {"output_index": 0, "item": item}),
                    ("response.output_item.done", {"output_index": 0, "item": item}),
                    ("response.completed", {"response": response})]])
                return
            self.reply({})
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--engine", choices=["codex", "claude", "both"], default="both")
    options = parser.parse_args()
    # Header helpers execute with the fixture directory as cwd; redirection paths must be absolute.
    options.output = options.output.resolve()
    options.output.mkdir(parents=True, exist_ok=True)
    fixture = Fixture()
    fixture.second = Fixture()
    fixture.second.access = "synthetic-second-access-0"
    fixture.second.refresh = "synthetic-second-refresh-0"
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(fixture))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    env = dict(os.environ, SENTIENT_DIRECT_MCP_FIXTURE_URL=base + "/mcp")
    recipes_file = options.output / "recipes.json"
    export_env = dict(env, SENTIENT_SELFTEST="connectorlab", LAB_CMD="directfixture", LAB_DIRECT_OUTPUT=str(recipes_file))
    subprocess.run([str(options.app)], env=export_env, check=True, stdout=subprocess.DEVNULL, timeout=30)
    recipes = json.loads(recipes_file.read_text())
    fixture.server_name = recipes["server_name"]
    fixture.second_server_name = recipes["second_server_name"]
    results = []

    def run(engine, mode, target, expected, bypass=False, missing_hook=False, renewal=False):
        fixture.reset(target, reject_once=renewal, multiple=mode == "multiple")
        label = f"{engine}-{mode}-{target}" + ("-bypass" if bypass else "") + ("-missing-hook" if missing_hook else "") + ("-renew" if renewal else "")
        args = list(recipes[f"{engine}_{mode}"])
        child_env = dict(env)
        before = fixture.rotation
        if engine == "codex":
            args = args[:-1]
            for index, value in enumerate(args):
                if ".http_headers_helper=" in value:
                    key, encoded = value.split("=", 1)
                    # Codex intentionally scrubs arbitrary inherited helper variables. Supply
                    # the test-only loopback provider inside the fixture command itself.
                    command = "SENTIENT_DIRECT_MCP_FIXTURE_URL=" + shlex.quote(base + "/mcp") + " " + json.loads(encoded)
                    command += " 2>" + shlex.quote(str(options.output / (label + ".helper.stderr")))
                    args[index] = key + "=" + json.dumps(command)
            overrides = ['model_provider="fixture"', f'model_providers.fixture={{name="Fixture",base_url="{base}/v1",wire_api="responses",requires_openai_auth=false}}',
                         f'chatgpt_base_url="{base}"', 'features.apps=false', 'features.code_mode=false', 'features.tool_search=false',
                         'analytics.enabled=false', 'web_search="disabled"', 'model_providers.fixture.request_max_retries=0']
            args += ["--ephemeral", *[x for value in overrides for x in ("-c", value)], "-"]
        else:
            child_env.update(ANTHROPIC_BASE_URL=base, ANTHROPIC_AUTH_TOKEN="synthetic", ANTHROPIC_API_KEY="synthetic",
                             CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
            args += ["--no-session-persistence"]
            if bypass:
                index = args.index("--permission-mode")
                del args[index:index + 2]
                args += ["--dangerously-skip-permissions"]
                args[args.index("--settings") + 1] = recipes["claude_bypass_settings"]
            if missing_hook:
                index = args.index("--settings") + 1
                settings = json.loads(args[index])
                settings["hooks"] = {}
                args[index] = json.dumps(settings)
        cli = str(Path.home() / ".local/bin" / ("codex" if engine == "codex" else "claude"))
        try:
            process = subprocess.run([cli, *args], input="Perform the synthetic fixture operation.", text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=child_env, cwd=options.output, timeout=60)
            (options.output / (label + ".stdout")).write_text(process.stdout)
            (options.output / (label + ".stderr")).write_text(process.stderr)
            passed = process.returncode == 0 and len(fixture.requests) >= 2 and fixture.calls == expected
            if renewal:
                passed = passed and fixture.rotation >= before + 2 and fixture.rejections == 1
            results.append({"name": label, "passed": passed, "exit": process.returncode, "calls": list(fixture.calls),
                            "model_requests": len(fixture.requests), "refreshes": fixture.rotation - before})
            (options.output / (label + ".model.json")).write_text(json.dumps(fixture.requests, indent=2))
            print(f"{'PASS' if passed else 'FAIL'} {label}: calls={fixture.calls} refreshes={fixture.rotation-before}", flush=True)
        except subprocess.TimeoutExpired:
            results.append({"name": label, "passed": False, "timeout": True})
            print(f"FAIL {label}: timeout", flush=True)

    try:
        for engine in (("codex", "claude") if options.engine == "both" else (options.engine,)):
            run(engine, "read", "read_item", ["read_item"])
            run(engine, "read", "create_item", [])
            run(engine, "action", "create_item", ["create_item"])
            run(engine, "action", "delete_item", [])
            run(engine, "action", "surprise_write", [])
            run(engine, "read", "read_item", ["read_item"], renewal=True)
            run(engine, "multiple", "read_item", ["first:read_item", "second:read_item"])
            run(engine, "summary", "create_item", [])
        if options.engine != "codex":
            run("claude", "action", "create_item", ["create_item"], bypass=True)
            run("claude", "action", "surprise_write", [], bypass=True)
            run("claude", "action", "create_item", [], bypass=True, missing_hook=True)
        # Multiple helper processes must serialize rotation instead of replaying one refresh.
        inherited = subprocess.run(recipes["helper"], shell=True,
            env=dict(env, SENTIENT_SELFTEST="connectorlab", LAB_CMD="notioncheck"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        try:
            inherited_headers = json.loads(inherited.stdout)
            passed = inherited.returncode == 0 and isinstance(inherited_headers.get("Authorization"), str)
        except (ValueError, AttributeError):
            passed = False
        results.append({"name": "helper-ignores-inherited-lab-mode", "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} helper-ignores-inherited-lab-mode", flush=True)
        def helper():
            return subprocess.run(recipes["helper"], shell=True, env=env, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, timeout=30)
        before = fixture.rotation
        with ThreadPoolExecutor(max_workers=4) as workers:
            outcomes = list(workers.map(lambda _: helper(), range(4)))
        passed = all(p.returncode == 0 for p in outcomes) and fixture.rotation == before + 4
        results.append({"name": "concurrent-helper-rotation", "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} concurrent-helper-rotation", flush=True)
        fixture.refresh = "synthetic-revoked"
        before = fixture.refresh_requests
        first, second = helper(), helper()
        passed = first.returncode != 0 and second.returncode != 0 and fixture.refresh_requests == before + 1
        results.append({"name": "invalid-grant-is-terminal", "passed": passed})
        print(f"{'PASS' if passed else 'FAIL'} invalid-grant-is-terminal", flush=True)
        protocol = subprocess.run([str(options.app)], env=dict(env, SENTIENT_SELFTEST="connectorlab", LAB_CMD="directprotocol"),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        passed = protocol.returncode == 0 and "DIRECT PROTOCOL: PASS" in protocol.stdout
        results.append({"name": "native-oauth-protocol", "passed": passed})
        (options.output / "protocol.log").write_text(protocol.stdout + protocol.stderr)
        print(f"{'PASS' if passed else 'FAIL'} native-oauth-protocol", flush=True)
    finally:
        for connection_id in (recipes["connection_id"], recipes["second_connection_id"]):
            subprocess.run([str(options.app)], env=dict(env, SENTIENT_SELFTEST="connectorlab", LAB_CMD="directcleanup",
                           LAB_DIRECT_ID=connection_id), stdout=subprocess.DEVNULL, timeout=30, check=True)
        server.shutdown()
        server.server_close()
        (options.output / "results.json").write_text(json.dumps(results, indent=2))
    return 0 if results and all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
