// Claude accounts: where a login is kept, how its usage and coupons are read, and how a coupon is used.
// Anthropic is asked the way the Mac app asks (Sources/agent-bar/Providers/ClaudeUsageProvider.swift): every
// request names the installed Claude Code, and the usage read brings the coupons too now and then.
import { createHash, randomUUID } from 'node:crypto';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import zlib from 'node:zlib';
import { cleanEnvironment, runCLI } from './cli.mjs';
import { cedarBlock, cedarCanRedeem, cedarCoupons, cedarOutcome, parseDate, pruneExpired } from './coupons.mjs';
import { userHome, writeAtomic } from './paths.mjs';

export const endpoints = {
  api: process.env.AGENTBAR_ANTHROPIC_API || 'https://api.anthropic.com',
  token: process.env.AGENTBAR_ANTHROPIC_TOKEN_URL || 'https://platform.claude.com/v1/oauth/token',
};

const SUCCESS_TTL = 60_000, FAILURE_TTL = 15_000, RATE_LIMITED_BASE = 60_000, RATE_LIMITED_MAX = 5 * 60_000;
const COUPON_INTERVAL = 30 * 60_000, COUPON_INELIGIBLE_INTERVAL = 6 * 60 * 60_000, COUPON_FAILURE_INTERVAL = 5 * 60_000;
// Claude Code renews its own login a few minutes before it runs out. AgentBar renews the login Claude Code is
// using only when it has been out for this long, which means no Claude Code is running to do it.
const LIVE_RENEW_GRACE = 2 * 60_000;

// MARK: Where a login is

// The login Claude Code uses when it starts by itself.
export function liveSlot() {
  const directory = process.env.CLAUDE_CONFIG_DIR;
  if (directory) return { ...folderSlot(directory), live: true };
  const home = path.join(userHome, '.claude');
  return { live: true, directory: home, credentialsFile: path.join(home, '.credentials.json'), identityFile: path.join(userHome, '.claude.json') };
}

// A login kept in a folder of its own (`CLAUDE_CONFIG_DIR`).
export function folderSlot(directory) {
  return { live: false, directory, credentialsFile: path.join(directory, '.credentials.json'), identityFile: path.join(directory, '.claude.json') };
}

// The signed-in account recorded in the CLI's config file; null when there is none.
export function readIdentity(slot) {
  const legacy = path.join(slot.directory, '.config.json');
  let account;
  try { account = JSON.parse(readFileSync(existsSync(legacy) ? legacy : slot.identityFile, 'utf8')).oauthAccount; } catch { return null; }
  if (!account || typeof account !== 'object') return null;
  return {
    email: account.emailAddress ?? null, organization: account.organizationName ?? null,
    organizationId: account.organizationUuid ?? null, accountId: account.accountUuid ?? null,
  };
}

// What a slot holds now: the login and the account recorded beside it. Answers a function that puts them back,
// leaving the rest of Claude Code's config file as it is then.
export function keepLogin(slot) {
  const legacy = path.join(slot.directory, '.config.json');
  const file = existsSync(legacy) ? legacy : slot.identityFile;
  let credentials = null, account;
  try { credentials = readFileSync(slot.credentialsFile, 'utf8'); } catch {}
  try { account = JSON.parse(readFileSync(file, 'utf8')).oauthAccount; } catch {}
  return () => {
    if (credentials === null) rmSync(slot.credentialsFile, { force: true }); else writeAtomic(slot.credentialsFile, credentials);
    try {
      const config = JSON.parse(readFileSync(file, 'utf8'));
      if (account === undefined) delete config.oauthAccount; else config.oauthAccount = account;
      writeAtomic(file, JSON.stringify(config, null, 2));
    } catch {}
  };
}

// The environment Claude Code gets when it signs in where it keeps its own login: the folder the person pointed
// it to with CLAUDE_CONFIG_DIR stays, so the login lands where AgentBar reads it.
export function liveEnvironment(extra = {}) {
  const kept = {};
  for (const key of ['CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR']) if (process.env[key]) kept[key] = process.env[key];
  return cleanEnvironment({ ...kept, ...extra });
}

// Email is display information, not an identifier the provider guarantees.
export function compareIdentity(one, other) {
  if (!one || !other) return 'unverified';
  if (one.accountId && other.accountId) return one.accountId === other.accountId && one.organizationId === other.organizationId ? 'same' : 'different';
  if (one.email && other.email && one.email.toLowerCase() !== other.email.toLowerCase()) return 'different';
  if (one.organizationId && other.organizationId && one.organizationId !== other.organizationId) return 'different';
  return 'unverified';
}

// The login in a slot; null when there is none. `key` changes whenever the file does.
export function readCredentials(slot) {
  let raw;
  try { raw = readFileSync(slot.credentialsFile, 'utf8'); } catch { return null; }
  let oauth;
  try { oauth = JSON.parse(raw).claudeAiOauth; } catch { return null; }
  if (!oauth?.accessToken) return null;
  return {
    raw, accessToken: oauth.accessToken, refreshToken: oauth.refreshToken || null,
    scopes: Array.isArray(oauth.scopes) ? oauth.scopes : [], expiresAt: Number.isFinite(oauth.expiresAt) ? oauth.expiresAt : null,
    subscriptionType: oauth.subscriptionType ?? '', key: createHash('sha256').update(raw).digest('hex').slice(0, 32),
  };
}

const isExpired = (credentials, now = Date.now()) => credentials.expiresAt !== null && credentials.expiresAt <= now;

// MARK: Naming the installed Claude Code

export function parseVersion(output) {
  const match = /^\s*(\d+)\.(\d+)\.(\d+)(?:[\s(+-].*)?$/.exec((output ?? '').split(/\r?\n/)[0] ?? '');
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}
export const versionAtLeast = (version, minimum) => {
  for (let index = 0; index < 3; index++) if (version[index] !== minimum[index]) return version[index] > minimum[index];
  return true;
};
// Switching needs the refresh-token sign-in that 2.1.309 added; the coupon program refuses a client older than 2.1.295.
export const SWITCH_MINIMUM = [2, 1, 309];
const COUPON_MINIMUM = [2, 1, 295];

let installed; // undefined until asked, then the version or null
export async function installedVersion() {
  if (installed !== undefined) return installed;
  try {
    const output = await runCLI('claude', ['--version'], { timeout: 10_000 });
    installed = output.status === 0 ? parseVersion(output.text) : null;
  } catch { installed = null; }
  return installed;
}
export function forgetInstalledVersion() { installed = undefined; }
export async function userAgent() {
  const version = await installedVersion();
  const named = version && versionAtLeast(version, COUPON_MINIMUM) ? version : COUPON_MINIMUM;
  return `claude-cli/${named.join('.')} (external, cli)`;
}

// MARK: Renewing a login

// Anthropic's answer when it stops apps other than Claude Code from using a Claude sign-in.
export function isAccessBlock(status, body) {
  if (![400, 401, 403].includes(status)) return false;
  const lowered = String(body ?? '').slice(0, 8192).toLowerCase();
  return ['only authorized for use with claude code', 'third-party', 'third party'].some((phrase) => lowered.includes(phrase));
}

const failure = (code, detail) => Object.assign(new Error(detail ?? code), { code });
const renewing = new Map();

// Exchanges the refresh token and writes the new login to the same file. Readers that come at once share one
// exchange, because the provider may replace the refresh token on every use.
export function renew(slot, credentials) {
  const running = renewing.get(slot.credentialsFile);
  if (running) return running;
  const task = exchange(slot, credentials).finally(() => renewing.delete(slot.credentialsFile));
  renewing.set(slot.credentialsFile, task);
  return task;
}

// Claude Code renews its login with the axios it bundles (Claude Code 2.1.325, axios 1.15.2,
// `axios.post(TOKEN_URL, body, { headers: { "Content-Type": "application/json" } })`), not under its claude-cli name,
// so the renewal goes out with the headers axios sends from Node. Node's fetch would add its own browser-like ones.
function postLikeClaudeCode(address, text) {
  const url = new URL(address);
  return new Promise((resolve, reject) => {
    const request = (url.protocol === 'http:' ? http : https).request(url, {
      method: 'POST', timeout: 30_000,
      headers: {
        Accept: 'application/json, text/plain, */*', 'Content-Type': 'application/json', 'User-Agent': 'axios/1.15.2',
        'Content-Length': Buffer.byteLength(text), 'Accept-Encoding': 'gzip, compress, deflate, br',
      },
    }, (response) => {
      const encoding = String(response.headers['content-encoding'] ?? '').toLowerCase();
      const body = encoding.includes('gzip') ? response.pipe(zlib.createGunzip()) : encoding.includes('deflate') ? response.pipe(zlib.createInflate())
        : encoding.includes('br') ? response.pipe(zlib.createBrotliDecompress()) : response;
      let answer = '';
      body.setEncoding('utf8');
      body.on('data', (chunk) => { answer += chunk; });
      body.on('end', () => resolve({ status: response.statusCode, text: answer }));
      body.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('timeout')));
    request.on('error', reject);
    request.end(text);
  });
}

async function exchange(slot, credentials) {
  if (!credentials.refreshToken) throw failure('login');
  // Official Claude Code OAuth endpoint and client. The granted scope is kept, not widened.
  const body = { grant_type: 'refresh_token', refresh_token: credentials.refreshToken, client_id: '9d1c250a-e61b-44d9-88ed-5944d1962f5e' };
  if (credentials.scopes.length) body.scope = credentials.scopes.join(' ');
  let status, answer;
  try { ({ status, text: answer } = await postLikeClaudeCode(endpoints.token, JSON.stringify(body))); } catch { throw failure('network'); }
  if (status !== 200) {
    if ([400, 401, 403].includes(status)) throw failure(isAccessBlock(status, answer) ? 'blocked' : 'login');
    throw failure(status === 429 ? 'rate-limited' : 'network');
  }
  let result;
  try { result = JSON.parse(answer); } catch { throw failure('parse'); }
  if (!result.access_token || !(result.expires_in > 0)) throw failure('parse');
  // Never recreate a removed account or overwrite a login that changed meanwhile.
  let current;
  try { current = readFileSync(slot.credentialsFile, 'utf8'); } catch { throw failure('changed'); }
  if (current !== credentials.raw) throw failure('changed');
  const document = JSON.parse(current);
  document.claudeAiOauth = {
    ...document.claudeAiOauth, accessToken: result.access_token, expiresAt: Math.floor(Date.now() + result.expires_in * 1000),
    ...(result.refresh_token ? { refreshToken: result.refresh_token } : {}),
    ...(typeof result.scope === 'string' ? { scopes: result.scope.split(' ').filter(Boolean) } : {}),
  };
  writeAtomic(slot.credentialsFile, JSON.stringify(document));
}

// A login that can be sent now, renewed first when it has run out. Null when the slot holds none.
async function usableCredentials(slot) {
  let credentials = readCredentials(slot);
  if (!credentials) return null;
  if (!isExpired(credentials)) return credentials;
  if (slot.live && Date.now() - credentials.expiresAt < LIVE_RENEW_GRACE) throw failure('renewing');
  await renew(slot, credentials);
  credentials = readCredentials(slot);
  if (!credentials || isExpired(credentials)) throw failure('login');
  return credentials;
}

// MARK: Reading usage

// Claude answers a fraction (0.27 is 27%) or a whole percentage written as a decimal (1.0 is 1%).
export function normalizePercent(raw) {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return 0;
  const scaled = raw >= 0 && raw < 1 ? raw * 100 : raw;
  return Math.round(Math.min(Math.max(scaled, 0), 100));
}

const windowOf = (raw) => (raw ? { used: typeof raw.utilization === 'number' ? normalizePercent(raw.utilization) : null, resetAt: parseDate(raw.resets_at) } : null);

export function planName(subscriptionType) {
  const normalized = (subscriptionType ?? '').trim().toLowerCase();
  if (!normalized) return null;
  for (const [word, name] of [['max', 'Max'], ['pro', 'Pro'], ['team', 'Team'], ['enterprise', 'Enterprise']]) if (normalized.includes(word)) return name;
  return normalized[0].toUpperCase() + normalized.slice(1);
}

// The usage answer as the panel shows it.
export function mapUsage(payload) {
  const limits = Array.isArray(payload.limits) ? payload.limits : [];
  const all = limits.find((limit) => limit.kind === 'weekly_all');
  const weekly = payload.seven_day ? { window: windowOf(payload.seven_day) }
    : all ? { window: { used: typeof all.percent === 'number' ? normalizePercent(all.percent) : null, resetAt: parseDate(all.resets_at) } }
    : payload.seven_day_oauth_apps ? { window: windowOf(payload.seven_day_oauth_apps), label: 'OAuth Apps 7-day' }
    : payload.seven_day_sonnet ? { window: windowOf(payload.seven_day_sonnet), label: 'Sonnet 7-day' }
    : payload.seven_day_opus ? { window: windowOf(payload.seven_day_opus), label: 'Opus 7-day' } : null;
  const scoped = limits.filter((limit) => limit.kind === 'weekly_scoped');
  const models = scoped.length
    ? scoped.map((limit) => ({ label: limit.scope?.model?.display_name ?? 'Model', used: typeof limit.percent === 'number' ? normalizePercent(limit.percent) : null, resetAt: parseDate(limit.resets_at) }))
    : [['Sonnet', payload.seven_day_sonnet], ['Opus', payload.seven_day_opus]].filter(([, raw]) => raw).map(([label, raw]) => ({ label, ...windowOf(raw) }));
  return { fiveHour: windowOf(payload.five_hour), weekly: weekly?.window ?? null, weeklyLabel: weekly?.label ?? null, models };
}

function retryAfterSeconds(header) {
  if (!header) return null;
  const seconds = Number.parseInt(header.trim(), 10);
  if (seconds > 0) return seconds;
  const date = Date.parse(header);
  return Number.isNaN(date) ? null : Math.max(1, Math.ceil((date - Date.now()) / 1000));
}

// With `withCoupons` the same read also brings the account's coupons. A second read right after the first is
// refused (429), so the coupons never get a request of their own.
async function requestUsage(accessToken, withCoupons) {
  const url = `${endpoints.api}/api/oauth/usage${withCoupons ? '?cedar_ember=1&skip_spend=1' : ''}`;
  let response, body;
  try {
    response = await fetch(url, {
      headers: { authorization: `Bearer ${accessToken}`, 'anthropic-beta': 'oauth-2025-04-20', 'user-agent': await userAgent() },
      signal: AbortSignal.timeout(15_000),
    });
    body = await response.text();
  } catch (error) { return { error: error?.name === 'TimeoutError' ? 'timeout' : 'network' }; }
  if (response.status !== 200) {
    return {
      status: response.status,
      error: isAccessBlock(response.status, body) ? 'blocked' : response.status === 429 ? 'rate-limited' : `http-${response.status}`,
      retryAfter: response.status === 429 ? retryAfterSeconds(response.headers.get('retry-after')) : null,
    };
  }
  try { return { status: 200, payload: JSON.parse(body) }; } catch { return { status: 200, error: 'parse' }; }
}

// Usage matters more than coupons: if the coupon flag is refused (a 4xx other than 401, 403 and 429), read plain usage instead.
async function fetchUsage(accessToken, withCoupons) {
  const result = await requestUsage(accessToken, withCoupons);
  if (!withCoupons || !(result.status >= 400 && result.status < 500) || [401, 403, 429].includes(result.status)) return result;
  return { ...(await requestUsage(accessToken, false)), couponsRefused: true };
}

const requiresLogin = (error) => ['login', 'missing-credentials', 'http-401', 'http-403'].includes(error);

// What is known about one account between reads. `memory` is kept by the caller and saved beside the account:
// { key, at, usage, error, rateLimitedCount, retryUntil, lastGood, lastGoodAt, force, coupons, couponCheck, couponAgent }.
function rateLimitedUntil(memory) {
  if (memory.error !== 'rate-limited') return null;
  if (memory.retryUntil > memory.at) return memory.retryUntil;
  if (!(memory.rateLimitedCount > 0)) return null;
  return memory.at + Math.min(RATE_LIMITED_BASE * 2 ** (memory.rateLimitedCount - 1), RATE_LIMITED_MAX);
}

function snapshot(memory, credentials) {
  const failed = Boolean(memory.error);
  const shown = failed ? memory.lastGood : memory.usage;
  return {
    provider: 'claude', updatedAt: (failed ? memory.lastGoodAt : memory.at) ?? null,
    fiveHour: shown?.fiveHour ?? null, weekly: shown?.weekly ?? null, weeklyLabel: shown?.weeklyLabel ?? null, models: shown?.models ?? [],
    plan: planName(credentials?.subscriptionType) ?? memory.plan ?? null,
    error: memory.error ?? null, stale: failed, requiresLogin: requiresLogin(memory.error),
    coupons: failed ? null : pruneExpired(memory.coupons ?? null),
  };
}

// Reads one account. Never throws: what went wrong is in the answer's `error`.
export async function loadClaude(slot, memory, { force = false } = {}) {
  const now = Date.now();
  let credentials;
  try { credentials = await usableCredentials(slot); } catch (error) {
    if (error.code === 'renewing') return snapshot(memory, readCredentials(slot));
    Object.assign(memory, { error: error.code === 'changed' ? 'network' : error.code, at: now });
    return snapshot(memory, null);
  }
  if (!credentials) {
    Object.assign(memory, { error: 'missing-credentials', at: now, key: null });
    return snapshot(memory, null);
  }
  const sameLogin = memory.key === credentials.key;
  if (!sameLogin) Object.assign(memory, { rateLimitedCount: 0, retryUntil: 0 });
  if (sameLogin && memory.at) {
    const waitUntil = rateLimitedUntil(memory);
    if (waitUntil && now < waitUntil) return snapshot(memory, credentials);
    if (!force && !memory.force && now - memory.at < (memory.error ? FAILURE_TTL : SUCCESS_TTL)) return snapshot(memory, credentials);
  }
  const agent = await userAgent();
  if (memory.couponAgent !== agent) Object.assign(memory, { coupons: null, couponCheck: 0, couponAgent: agent });
  const withCoupons = now >= (memory.couponCheck ?? 0);
  const result = await fetchUsage(credentials.accessToken, withCoupons);
  // The login may have changed while Anthropic answered: this answer belongs to the old one.
  if (readCredentials(slot)?.key !== credentials.key) return snapshot(memory, credentials);
  memory.key = credentials.key;
  memory.plan = planName(credentials.subscriptionType);
  memory.force = false;
  if (result.payload) {
    const usage = mapUsage(result.payload);
    Object.assign(memory, { usage, at: now, error: null, rateLimitedCount: 0, retryUntil: 0, lastGood: usage, lastGoodAt: now });
    if (result.couponsRefused) memory.couponCheck = now + COUPON_FAILURE_INTERVAL;
    else if (withCoupons) noteCoupons(memory, result.payload, credentials.subscriptionType, now);
    return snapshot(memory, credentials);
  }
  const rateLimited = result.error === 'rate-limited';
  Object.assign(memory, {
    error: result.error, at: now, rateLimitedCount: rateLimited ? (memory.rateLimitedCount ?? 0) + 1 : 0,
    retryUntil: rateLimited && result.retryAfter ? now + result.retryAfter * 1000 : 0,
  });
  return snapshot(memory, credentials);
}

// Keeps the coupons a usage answer brought and decides when to ask again: after 30 minutes, after 6 hours while
// the account cannot have any, after 5 minutes when the service could not say or one is waiting.
function noteCoupons(memory, payload, subscriptionType, now) {
  const block = cedarBlock(payload);
  if (block && block.eligible !== true && block.ineligibleReason === 'unavailable') {
    memory.couponCheck = now + COUPON_FAILURE_INTERVAL;
    return;
  }
  // The usage answer can leave the 5-hour window out before it has data.
  const plan = (subscriptionType ?? '').trim().toLowerCase();
  const hasFiveHour = Boolean(payload.five_hour) || plan === 'max' || plan === 'pro';
  memory.coupons = block ? cedarCoupons(block, hasFiveHour, now) : null;
  if (block?.eligible === true) {
    const waiting = memory.coupons?.options.some((item) => !(item.count > 0 && item.redeemable));
    memory.couponCheck = now + (waiting ? COUPON_FAILURE_INTERVAL : COUPON_INTERVAL);
  } else memory.couponCheck = now + COUPON_INELIGIBLE_INTERVAL;
}

// MARK: Using a coupon

// A claim whose answer did not say whether it went through. Pressing again within 10 minutes sends the same
// request id, so the service does not use a second coupon.
const pendingClaims = new Map();

// Uses the grant a person confirmed. Answers how it ended: reset, nothingToReset, conditionsChanged, noCoupon,
// signInAgain or tryLater.
export async function useClaudeCoupon(slot, identity, memory, claim) {
  const organization = identity?.organizationId;
  if (!organization || !/^[A-Za-z0-9-]{1,64}$/.test(organization) || claim?.type !== 'claude') return 'signInAgain';
  let credentials;
  try { credentials = await usableCredentials(slot); } catch (error) { return requiresLogin(error.code) ? 'signInAgain' : 'tryLater'; }
  if (!credentials) return 'signInAgain';
  const claimKey = `${organization}:${claim.grantId}`;
  const held = pendingClaims.get(claimKey);
  const retryId = held && Date.now() - held.at < 600_000 ? held.id : null;
  if (!retryId) {
    const check = await requestUsage(credentials.accessToken, true);
    if (check.status === 401) return 'signInAgain';
    // A read right after the panel's own read is refused (429), and the coupons were chosen from that fresh
    // read: go on without the check, as Claude Code does. Claude still checks the grant itself.
    if (check.status !== 429) {
      const block = check.payload && cedarBlock(check.payload);
      if (!block) return 'tryLater';
      noteCoupons(memory, check.payload, credentials.subscriptionType, Date.now());
      const selected = memory.coupons?.options.find((item) => item.claim.grantId === claim.grantId);
      if (!cedarCanRedeem(claim.grantId, block) || !selected?.redeemable) return 'conditionsChanged';
    }
  }
  if (readCredentials(slot)?.key !== credentials.key) return 'signInAgain';
  const requestId = retryId ?? randomUUID();
  const remember = () => pendingClaims.set(claimKey, { id: requestId, at: Date.now() });
  let response, body;
  try {
    response = await fetch(`${endpoints.api}/api/organizations/${organization}/reset_rate_limits`, {
      method: 'POST', signal: AbortSignal.timeout(25_000),
      headers: { authorization: `Bearer ${credentials.accessToken}`, 'anthropic-beta': 'oauth-2025-04-20', 'content-type': 'application/json', 'user-agent': await userAgent() },
      body: JSON.stringify({ program: 'cedar_ember', grant_id: claim.grantId, request_id: requestId }),
    });
    body = await response.text();
  } catch { remember(); return 'tryLater'; }
  if (response.status >= 200 && response.status < 300) {
    let answer = null;
    try { answer = JSON.parse(body); } catch {}
    const { outcome, unconfirmed } = cedarOutcome(answer);
    if (unconfirmed) remember(); else pendingClaims.delete(claimKey);
    // The next read asks again instead of showing the last minute's numbers.
    if (outcome === 'reset') Object.assign(memory, { force: true, couponCheck: 0 });
    return outcome;
  }
  if (response.status === 401) return 'signInAgain';
  if (response.status === 403) return isAccessBlock(403, body) ? 'tryLater' : 'signInAgain';
  if (response.status === 429) return 'tryLater';
  // It may have gone through; a second press sends the same request id.
  remember();
  return 'tryLater';
}
