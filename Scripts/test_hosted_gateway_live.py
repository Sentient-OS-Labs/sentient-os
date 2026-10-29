#!/usr/bin/env python3
"""Opt-in live Claude acceptance against the real gateway and its disposable SQL ledger.

Only synthetic prompts are sent. The supplied provider key stays in server memory;
Claude receives a per-run gateway token. No cloud service is deployed or reconfigured.
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key-file', required=True)
    parser.add_argument('--claude', default=str(Path.home() / '.local/bin/claude'))
    parser.add_argument('--with-vault-tools', action='store_true', help='Exercise production confined MCP file tools too')
    parser.add_argument('--app', type=Path, help='Debug app executable for the synthetic full Sidekick bridge acceptance')
    args = parser.parse_args()
    path = Path(args.key_file)
    raw = (subprocess.run(['/usr/bin/textutil', '-convert', 'txt', '-stdout', str(path)],
                          check=True, capture_output=True).stdout.decode() if path.suffix == '.rtf' else path.read_text())
    keys = re.findall(r'sk-ant-[A-Za-z0-9_-]+', raw)
    if len(keys) != 1:
        raise SystemExit('Expected exactly one provider credential; contents withheld.')
    key = keys[0]
    del keys, raw
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    environment = {name: os.environ[name] for name in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'USER') if name in os.environ}
    server_env = {**environment, 'PORT': str(port), 'ANTHROPIC_API_KEY': key,
                  'ANTHROPIC_MODEL': 'claude-sonnet-5-5', 'HOSTED_TEST_BUDGET_MICROUSD': '2000000',
                  'ANTHROPIC_BETAS': 'context-management-2025-06-27,mid-conversation-output-config-2026-07-01,dangerous-tool-use-2026-09-03',
                  # Intentionally conservative acceptance rates, not advertised pricing.
                  'INPUT_MICROUSD_PER_MILLION': '10000000', 'OUTPUT_MICROUSD_PER_MILLION': '50000000',
                  'CACHE_WRITE_MICROUSD_PER_MILLION': '20000000', 'CACHE_READ_MICROUSD_PER_MILLION': '10000000',
                  'MAXIMUM_INPUT_TOKENS': '32768', 'MAXIMUM_OUTPUT_TOKENS': '4096',
                  'MAXIMUM_BODY_BYTES': '1048576', 'REQUEST_TIMEOUT_MS': '90000', 'LEASE_CHECK_MS': '8000'}
    server = subprocess.Popen(['node', 'src/server.mjs', '--fixture', '--live-upstream'],
                              cwd=ROOT / 'HostedInference', env=server_env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    def call(path, token='local-fixture-token', body=None):
        request = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'},
                                         data=None if body is None else json.dumps(body).encode())
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    try:
        deadline = time.monotonic() + 15
        while True:
            if server.poll() is not None:
                raise SystemExit('Local fixture failed to start; server output withheld.')
            try:
                call('/health'); break
            except (OSError, urllib.error.URLError):
                if time.monotonic() > deadline: raise SystemExit('Fixture startup deadline exceeded.')
                time.sleep(0.05)
        with tempfile.TemporaryDirectory(prefix='sentient-gateway-live-') as directory:
            root = Path(directory)
            run = call('/v1/runs', body={'purpose': 'sidekick'})
            token = run['run_token']; run_path = '/v1/runs/' + run['run_id']
            profile = root / 'profile'; profile.mkdir(mode=0o700)
            child_env = {**environment, 'CLAUDE_CONFIG_DIR': str(profile), 'ANTHROPIC_API_KEY': token,
                         'ANTHROPIC_BASE_URL': base, 'CLAUDE_CODE_MAX_OUTPUT_TOKENS': '2048',
                         'DISABLE_AUTOUPDATER': '1', 'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1',
                         'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'ENABLE_TOOL_SEARCH': 'false'}
            stop = threading.Event(); heartbeat_errors = []
            def heartbeat():
                while not stop.wait(8):
                    try: call(run_path + '/heartbeat', token, {})
                    except Exception as error: heartbeat_errors.append(type(error).__name__); return
            watcher = threading.Thread(target=heartbeat, daemon=True); watcher.start()
            common = [args.claude, '--bare', '-p', '--model', run['model'], '--effort', 'low',
                      '--output-format', 'json', '--max-budget-usd', '0.50', '--setting-sources', '',
                      '--strict-mcp-config', '--no-session-persistence', '--tools', '',
                      '--system-prompt', 'Complete this isolated synthetic acceptance task.']
            try:
                result = subprocess.run(common + ['--json-schema', '{"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"],"additionalProperties":false}'],
                    input='Return a JSON object with answer equal to six times seven.', env=child_env,
                    text=True, capture_output=True, cwd=root, timeout=120)
                try: envelope = json.loads(result.stdout)
                except ValueError: envelope = {}
                valid = result.returncode == 0 and envelope.get('is_error') is False and envelope.get('structured_output', {}).get('answer') == 42
                print(json.dumps({'case': 'real_gateway_structured', 'passed': valid,
                                  'exit_code': result.returncode, 'cost_usd': envelope.get('total_cost_usd')}), flush=True)
                if not valid:
                    detail = str(envelope.get('result', ''))[:800].replace(key, '[redacted]').replace(token, '[redacted]')
                    print(json.dumps({'safe_synthetic_error': detail}), flush=True)
                    raise SystemExit('Live gateway acceptance failed; other process output withheld.')
                if args.with_vault_tools:
                    vault = root / 'vault'; vault.mkdir()
                    connection = root / 'mcp.json'
                    mcp = subprocess.Popen(['python3', str(ROOT / 'Scripts/hosted_vault_fixture.py'),
                        '--root', str(vault), '--connection-file', str(connection)], env=environment,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        ready_by = time.monotonic() + 20
                        while not connection.exists():
                            if mcp.poll() is not None or time.monotonic() > ready_by:
                                raise SystemExit('Production vault MCP fixture did not start.')
                            time.sleep(0.05)
                        command = common + ['--mcp-config', str(connection), '--allowedTools', 'mcp__sentient_vault__*',
                                            '--permission-mode', 'dontAsk']
                        result = subprocess.run(command, input='Use the sentient_vault tools to write README.md containing exactly synthetic hosted vault passed. Read README.md back using the tool, then respond VERIFIED.',
                            env=child_env, text=True, capture_output=True, cwd=vault, timeout=120)
                        try: envelope = json.loads(result.stdout)
                        except ValueError: envelope = {}
                        target = vault / 'README.md'
                        valid = result.returncode == 0 and envelope.get('is_error') is False and target.exists() and target.read_text().strip() == 'synthetic hosted vault passed'
                        print(json.dumps({'case': 'real_gateway_confined_vault', 'passed': valid,
                                          'exit_code': result.returncode, 'cost_usd': envelope.get('total_cost_usd')}), flush=True)
                        if not valid:
                            detail = str(envelope.get('result', ''))[:800].replace(key, '[redacted]').replace(token, '[redacted]')
                            print(json.dumps({'safe_synthetic_error': detail}), flush=True)
                            raise SystemExit('Production confined vault acceptance failed.')
                    finally:
                        if mcp.stdin: mcp.stdin.close(); mcp.stdin = None
                        try: mcp.communicate(timeout=10)
                        except subprocess.TimeoutExpired: mcp.terminate(); mcp.communicate(timeout=10)
            finally:
                stop.set(); watcher.join(timeout=16)
            if heartbeat_errors: raise SystemExit('Live gateway heartbeat failed.')
            paused = call(run_path + '/pause', token, {})
            resumed = call(run_path + '/resume', token, {})
            finished = call(run_path + '/finish', token, {})
            usage = call('/v1/usage')
            assert paused['phase'] == 'waiting_for_user' and resumed['phase'] == 'running'
            assert finished['phase'] == 'completed' and usage['used_seconds'] > 0
            assert usage['remaining_seconds'] + usage['used_seconds'] <= 3600.001
            print(json.dumps({'case': 'real_gateway_metering', 'passed': True, 'used_seconds': usage['used_seconds']}), flush=True)
            if args.app:
                capability = call('/v1/runs', body={'purpose': 'sidekick'})
                capability['gateway_url'] = base
                ticket = root / 'run.json'
                descriptor = os.open(ticket, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, 'w') as output: json.dump(capability, output)
                lab_env = {**environment, 'SENTIENT_SELFTEST': 'sidekickbackend', 'LAB_SIDEKICK_COMMAND': 'provider',
                           'LAB_SIDEKICK_PROVIDER': 'sentient_bridge', 'LAB_HOSTED_RUN_FILE': str(ticket)}
                try:
                    result = subprocess.run([str(args.app)], env=lab_env, text=True, capture_output=True, timeout=240)
                    records = []
                    for line in result.stdout.splitlines():
                        try: record = json.loads(line)
                        except ValueError: continue
                        if isinstance(record, dict) and record.get('lab') == 'sidekick_backend': records.append(record)
                    passed = result.returncode == 0 and len(records) == 1 and records[0].get('passed') is True
                    print(json.dumps({'case': 'real_app_hosted_sidekick_bridge', 'passed': passed, 'exit_code': result.returncode,
                                      'evidence': records}), flush=True)
                    if not passed: raise SystemExit('Hosted Sidekick bridge acceptance failed; process logs withheld.')
                finally:
                    ticket.unlink(missing_ok=True)
                    try: call('/v1/runs/' + capability['run_id'] + '/finish', capability['run_token'], {})
                    except (OSError, urllib.error.URLError): pass
    finally:
        server.terminate()
        try: output, _ = server.communicate(timeout=10)
        except subprocess.TimeoutExpired: server.kill(); output, _ = server.communicate()
        for line in output.splitlines():
            try: event = json.loads(line)
            except ValueError: continue
            if event.get('event') in ('request_rejected', 'fixture_request_shape'):
                print(json.dumps(event), flush=True)


if __name__ == '__main__':
    main()
