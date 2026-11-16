// A stand-in for Claude Code in tests: `--version` and `auth login --claudeai`, writing a login the way Claude Code
// does on Windows (a credentials file in the config folder, the account in .claude.json).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const db = () => JSON.parse(readFileSync(process.env.FAKE_CLAUDE_DB, 'utf8'));
if (args[0] === '--version') { console.log(`${process.env.FAKE_CLAUDE_VERSION ?? '2.1.322'} (Claude Code)`); process.exit(0); }
if (args.join(' ') !== 'auth login --claudeai') process.exit(2);

const folder = process.env.CLAUDE_CONFIG_DIR;
const directory = folder ?? path.join(process.env.AGENTBAR_USER_HOME, '.claude');
const identityFile = folder ? path.join(folder, '.claude.json') : path.join(process.env.AGENTBAR_USER_HOME, '.claude.json');

function signIn(account, refreshToken) {
  mkdirSync(directory, { recursive: true });
  writeFileSync(path.join(directory, '.credentials.json'), JSON.stringify({ claudeAiOauth: {
    accessToken: `access-${account.name}-${Date.now()}`, refreshToken, expiresAt: Date.now() + 3600_000,
    scopes: ['user:inference', 'user:profile'], subscriptionType: account.plan,
  } }));
  const config = existsSync(identityFile) ? JSON.parse(readFileSync(identityFile, 'utf8')) : {};
  config.oauthAccount = { accountUuid: account.accountId, emailAddress: account.email, organizationUuid: account.organizationId, organizationName: account.organization };
  writeFileSync(identityFile, JSON.stringify(config));
}

const token = process.env.CLAUDE_CODE_OAUTH_REFRESH_TOKEN;
if (token) {
  const account = db().accounts.find((item) => token.startsWith(`refresh-${item.name}`));
  if (!account || db().refused?.includes(token)) { console.error('Login failed: Request failed with status code 400'); process.exit(1); }
  if (process.env.FAKE_CLAUDE_FAIL) { console.error('Login failed: connect ECONNREFUSED 127.0.0.1:9'); process.exit(1); }
  signIn(account, `${token}+`);
  console.log('Login successful.');
  process.exit(0);
}
// The browser sign-in: the test "signs in" by writing the account's name to a file.
console.log('Opening browser to sign in…\nIf the browser didn\'t open, visit: https://claude.ai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A1234%2Fcallback');
const wait = setInterval(() => {
  if (!existsSync(process.env.FAKE_CLAUDE_BROWSER)) return;
  clearInterval(wait);
  const account = db().accounts.find((item) => item.name === readFileSync(process.env.FAKE_CLAUDE_BROWSER, 'utf8').trim());
  signIn(account, `refresh-${account.name}-browser`);
  console.log('Login successful.');
  process.exit(0);
}, 20);
