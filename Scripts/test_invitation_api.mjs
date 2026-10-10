// Live API acceptance with disposable anonymous users; credentials never leave memory.
// Usage: node Scripts/test_invitation_api.mjs
import assert from 'node:assert/strict';
const base = 'https://hjqedlalhfoxwehxhton.supabase.co';
const key = 'sb_publishable_MFHS0LDzdAW1lGyEf1MUig_BzqObIr9';
const users = [];

async function request(path, { user, body, method = 'POST' } = {}) {
  const headers = { apikey: key, 'Content-Type': 'application/json' };
  if (user) headers.Authorization = `Bearer ${user.access_token}`;
  const response = await fetch(`${base}/${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const data = response.status === 204 ? null : await response.json();
  return { status: response.status, data };
}
async function newUser() {
  const result = await request('auth/v1/signup', { body: {} });
  assert.equal(result.status, 200, 'Anonymous signup failed');
  assert.equal(result.data.user.is_anonymous, true);
  users.push(result.data);
  return result.data;
}
async function rpc(user, name, body = {}) {
  const result = await request(`rest/v1/rpc/${name}`, { user, body });
  assert.equal(result.status, 200, `RPC ${name} failed`);
  return result.data;
}

try {
  const sender = await newUser();
  const friend = await newUser();
  const anotherFriend = await newUser();
  const [senderState, senderReplay] = await Promise.all([
    rpc(sender, 'invite_status'), rpc(sender, 'invite_status'),
  ]);
  assert.equal(senderState.code, senderReplay.code, 'Concurrent issuance returned different codes');
  const friendState = await rpc(friend, 'invite_status');
  assert.match(senderState.code, /^[0-9A-Z]{6}$/);
  assert.match(friendState.code, /^[0-9A-Z]{6}$/);
  assert.notEqual(senderState.code, friendState.code);
  assert.equal(senderState.redeemedAt, null);
  assert.equal((await rpc(sender, 'redeem_invite', { p_code: senderState.code })).error, 'own_code');
  const [first, replay] = await Promise.all([
    rpc(friend, 'redeem_invite', { p_code: ` ${senderState.code.toLowerCase().match(/.{3}/g).join('-')} ` }),
    rpc(friend, 'redeem_invite', { p_code: senderState.code }),
  ]);
  assert.ok(first.redeemedAt > 0);
  assert.equal(first.redeemedAt, replay.redeemedAt, 'Concurrent replay created different grants');
  const grants = await Promise.all([
    rpc(anotherFriend, 'redeem_invite', { p_code: senderState.code }),
    rpc(anotherFriend, 'redeem_invite', { p_code: friendState.code }),
  ]);
  assert.equal(grants[0].redeemedAt, grants[1].redeemedAt, 'Concurrent different codes created different grants');
  const senderAfter = await rpc(sender, 'invite_status');
  const friendAfter = await rpc(friend, 'invite_status');
  assert.equal(senderAfter.redemptionCount + friendAfter.redemptionCount, 2, 'A recipient was counted twice');
  const rows = await request('rest/v1/invite_redemptions?select=recipient_id', { user: friend, method: 'GET' });
  assert.deepEqual(rows.data.map(x => x.recipient_id), [friend.user.id]);
  const forged = await request('rest/v1/invite_redemptions', {
    user: sender, body: { recipient_id: sender.user.id, campaign_id: 'launch-lifetime' },
  });
  assert.equal(forged.status, 403, 'Client forged a lifetime grant');
  const anonymous = await request('rest/v1/rpc/invite_status', { body: {} });
  assert.ok([401, 403].includes(anonymous.status), 'Anonymous request issued a code');
  const refreshed = await request('auth/v1/token?grant_type=refresh_token', { body: { refresh_token: friend.refresh_token } });
  assert.equal(refreshed.status, 200);
  Object.assign(friend, refreshed.data);
  assert.equal((await rpc(friend, 'invite_status')).redeemedAt, first.redeemedAt, 'Token refresh lost access');
  console.log('PASS: live Auth, code sharing, concurrent redemption/replay, RLS, forgery denial, token refresh');
} finally {
  let failures = 0;
  for (const user of users.reverse()) {
    // Existing project RPC deletes only the calling disposable anonymous Auth user.
    const result = await request('rest/v1/rpc/delete_connected_email_identity', { user, body: {} }).catch(() => null);
    if (!result || result.status !== 204 && result.status !== 200) failures++;
  }
  if (failures) throw new Error(`${failures} disposable test identities need cleanup`);
  console.log(`Cleaned up ${users.length} disposable test identities.`);
}
