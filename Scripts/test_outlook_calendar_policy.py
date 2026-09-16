"""Exercise Calendar policies with real CLIs and loopback-only model/MCP fixtures.

Export recipes with the app's connector lab: LAB_CMD=calendarpolicy. Run this script
with --recipes, --engine claude|chatgpt, and --output. Provider requests never reach a
real account. Headers are not recorded. Cleanup touches only this run's random counters
and synthetic account reservations. Positive controls accompany every denial family.
"""
import argparse, base64, hashlib, json, os, re, shlex, subprocess, sys, threading, uuid
from pathlib import Path
from http.server import ThreadingHTTPServer
from test_connector_read_policy import Fixture, make_handler, tool
CAL = 'connector_e6a7394682e24467ac68c60696f275a4'
MAIL = 'connector_4aaab2856305417b993eca9a216aaf6e'
PREFIX = 'mcp__claude_ai_Microsoft_365__'
EVENT = {'subject': 'Synthetic appointment', 'start': {'dateTime': '2026-09-15T09:00:00', 'timeZone': 'UTC'}, 'end': {'dateTime': '2026-09-15T09:15:00', 'timeZone': 'UTC'}, 'attendees': []}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--recipes', type=Path, required=True)
    parser.add_argument('--engine', choices=['claude', 'chatgpt'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    recipes = json.loads(options.recipes.read_text())
    fixture = Fixture()
    base_handler = make_handler(fixture)

    class Handler(base_handler):

        def do_POST(self):
            if options.engine != 'claude' or not self.path.startswith('/v1/messages'):
                return super().do_POST()
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or b'{}')
            if 'count_tokens' in self.path:
                return self.reply({'input_tokens': 10})
            fixture.requests.append(body)
            call = fixture.sent < fixture.force_count
            fixture.sent += 1
            block = {'type': 'tool_use', 'id': 'toolu_fixture_' + str(fixture.sent), 'name': fixture.force, 'input': {}} if call else {'type': 'text', 'text': ''}
            message = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'content': [], 'model': body.get('model', 'fixture'), 'stop_reason': None, 'usage': {'input_tokens': 10, 'output_tokens': 1}}
            events = [('message_start', {'message': message}), ('content_block_start', {'index': 0, 'content_block': block}), ('content_block_delta', {'index': 0, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(fixture.force_args)} if call else {'type': 'text_delta', 'text': 'Fixture complete.'}}), ('content_block_stop', {'index': 0}), ('message_delta', {'delta': {'stop_reason': 'tool_use' if call else 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 10}}), ('message_stop', {})]
            data = ''.join((f"event: {k}\ndata: {json.dumps({'type': k, **v})}\n\n" for (k, v) in events)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    results = []
    owned_accounts = set()
    intents = {}

    def run(label, recipe, name, arguments=None, expected=1, repeat=1, mail=False, missing=False, annotation=True, reuse=None):
        fixture.reset()
        fixture.force_args = arguments or {}
        fixture.force_count = repeat
        names = [('get_me', True), ('get_profile', True), ('outlook_calendar_search', True), ('list_events', True), ('read_resource', True), ('fetch_event', True), ('outlook_email_search', True), ('list_messages', True), ('outlook_create_event', False), ('create_event', False), ('outlook_send_mail', False), ('send_email', False), ('outlook_delete_event', False), ('cancel_or_delete_event', False), ('outlook_future_write', False), ('future_write', False), ('sharepoint_search', True)]
        fixture.tools = []
        for (n, read) in names:
            ns = 'microsoft_outlook_email' if n in ['list_messages', 'send_email'] else 'microsoft_outlook_calendar'
            native = n if options.engine == 'claude' else ns + '.' + n
            t = tool(native, MAIL if ns.endswith('email') else CAL, n, read and (not (n == name and (not annotation))))
            t['inputSchema'] = {'type': 'object', 'properties': {}, 'additionalProperties': True}
            t['_meta']['connector_name'] = 'Microsoft Outlook Email' if ns.endswith('email') else 'Microsoft Outlook Calendar'
            fixture.tools.append(t)
        ns = 'microsoft_outlook_email' if mail else 'microsoft_outlook_calendar'
        expected_name = name if options.engine == 'claude' else ns + '.' + name
        fixture.force = PREFIX + name if options.engine == 'claude' else ('mcp__codex_apps__' + ns, '_' + name)
        args = list(recipes[options.engine + '-' + recipe])
        runids = []
        key = reuse or label
        if key not in intents:
            intents[key] = (hashlib.sha256(uuid.uuid4().bytes).hexdigest(), hashlib.sha256(uuid.uuid4().bytes).hexdigest())
        (account, intent) = intents[key]
        owned_accounts.add(account)

        def fix_command(command):

            def fresh(m):
                value = str(uuid.uuid4()).upper()
                runids.append(value)
                return value
            command = re.sub('[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', fresh, command)
            for token in shlex.split(command):
                try:
                    ctx = json.loads(base64.b64decode(token))
                except:
                    continue
                if isinstance(ctx, dict) and ctx.get('operation') == 'create':
                    ctx['accountFingerprint'] = account
                    ctx['intentHash'] = intent
                    command = command.replace(token, base64.b64encode(json.dumps(ctx).encode()).decode())
            return '/missing-calendar-fixture || { exit 2; }' if missing else command
        env = dict(os.environ)
        if options.engine == 'claude':
            if recipe == 'computer':
                del args[1]
            i = args.index('--settings') + 1
            settings = json.loads(args[i])
            settings['allowedMcpServers'] = [{'serverName': 'claude_ai_Microsoft_365'}]
            for groups in settings.get('hooks', {}).values():
                for group in groups:
                    for hook in group['hooks']:
                        hook['command'] = fix_command(hook['command'])
            args[i] = json.dumps(settings)
            if '--mcp-config' in args:
                i = args.index('--mcp-config')
                del args[i:i + 2]
            args += ['--strict-mcp-config', '--mcp-config', json.dumps({'mcpServers': {'claude_ai_Microsoft_365': {'type': 'http', 'url': base + '/mcp'}}}), '--no-session-persistence']
            env.pop('ANTHROPIC_AUTH_TOKEN', None)
            env.update(ANTHROPIC_API_KEY='synthetic-fixture', ANTHROPIC_BASE_URL=base, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1', DISABLE_TELEMETRY='1', DISABLE_ERROR_REPORTING='1')
            command = [str(Path.home() / '.local/bin/claude'), *args]
        else:
            args = args[:-1]
            for (i, value) in enumerate(args):
                if value.startswith('hooks.'):
                    pattern = 'command=("(?:[^"\\\\]|\\\\.)*")'
                    args[i] = re.sub(pattern, lambda m: 'command=' + json.dumps(fix_command(json.loads(m.group(1)))), value)
            args[args.index('-m') + 1] = 'fixture'
            overrides = ['model_provider="fixture"', f'model_providers.fixture={{name="Fixture",base_url="{base}/v1",wire_api="responses",requires_openai_auth=false}}', f'chatgpt_base_url="{base}"', 'features.apps=true', 'features.code_mode=false', 'features.tool_search=false', 'mcp_servers={}', 'analytics.enabled=false', 'web_search="disabled"', 'model_providers.fixture.request_max_retries=0']
            if '--ignore-user-config' not in args:
                args += ['--ignore-user-config']
            args += ['--ephemeral', *[x for v in overrides for x in ['-c', v]], '-']
            command = [str(Path.home() / '.local/bin/codex'), *args]
        try:
            with (options.output / (label + '.jsonl')).open('w') as out, (options.output / (label + '.err')).open('w') as err:
                result = subprocess.run(command, input='Perform the synthetic fixture operation.', text=True, stdout=out, stderr=err, env=env, cwd=options.output, timeout=40)
            passed = result.returncode == 0 and len(fixture.requests) == repeat + 1 and (fixture.calls == [expected_name] * expected)
            results.append({'name': label, 'passed': passed, 'exit': result.returncode, 'modelRequests': len(fixture.requests), 'calls': list(fixture.calls)})
            print(('PASS' if passed else 'FAIL') + ' ' + label + ' calls=' + str(fixture.calls), flush=True)
        finally:
            for runid in runids:
                for p in Path('/private/tmp').glob(f'sentient-outlook-{os.getuid()}-{runid}-*'):
                    p.unlink(missing_ok=True)
    search = 'outlook_calendar_search' if options.engine == 'claude' else 'list_events'
    create = 'outlook_create_event' if options.engine == 'claude' else 'create_event'
    profile = 'get_me' if options.engine == 'claude' else 'get_profile'
    fetch = 'read_resource' if options.engine == 'claude' else 'fetch_event'
    delete = 'outlook_delete_event' if options.engine == 'claude' else 'cancel_or_delete_event'
    query = {'query': '*', 'afterDateTime': '2026-08-31T23:59:59.999Z', 'beforeDateTime': '2026-09-15T00:00:00.000Z', 'order': 'newest', 'limit': 25, 'offset': 0} if options.engine == 'claude' else {'start_datetime': '2026-09-01T00:00:00.000Z', 'end_datetime': '2026-09-15T00:00:00.000Z', 'top': 200, 'order_by': 'start/dateTime desc'}
    try:
        run('read-profile', 'read', profile)
        run('read-create-denied', 'read', create, EVENT, expected=0)
        run('read-delete-denied', 'read', delete, {}, expected=0)
        run('read-mail-denied', 'read', 'outlook_email_search' if options.engine == 'claude' else 'list_messages', {'query': '*'} if options.engine == 'claude' else {}, expected=0, mail=True)
        run('knowledge-query', 'knowledge', search, query)
        bad = dict(query)
        bad['calendarOwnerEmail' if options.engine == 'claude' else 'calendar_id'] = 'other@example.invalid'
        run('other-calendar-denied', 'knowledge', search, bad, expected=0)
        bad = dict(query)
        bad['afterDateTime' if options.engine == 'claude' else 'start_datetime'] = '2020-01-01T00:00:00Z'
        run('changed-window-denied', 'knowledge', search, bad, expected=0)
        run('mixed-calendar-read', 'mixed', search, query)
        run('mixed-mail-read', 'mixed', 'outlook_email_search' if options.engine == 'claude' else 'list_messages', {'query': '*'} if options.engine == 'claude' else {}, mail=True)
        hidden = {**EVENT, 'showAs' if options.engine == 'claude' else 'show_as': 'free'}
        run('unreviewed-option-denied', 'create', create, hidden, expected=0)
        attendee_key = 'email' if options.engine == 'claude' else 'emailAddress'
        address = 'person@example.invalid' if options.engine == 'claude' else {'address': 'person@example.invalid'}
        duplicate = {**EVENT, 'attendees': [{attendee_key: address, 'type': role} for role in ['required', 'optional']]}
        run('duplicate-attendee-denied', 'create', create, duplicate, expected=0)
        run('create-event', 'create', create, EVENT)
        run('duplicate-create-denied', 'create', create, EVENT, repeat=2)
        run('pending-first', 'create', create, EVENT, reuse='pending')
        run('pending-retry-denied', 'create', create, EVENT, expected=0, reuse='pending')
        changed = dict(EVENT)
        changed['subject'] = 'Changed card'
        run('pending-edited-retry-denied', 'create', create, changed, expected=0, reuse='pending')
        run('future-write-denied', 'create', 'outlook_future_write' if options.engine == 'claude' else 'future_write', EVENT, expected=0)
        run('missing-helper-denied', 'create', create, EVENT, expected=0, missing=True)
        run('wide-create-denied', 'computer', create, EVENT, expected=0)
        if options.engine == 'claude':
            run('calendar-resource', 'read', fetch, {'uri': 'calendar:///events/EVENT_FIXTURE'})
            run('mail-resource-denied', 'read', fetch, {'uri': 'mail:///messages/MAIL_FIXTURE'}, expected=0)
            run('file-resource-denied', 'mixed', fetch, {'uri': 'file:///secret'}, expected=0)
            run('mixed-mail-resource', 'mixed', fetch, {'uri': 'mail:///messages/MAIL_FIXTURE'})
        else:
            run('annotation-change-denied', 'knowledge', search, query, expected=0, annotation=False)
    finally:
        server.shutdown()
        server.server_close()
        pending = Path.home() / 'Library/Application Support/SentientOS/OutlookCalendarPending'
        for account in owned_accounts:
            for p in pending.glob(account + '-*'):
                p.unlink(missing_ok=True)
        (options.output / 'results.json').write_text(json.dumps(results, indent=2))
    return 0 if results and all((x['passed'] for x in results)) else 1
if __name__ == '__main__':
    raise SystemExit(main())
