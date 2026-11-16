// The account store against a stand-in Claude Code and a stand-in Anthropic: reading usage and coupons, renewing a
// login, switching, adding and using a coupon. Nothing here reaches the real services or the real logins.
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';

const temp = mkdtempSync(path.join(os.tmpdir(), 'agentbar-test-'));
const home = path.join(temp, 'home');
mkdirSync(path.join(home, '.claude'), { recursive: true });
const accounts = [
  { name: 'work', plan: 'team', accountId: 'acc-work', email: 'work@example.com', organizationId: 'org-work', organization: 'Example Inc' },
  { name: 'me', plan: 'max', accountId: 'acc-me', email: 'me@example.com', organizationId: 'org-me', organization: "me@example.com's Organization" },
];
const dbFile = path.join(temp, 'db.json');
writeFileSync(dbFile, JSON.stringify({ accounts }));

// What the stand-in Anthropic saw and what it answers.
const seen = { usage: [], claims: [], renewals: [] };
const answers = { usageStatus: 200, cedar: null, claim: { result: 'reset' } };
const server = http.createServer((request, response) => {
  let body = '';
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    const send = (status, value, headers = {}) => { response.writeHead(status, { 'content-type': 'application/json', ...headers }); response.end(JSON.stringify(value)); };
    if (request.url.startsWith('/api/oauth/usage')) {
      seen.usage.push({ url: request.url, agent: request.headers['user-agent'], authorization: request.headers.authorization });
      if (answers.usageStatus !== 200) return send(answers.usageStatus, { error: 'no' }, { 'retry-after': '120' });
      const usage = { five_hour: { utilization: 59.2, resets_at: new Date(Date.now() + 27 * 60_000).toISOString() },
        seven_day: { utilization: 0.69, resets_at: new Date(Date.now() + 5 * 86400_000).toISOString() },
        limits: [{ kind: 'weekly_scoped', percent: 1, resets_at: new Date(Date.now() + 5 * 86400_000).toISOString(), scope: { model: { display_name: 'Fable' } } }] };
      if (request.url.includes('cedar_ember=1') && answers.cedar) usage.cedar_ember = answers.cedar;
      return send(200, usage);
    }
    if (request.url === '/v1/oauth/token') {
      seen.renewals.push(JSON.parse(body));
      return send(200, { access_token: 'access-renewed', refresh_token: 'refresh-renewed', expires_in: 3600, scope: 'user:inference user:profile' });
    }
    const claim = /^\/api\/organizations\/([^/]+)\/reset_rate_limits$/.exec(request.url);
    if (claim && request.method === 'POST') {
      seen.claims.push({ organization: claim[1], body: JSON.parse(body), agent: request.headers['user-agent'] });
      return send(200, answers.claim);
    }
    send(404, {});
  });
});

let Store, store, claude;
before(async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  Object.assign(process.env, {
    AGENTBAR_USER_HOME: home, AGENTBAR_HOME: path.join(temp, 'data'), AGENTBAR_ANTHROPIC_API: base, AGENTBAR_ANTHROPIC_TOKEN_URL: `${base}/v1/oauth/token`,
    AGENTBAR_CLAUDE_CLI: path.resolve(import.meta.dirname, 'fake-claude.mjs'), AGENTBAR_CODEX_CLI: path.join(temp, 'no-codex'),
    FAKE_CLAUDE_DB: dbFile, FAKE_CLAUDE_BROWSER: path.join(temp, 'browser'), AGENTBAR_NO_BROWSER: '1',
  });
  delete process.env.CLAUDE_CONFIG_DIR;
  ({ Store } = await import('../app/store.mjs'));
  claude = await import('../app/claude.mjs');
  // Claude Code is signed in to "work".
  writeFileSync(path.join(home, '.claude', '.credentials.json'), JSON.stringify({ claudeAiOauth: {
    accessToken: 'access-work', refreshToken: 'refresh-work-1', expiresAt: Date.now() + 3600_000, scopes: ['user:inference'], subscriptionType: 'team' }, mcpOAuth: { kept: true } }));
  writeFileSync(path.join(home, '.claude.json'), JSON.stringify({ numStartups: 3, oauthAccount: {
    accountUuid: 'acc-work', emailAddress: 'work@example.com', organizationUuid: 'org-work', organizationName: 'Example Inc' } }));
  store = new Store();
});
after(() => server.close());

const row = (email) => store.state().accounts.find((account) => account.email === email);
const liveCredentials = () => JSON.parse(readFileSync(path.join(home, '.claude', '.credentials.json'), 'utf8'));

test('the account Claude Code uses is listed by itself, with its usage', async () => {
  await store.refreshAll();
  const work = row('work@example.com');
  assert.equal(work.inUse, true);
  assert.equal(work.plan, 'Team');
  assert.equal(work.fiveHour.used, 59);
  assert.equal(work.weekly.used, 69);
  assert.deepEqual(work.models.map((model) => [model.label, model.used]), [['Fable', 1]]);
  assert.equal(work.organization, 'Example Inc');
  assert.equal(seen.usage.at(-1).agent, 'claude-cli/2.1.322 (external, cli)');
  assert.equal(seen.usage.at(-1).authorization, 'Bearer access-work');
  assert.match(seen.usage.at(-1).url, /cedar_ember=1&skip_spend=1/);
});

test('a second read inside a minute asks nobody', async () => {
  const count = seen.usage.length;
  await store.refreshAll();
  assert.equal(seen.usage.length, count);
});

test('a refusal keeps the last numbers and waits as long as it was told', async () => {
  answers.usageStatus = 429;
  await store.refreshAll({ force: true });
  const work = row('work@example.com');
  assert.equal(work.error, 'rate-limited');
  assert.equal(work.stale, true);
  assert.equal(work.fiveHour.used, 59);
  const count = seen.usage.length;
  answers.usageStatus = 200;
  await store.refreshAll({ force: true });
  assert.equal(seen.usage.length, count, 'still waiting out the 120 seconds');
  store.memoryOf(row('work@example.com').id).retryUntil = 1;
  store.memoryOf(row('work@example.com').id).at = 1;
  store.memoryOf(row('work@example.com').id).rateLimitedCount = 0;
});

test('adding an account signs it in with the browser into its own folder and leaves Claude Code alone', async () => {
  const adding = store.addClaude();
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.deepEqual(store.state().activity, { kind: 'add', provider: 'claude', id: null });
  writeFileSync(process.env.FAKE_CLAUDE_BROWSER, 'me');
  assert.deepEqual(await adding, { outcome: 'added' });
  const me = row('me@example.com');
  assert.equal(me.inUse, false);
  assert.equal(me.canSwitch, true);
  assert.equal(me.plan, 'Max');
  assert.equal(me.organization, null, 'an organization named after the email is not repeated');
  assert.equal(me.weekly.used, 69);
  assert.equal(liveCredentials().claudeAiOauth.refreshToken, 'refresh-work-1');
});

test('switching hands the saved login to Claude Code and keeps the one that was there', async () => {
  const me = row('me@example.com'), work = row('work@example.com');
  assert.deepEqual(await store.switchClaude(me.id), { outcome: 'switched' });
  assert.equal(liveCredentials().claudeAiOauth.refreshToken, 'refresh-me-browser+');
  assert.equal(JSON.parse(readFileSync(path.join(home, '.claude.json'), 'utf8')).numStartups, 3);
  assert.equal(row('me@example.com').inUse, true);
  assert.equal(row('work@example.com').inUse, false);
  assert.equal(row('work@example.com').canSwitch, true);
  // Each login exists once: the one handed over is gone from its folder, the previous one is in its own.
  assert.equal(existsSync(path.join(store.claudeFolder(me.id), '.credentials.json')), false);
  assert.equal(JSON.parse(readFileSync(path.join(store.claudeFolder(work.id), '.credentials.json'), 'utf8')).claudeAiOauth.refreshToken, 'refresh-work-1');
  assert.equal(row('work@example.com').weekly.used, 69, 'the account that left Claude Code is still read');
});

test('a switch that fails changes nothing and can be tried again', async () => {
  const work = row('work@example.com'), me = row('me@example.com');
  process.env.FAKE_CLAUDE_FAIL = '1';
  assert.deepEqual(await store.switchClaude(work.id), { outcome: 'failed' });
  delete process.env.FAKE_CLAUDE_FAIL;
  assert.equal(row('me@example.com').inUse, true);
  assert.equal(row('work@example.com').canSwitch, true);
  assert.equal(existsSync(path.join(store.claudeFolder(me.id), '.credentials.json')), false, 'the live login is not also kept in its folder');
  assert.deepEqual(await store.switchClaude(work.id), { outcome: 'switched' });
  assert.equal(liveCredentials().claudeAiOauth.refreshToken, 'refresh-work-1+');
  assert.equal(row('me@example.com').canSwitch, true);
});

test('a saved login the provider refuses asks for a new sign-in', async () => {
  const me = row('me@example.com');
  const saved = JSON.parse(readFileSync(path.join(store.claudeFolder(me.id), '.credentials.json'), 'utf8')).claudeAiOauth.refreshToken;
  writeFileSync(dbFile, JSON.stringify({ accounts, refused: [saved] }));
  assert.deepEqual(await store.switchClaude(me.id), { outcome: 'needsLogin' });
  assert.equal(row('work@example.com').inUse, true);
  assert.equal(row('me@example.com').requiresLogin, true);
  assert.equal(row('me@example.com').canSwitch, false);
  // Signing in again from that account's row brings it back.
  writeFileSync(dbFile, JSON.stringify({ accounts }));
  const renewing = store.addClaude(me.id);
  writeFileSync(process.env.FAKE_CLAUDE_BROWSER, 'me');
  assert.deepEqual(await renewing, { outcome: 'renewed' });
  assert.equal(row('me@example.com').canSwitch, true);
});

test('a saved login that ran out is renewed before it is used, other fields kept', async () => {
  const me = row('me@example.com');
  const file = path.join(store.claudeFolder(me.id), '.credentials.json');
  const document = JSON.parse(readFileSync(file, 'utf8'));
  document.claudeAiOauth.expiresAt = Date.now() - 1000;
  document.extra = 'kept';
  writeFileSync(file, JSON.stringify(document));
  await store.refreshAll({ force: true });
  assert.equal(seen.renewals.at(-1).refresh_token, 'refresh-me-browser');
  assert.equal(seen.renewals.at(-1).client_id, '9d1c250a-e61b-44d9-88ed-5944d1962f5e');
  const renewed = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(renewed.claudeAiOauth.refreshToken, 'refresh-renewed');
  assert.equal(renewed.extra, 'kept');
  assert.equal(seen.usage.at(-1).authorization, 'Bearer access-renewed');
  assert.equal(row('me@example.com').error, null);
});

test('coupons come with the usage read; using one sends the confirmed grant once', async () => {
  const soon = new Date(Date.now() + 3 * 86400_000).toISOString();
  answers.cedar = { eligible: true, at_limit: true, exhausted: ['five_hour'], next_grant_id: 'g-session', grants: [
    { id: 'g-session', resets_left: 2, ends_at: soon, clears: ['five_hour'], type: 'session', usable_now: true, percent_used: { five_hour: 100 } },
    { id: 'g-week', resets_left: 1, ends_at: soon, clears: ['seven_day'], type: 'weekly', usable_now: false, unavailable_reason: 'needs_limit' },
  ] };
  const work = row('work@example.com');
  store.memoryOf(work.id).couponCheck = 0;
  await store.refreshAll({ force: true });
  const coupons = row('work@example.com').coupons;
  assert.equal(coupons.totalCount, 3);
  assert.deepEqual(coupons.options.map((item) => [item.scope, item.count, item.redeemable, item.blockReason, item.affectedUsagePercent]),
    [['fiveHour', 2, true, undefined, 100], ['weekly', 1, false, 'limitRequired', undefined]]);
  // One that cannot be used now is not sent.
  assert.deepEqual(await store.useCoupon(work.id, coupons.options[1].claim), { outcome: 'conditionsChanged' });
  assert.equal(seen.claims.length, 0);
  assert.deepEqual(await store.useCoupon(work.id, coupons.options[0].claim), { outcome: 'reset' });
  assert.equal(seen.claims.length, 1);
  assert.equal(seen.claims[0].organization, 'org-work');
  assert.equal(seen.claims[0].body.program, 'cedar_ember');
  assert.equal(seen.claims[0].body.grant_id, 'g-session');
  assert.match(seen.claims[0].body.request_id, /^[0-9a-f-]{36}$/);
  assert.equal(seen.claims[0].agent, 'claude-cli/2.1.322 (external, cli)');
});

test('an account can be removed, but not the one Claude Code is using', () => {
  assert.equal(store.remove(row('work@example.com').id), false);
  const me = row('me@example.com');
  assert.equal(store.remove(me.id), true);
  assert.equal(existsSync(store.claudeFolder(me.id)), false);
  assert.equal(row('me@example.com'), undefined);
});

test('version reading and percentages', () => {
  assert.deepEqual(claude.parseVersion('2.1.312 (Claude Code)'), [2, 1, 312]);
  assert.equal(claude.parseVersion('claude 2.1'), null);
  assert.equal(claude.normalizePercent(0.27), 27);
  assert.equal(claude.normalizePercent(1.0), 1);
  assert.equal(claude.normalizePercent(250), 100);
});
