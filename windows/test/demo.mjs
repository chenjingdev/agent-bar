// AgentBar with made-up accounts, for looking at it and pressing things without a real login: `node test/demo.mjs`
// (on Windows, with the node.exe AgentBar ships). Three Claude accounts and one Codex account; Anthropic, Claude Code
// and Codex are stand-ins, so switching and using a coupon really run, against nothing real. Everything lives in a
// folder under the temp folder; the real logins and the real AgentBar data are not touched.
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { startMock } from './mock-anthropic.mjs';

const root = process.env.AGENTBAR_DEMO_DIR || path.join(os.tmpdir(), 'agentbar-demo');
rmSync(root, { recursive: true, force: true });
const home = path.join(root, 'home'), data = path.join(root, 'data');
const people = [
  { name: 'work', plan: 'team', accountId: 'acc-work', email: 'work@example.com', organizationId: 'org-work', organization: 'Example Inc' },
  { name: 'me', plan: 'max', accountId: 'acc-me', email: 'me@example.com', organizationId: 'org-me', organization: "me@example.com's Organization" },
  { name: 'lab', plan: 'max', accountId: 'acc-lab', email: 'lab@example.com', organizationId: 'org-lab', organization: "lab@example.com's Organization" },
];
const identity = (person) => ({ email: person.email, organization: person.organization, organizationId: person.organizationId, accountId: person.accountId });
const login = (person) => JSON.stringify({ claudeAiOauth: { accessToken: `access-${person.name}`, refreshToken: `refresh-${person.name}-1`, expiresAt: Date.now() + 8 * 3600_000, scopes: ['user:inference', 'user:profile'], subscriptionType: person.plan } });
const put = (file, text) => { mkdirSync(path.dirname(file), { recursive: true }); writeFileSync(file, text); };

// Claude Code is signed in to "work"; "me" and "lab" wait in their own folders.
put(path.join(home, '.claude', '.credentials.json'), login(people[0]));
put(path.join(home, '.claude.json'), JSON.stringify({ oauthAccount: { accountUuid: 'acc-work', emailAddress: 'work@example.com', organizationUuid: 'org-work', organizationName: 'Example Inc' } }));
put(path.join(data, 'accounts.json'), JSON.stringify({ version: 1, accounts: people.map((person) => ({ id: `demo-${person.name}`, provider: 'claude', identity: identity(person), addedAt: 1 })) }));
for (const person of people.slice(1)) put(path.join(data, 'claude', `demo-${person.name}`, '.credentials.json'), login(person));
put(path.join(root, 'db.json'), JSON.stringify({ accounts: people }));

const day = 86400, fable = (percent, seconds) => ({ kind: 'weekly_scoped', percent, resets_in: seconds, scope: { model: { display_name: 'Fable' } } });
put(path.join(root, 'anthropic.json'), JSON.stringify({ usage: {
  work: { five_hour: { utilization: 59, resets_in: 27 * 60 }, seven_day: { utilization: 69, resets_in: 5 * day + 6 * 3600 }, limits: [fable(1, 5 * day + 6 * 3600)] },
  me: { five_hour: { utilization: 100, resets_in: 3 * 3600 + 12 * 60 }, seven_day: { utilization: 42, resets_in: 6 * day + 3600 }, limits: [fable(12, 6 * day + 3600)],
    cedar_ember: { eligible: true, at_limit: true, exhausted: ['five_hour'], next_grant_id: 'g-session', grants: [
      { id: 'g-session', resets_left: 2, ends_in: 3 * day, clears: ['five_hour'], type: 'session', usable_now: true, percent_used: { five_hour: 100 } },
      { id: 'g-week', resets_left: 1, ends_in: 20 * day, clears: ['seven_day'], type: 'weekly', usable_now: false, unavailable_reason: 'needs_limit' }] } },
  lab: { seven_day: { utilization: 19, resets_in: 6 * day + 18 * 3600 }, limits: [fable(1, 6 * day + 18 * 3600)] },
} }, null, 2));

const soon = Math.floor(Date.now() / 1000);
put(path.join(home, '.codex', 'auth.json'), '{}');
put(path.join(home, '.codex', 'fake.json'), JSON.stringify({
  account: { type: 'chatgpt', email: 'dev@example.com', accountId: 'codex-1', planType: 'pro' },
  rateLimits: { planType: 'pro', primary: { usedPercent: 12, windowDurationMins: 300, resetsAt: soon + 2 * 3600 }, secondary: { usedPercent: 27, windowDurationMins: 10080, resetsAt: soon + 5 * day },
  }, rateLimitResetCredits: { availableCount: 3, credits: [{ id: 'credit-a', status: 'available', expiresAt: soon + 14 * day }] },
}));

const port = await startMock(path.join(root, 'anthropic.json'));
Object.assign(process.env, {
  AGENTBAR_USER_HOME: home, AGENTBAR_HOME: data, AGENTBAR_ANTHROPIC_API: `http://127.0.0.1:${port}`, AGENTBAR_ANTHROPIC_TOKEN_URL: `http://127.0.0.1:${port}/v1/oauth/token`,
  AGENTBAR_CLAUDE_CLI: path.resolve(import.meta.dirname, 'fake-claude.mjs'), AGENTBAR_CODEX_CLI: path.resolve(import.meta.dirname, 'fake-codex.mjs'),
  FAKE_CLAUDE_DB: path.join(root, 'db.json'), FAKE_CLAUDE_BROWSER: path.join(root, 'browser'), AGENTBAR_NO_BROWSER: '1', AGENTBAR_TEST: '1',
});
delete process.env.CLAUDE_CONFIG_DIR; delete process.env.CODEX_HOME;
console.log(`demo in ${root}`);
await import('../app/main.mjs');
