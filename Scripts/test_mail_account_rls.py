#!/usr/bin/env python3
"""Exercise the real Data API using two disposable anonymous identities; no admin key.

Only synthetic example.com addresses are used. Each identity removes itself in finally.
Run with --url and --key (the publishable key is public, never a service-role key).
"""
import argparse
import json
import urllib.request
import urllib.error
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', required=True)
    parser.add_argument('--key', required=True)
    args = parser.parse_args()
    assert not args.key.startswith('sb_secret_'), 'Use a publishable key'
    sessions = []
    checks = 0

    def call(path, token=None, data=None, method=None, prefer=None):
        headers = {'apikey': args.key, 'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        if prefer:
            headers['Prefer'] = prefer
        req = urllib.request.Request(args.url.rstrip('/') + '/' + path,
                                     data=json.dumps(data).encode() if data is not None else None,
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                body = response.read()
                return response.status, json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            body = error.read()
            return error.code, json.loads(body) if body else None

    def check(condition, label):
        nonlocal checks
        if not condition:
            raise AssertionError(label)
        checks += 1
        print('PASS', label, flush=True)

    def record(email='fixture-a@example.com', key='fixture'):
        return {'engine': 'chatgpt', 'provider': 'gmail', 'connection_key': key,
                'email': email, 'reported_via': 'connector_profile', 'consent_version': 1}

    table = 'rest/v1/connected_email_accounts'
    sync = 'rest/v1/rpc/sync_connected_email_accounts'
    try:
        check(call(table + '?select=id')[0] in (401, 403), 'public key alone cannot read email records')
        check(call(table, data=record())[0] in (401, 403), 'public key alone cannot insert')
        check(call(sync, data={'accounts': []})[0] in (401, 403), 'public key alone cannot call sync')
        check(call('rest/v1/rpc/delete_connected_email_identity', data={})[0] in (401, 403), 'public key alone cannot call self-deletion')
        for _ in range(2):
            status, session = call('auth/v1/signup', data={})
            check(status == 200 and session.get('user', {}).get('is_anonymous') is True, 'create isolated anonymous identity')
            sessions.append(session)
        a, b = sessions
        at, bt = a['access_token'], b['access_token']
        check(call(sync, at, {'accounts': [record()]})[0] in (200, 204), 'owner can sync its account')
        status, rows = call(table + '?select=*', at)
        check(status == 200 and len(rows) == 1 and rows[0]['owner_id'] == a['user']['id'], 'owner receives its own row with server-assigned ownership')
        aid = rows[0]['id']
        check(call(table + '?select=*', bt) == (200, []), 'another identity cannot list the row')
        check(call(table + '?select=*&owner_id=eq.' + a['user']['id'], bt) == (200, []), 'explicit owner filter cannot bypass RLS')
        check(call(table + '?id=eq.' + aid, bt, {'email': 'attacker@example.com'}, 'PATCH', 'return=representation') == (200, []), 'cross-owner update affects no rows')
        check(call(table + '?id=eq.' + aid, bt, method='DELETE', prefer='return=representation') == (200, []), 'cross-owner deletion affects no rows')
        forged = dict(record(), owner_id=a['user']['id'])
        check(call(table, bt, forged)[0] == 403, 'client cannot supply another owner on insert')
        check(call(table + '?id=eq.' + aid, at, {'owner_id': b['user']['id']}, 'PATCH')[0] == 403, 'owner cannot transfer ownership')
        check(call(table + '?id=eq.' + aid, at, {'updated_at': '2000-01-01T00:00:00Z'}, 'PATCH')[0] == 403, 'client cannot set server timestamps')
        check(call(sync, bt, {'accounts': [forged]})[0] == 400, 'snapshot RPC rejects injected ownership fields')
        check(call(sync, bt, {'accounts': [record('fixture-b@example.com')]})[0] in (200, 204), 'second identity can save independently')
        check(call(sync, at, {'accounts': [record('changed@example.com'), record('invalid', 'other')]})[0] == 400, 'invalid mixed snapshot is rejected atomically')
        check(call(table + '?select=email', at) == (200, [{'email': 'fixture-a@example.com'}]), 'failed snapshot preserves previous data')
        check(call(sync, at, {'accounts': [record(), record()]})[0] == 400, 'duplicate connection keys are rejected')
        check(call(sync, at, {'accounts': [record(key=str(i)) for i in range(33)]})[0] == 400, 'snapshot account limit is enforced')
        check(call(sync, at, {'accounts': [dict(record(), provider='unknown')]})[0] == 400, 'unsupported providers are rejected')
        check(call(sync, at, {'accounts': [dict(record(), consent_version=0)]})[0] == 400, 'missing current disclosure version is rejected')
        check(call(sync, at, {'accounts': [record('fixture-a-updated@example.com')]})[0] in (200, 204), 'owner can update existing address')
        check(call(sync, at, {'accounts': []})[0] in (200, 204), 'owner can delete its snapshot')
        check(call(table + '?select=email', at) == (200, []), 'empty snapshot removes own records')
        check(call(table + '?select=email', bt) == (200, [{'email': 'fixture-b@example.com'}]), 'empty snapshot preserves other owner')
        check(call('rest/v1/rpc/delete_connected_email_identity', bt, {})[0] in (200, 204), 'self-deletion succeeds without an admin key')
        check(call(table + '?select=email', bt) == (200, []), 'self-deletion cascades to account records')
        print(f'{checks} assertions passed.', flush=True)
    finally:
        for session in sessions:
            status, _ = call('rest/v1/rpc/delete_connected_email_identity', session['access_token'], {})
            if status not in (200, 204):
                raise RuntimeError('Disposable identity cleanup failed; HTTP ' + str(status))


if __name__ == '__main__':
    main()
