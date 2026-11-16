// Codex accounts against a stand-in app-server: limits by window length, coupons, and using one.
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { before, test } from 'node:test';

const temp = mkdtempSync(path.join(os.tmpdir(), 'agentbar-codex-'));
const home = path.join(temp, 'home', '.codex');
mkdirSync(home, { recursive: true });
writeFileSync(path.join(home, 'auth.json'), '{}');
const soon = Math.floor(Date.now() / 1000) + 14 * 86400;
writeFileSync(path.join(home, 'fake.json'), JSON.stringify({
  account: { type: 'chatgpt', email: 'dev@example.com', accountId: 'codex-1', planType: 'pro' },
  rateLimits: { planType: 'pro', primary: { usedPercent: 12, windowDurationMins: 300, resetsAt: soon }, secondary: { usedPercent: 27, windowDurationMins: 10080, resetsAt: soon } },
  rateLimitResetCredits: { availableCount: 3, credits: [{ id: 'credit-b', status: 'available', expiresAt: soon + 100 }, { id: 'credit-a', status: 'available', expiresAt: soon }, { id: 'credit-used', status: 'redeemed', expiresAt: soon }] },
}));

let store, CODEX_DEFAULT;
before(async () => {
  Object.assign(process.env, {
    AGENTBAR_USER_HOME: path.join(temp, 'home'), AGENTBAR_HOME: path.join(temp, 'data'),
    AGENTBAR_CODEX_CLI: path.resolve(import.meta.dirname, 'fake-codex.mjs'), AGENTBAR_CLAUDE_CLI: path.join(temp, 'no-claude'), AGENTBAR_NO_BROWSER: '1',
  });
  delete process.env.CODEX_HOME;
  const module = await import('../app/store.mjs');
  CODEX_DEFAULT = module.CODEX_DEFAULT;
  store = new module.Store();
});

test('the Codex login Codex itself uses is listed with both windows and its coupons', async () => {
  await store.refreshAll();
  const [codex] = store.state().accounts;
  assert.equal(codex.id, CODEX_DEFAULT);
  assert.equal(codex.email, 'dev@example.com');
  assert.equal(codex.plan, 'Pro');
  assert.equal(codex.fiveHour.used, 12);
  assert.equal(codex.weekly.used, 27);
  assert.equal(codex.coupons.totalCount, 3);
  assert.deepEqual(codex.coupons.options[0].claim, { type: 'codex', creditId: 'credit-a' }, 'the one that expires first');
  assert.equal(codex.coupons.options[0].expiries.length, 2);
});

test('using a Codex coupon asks the app-server once, for that credit', async () => {
  const [codex] = store.state().accounts;
  assert.deepEqual(await store.useCoupon(codex.id, codex.coupons.options[0].claim), { outcome: 'reset' });
  const sent = readFileSync(path.join(home, 'consumed.json'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  assert.equal(sent.length, 1);
  assert.equal(sent[0].creditId, 'credit-a');
  assert.match(sent[0].idempotencyKey, /^[0-9a-f-]{36}$/);
});
