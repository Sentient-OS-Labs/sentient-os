// Live HTTP checks with two disposable anonymous users. No macOS notifications are sent.
// Requires the authenticated Supabase CLI only to seed the disposable notice fixture.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
const base = 'https://hjqedlalhfoxwehxhton.supabase.co';
const key = 'sb_publishable_MFHS0LDzdAW1lGyEf1MUig_BzqObIr9';
const users = [];
async function request(path, user, body = {}) {
  const response = await fetch(`${base}/${path}`, {
    method: 'POST', headers: { apikey: key, 'Content-Type': 'application/json',
      ...(user ? { Authorization: `Bearer ${user.access_token}` } : {}) },
    body: JSON.stringify(body), signal: AbortSignal.timeout(30_000),
  });
  const data = response.status === 204 ? null : await response.json();
  return { status: response.status, data };
}
async function newUser() {
  const result = await request('auth/v1/signup');
  assert.equal(result.status, 200);
  assert.equal(result.data.user.is_anonymous, true);
  users.push(result.data);
  return result.data;
}
async function rpc(user, name, body = {}) {
  const result = await request(`rest/v1/rpc/${name}`, user, body);
  assert.equal(result.status, 200, `${name} failed`);
  return result.data;
}
try {
  const recipient = await newUser(), outsider = await newUser();
  const granted = await rpc(recipient, 'redeem_invite', { p_code: 'FINAL_1000' });
  assert.ok(granted.redeemedAt > 0);
  assert.equal(granted.lifetimeUpgrade, null, 'New recipient joined the historical cohort');
  const userID = recipient.user.id;
  assert.match(userID, /^[0-9a-f-]{36}$/i);
  const seeded = spawnSync('supabase', ['db', 'query', '--linked', '--project-ref', 'hjqedlalhfoxwehxhton',
    `insert into public.invite_upgrade_announcements(user_id) values ('${userID}'::uuid);`, '--output', 'json'], { encoding: 'utf8' });
  assert.equal(seeded.status, 0, 'Disposable fixture setup failed');
  const receipt = (await rpc(recipient, 'invite_status')).lifetimeUpgrade;
  assert.ok(receipt.id && receipt.upgradedAt > 0 && receipt.seenAt === null);
  assert.equal((await rpc(outsider, 'invite_status')).lifetimeUpgrade, null);
  const body = { p_notice_id: receipt.id };
  assert.equal((await rpc(outsider, 'claim_invite_upgrade_notification', body)).claimed, false);
  assert.equal((await rpc(outsider, 'acknowledge_invite_upgrade', body)).error, 'invalid_notice');
  const claims = await Promise.all([
    rpc(recipient, 'claim_invite_upgrade_notification', body),
    rpc(recipient, 'claim_invite_upgrade_notification', body),
  ]);
  assert.equal(claims.filter(x => x.claimed).length, 1, 'Concurrent claims could send two notifications');
  assert.equal((await rpc(recipient, 'invite_status')).lifetimeUpgrade.seenAt, null);
  const seen = await rpc(recipient, 'acknowledge_invite_upgrade', body);
  assert.ok(seen.lifetimeUpgrade.seenAt > 0);
  assert.equal(seen.redeemedAt, granted.redeemedAt, 'Notice changed the lifetime entitlement');
  assert.deepEqual((await rpc(recipient, 'acknowledge_invite_upgrade', body)).lifetimeUpgrade, seen.lifetimeUpgrade);
  assert.equal((await rpc(recipient, 'claim_invite_upgrade_notification', body)).claimed, false);
  const unauthenticated = await request('rest/v1/rpc/claim_invite_upgrade_notification', null, body);
  assert.ok([401, 403].includes(unauthenticated.status));
  console.log('PASS: live targeting, owner-only receipts, concurrent once-only claim, independent in-app gift, idempotent acknowledgement, unchanged access and unauthenticated denial');
} finally {
  let failures = 0;
  for (const user of users.reverse()) {
    const result = await request('rest/v1/rpc/delete_connected_email_identity', user).catch(() => null);
    if (!result || ![200, 204].includes(result.status)) failures++;
  }
  if (failures) throw new Error(`${failures} disposable test identities need cleanup`);
  console.log(`Cleaned up ${users.length} disposable identities and their notice fixtures.`);
}
