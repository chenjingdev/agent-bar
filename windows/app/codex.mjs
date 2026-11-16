// Codex accounts, asked through Codex's own app-server (`codex app-server`, JSON lines on stdio), as the Mac app
// does (Sources/agent-bar/Core/ProviderProcess.swift, Providers/CodexUsageProvider.swift). AgentBar holds no Codex
// token: each account is a `CODEX_HOME` folder and Codex reads and renews the login in it.
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { cleanEnvironment, openInBrowser, startCLI } from './cli.mjs';
import { codexCoupons, codexOutcome } from './coupons.mjs';
import { userHome } from './paths.mjs';

const failure = (code, detail) => Object.assign(new Error(detail ?? code), { code });

// The Codex login Codex itself uses.
export const defaultCodexHome = () => process.env.CODEX_HOME || path.join(userHome, '.codex');

export class CodexRPC {
  #child; #buffer = ''; #waiting = new Map(); #nextId = 1; #onNotification = null; #closed = false; #gone;

  // `home` is the account's folder.
  static async open(home, { requestTimeout = 25_000 } = {}) {
    const rpc = new CodexRPC(home, requestTimeout);
    try {
      await rpc.request('initialize', { clientInfo: { name: 'agent-bar', version: '0.2.0' }, capabilities: { experimentalApi: true } });
      rpc.#send({ method: 'initialized' });
    } catch (error) { await rpc.stop(); throw error; }
    return rpc;
  }

  constructor(home, requestTimeout) {
    this.requestTimeout = requestTimeout;
    // File storage keeps each account's login in its own folder.
    this.#child = startCLI('codex', ['app-server', '--listen', 'stdio://', '-c', 'cli_auth_credentials_store="file"'],
      { env: cleanEnvironment({ CODEX_HOME: home }), cwd: userHome });
    this.#child.stdout.setEncoding('utf8');
    this.#child.stdout.on('data', (chunk) => this.#read(chunk));
    this.#child.stderr.resume();
    this.#child.stdin.on('error', () => {});
    const end = () => {
      this.#closed = true;
      for (const { reject } of this.#waiting.values()) reject(failure('closed'));
      this.#waiting.clear();
    };
    this.#child.on('error', end);
    this.#child.on('close', end);
    // Done when the app-server has let go of the account's folder: on Windows its files stay locked until then.
    this.#gone = new Promise((resolve) => { this.#child.on('close', resolve); this.#child.on('error', resolve); });
  }

  #send(value) { if (!this.#closed) this.#child.stdin.write(`${JSON.stringify(value)}\n`); }

  #read(chunk) {
    this.#buffer += chunk;
    for (let end = this.#buffer.indexOf('\n'); end !== -1; end = this.#buffer.indexOf('\n')) {
      const line = this.#buffer.slice(0, end);
      this.#buffer = this.#buffer.slice(end + 1);
      let value;
      try { value = JSON.parse(line); } catch { continue; }
      const waiting = this.#waiting.get(value.id);
      if (waiting && !value.method) {
        this.#waiting.delete(value.id);
        if (value.error) waiting.reject(this.#classify(value.error, waiting.method)); else waiting.resolve(value.result ?? {});
      } else if (value.method) this.#onNotification?.(value);
    }
  }

  // Raw provider messages are not passed on: they can hold account details.
  #classify(error, method) {
    const message = String(error.message ?? '').toLowerCase();
    if (/401|unauthorized|not logged|authentication/.test(message)) return failure('login');
    if (/429|rate limit/.test(message)) return Object.assign(failure('rate-limited'), { retryAfter: Math.max(60, error.data?.retryAfterSeconds ?? 60) });
    return failure('request', method);
  }

  request(method, params = null, timeout = this.requestTimeout) {
    return new Promise((resolve, reject) => {
      if (this.#closed) { reject(failure('closed')); return; }
      const id = this.#nextId++;
      const timer = setTimeout(() => { this.#waiting.delete(id); reject(failure('timeout')); }, timeout);
      this.#waiting.set(id, {
        method, resolve: (value) => { clearTimeout(timer); resolve(value); }, reject: (error) => { clearTimeout(timer); reject(error); },
      });
      this.#send({ id, method, params });
    });
  }

  async identity(refresh = false) {
    const result = await this.request('account/read', { refreshToken: refresh });
    if (result.account?.type !== 'chatgpt') throw failure('login');
    return { email: result.account.email ?? null, organization: null, organizationId: null, accountId: result.account.accountId ?? null, plan: result.account.planType ?? null };
  }

  // The browser sign-in: Codex gives the address, the person signs in, Codex says when it is done.
  // `control.cancel()` gives it up.
  async login(control = {}) {
    const result = await this.request('account/login/start', { type: 'chatgpt' });
    let url;
    try { url = new URL(result.authUrl); } catch { throw failure('request'); }
    if (!result.loginId || url.protocol !== 'https:' || !(url.hostname === 'auth.openai.com' || url.hostname.endsWith('.openai.com'))) throw failure('request');
    const completed = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(failure('timeout')), 300_000);
      control.cancel = () => { clearTimeout(timer); reject(failure('cancelled')); };
      this.#onNotification = (value) => {
        if (value.method !== 'account/login/completed' || value.params?.loginId !== result.loginId) return;
        clearTimeout(timer);
        if (value.params.success === true) resolve(); else reject(failure('login'));
      };
      this.#child.on('close', () => { clearTimeout(timer); reject(failure('closed')); });
    });
    openInBrowser(url.href);
    try { await completed; } catch (error) {
      this.#send({ id: 999999, method: 'account/login/cancel', params: { loginId: result.loginId } });
      throw error;
    }
    return this.identity();
  }

  // Ends the app-server. Answers when it has ended (5 seconds at most).
  stop() {
    if (!this.#closed) {
      this.#closed = true;
      try { this.#child.stdin.end(); } catch {}
      this.#child.kill();
    }
    return Promise.race([this.#gone, new Promise((resolve) => setTimeout(resolve, 5000).unref())]);
  }
}

const titleCase = (text) => (text ? text[0].toUpperCase() + text.slice(1).toLowerCase() : null);

// Codex names its two windows by length: 300 minutes and 10080 minutes.
export function mapRateLimits(rateLimits) {
  const windows = [rateLimits?.primary, rateLimits?.secondary].filter(Boolean);
  const fiveHour = windows.find((window) => window.windowDurationMins === 300)
    ?? (rateLimits?.primary && rateLimits.primary.windowDurationMins == null ? rateLimits.primary : null);
  const weekly = windows.find((window) => window.windowDurationMins === 10_080)
    ?? (rateLimits?.secondary && rateLimits.secondary.windowDurationMins == null ? rateLimits.secondary : null);
  const shown = (window) => (window ? { used: Math.round(window.usedPercent), resetAt: Number.isFinite(window.resetsAt) ? window.resetsAt * 1000 : null } : null);
  return { plan: titleCase(rateLimits?.planType), fiveHour: shown(fiveHour), weekly: shown(weekly) };
}

// Reads one account. Never throws: what went wrong is in the answer's `error`. `memory` keeps the last good
// answer and the wait a refusal asked for.
export async function loadCodex(home, expectedIdentity, memory, { force = false } = {}) {
  const now = Date.now();
  if (memory.retryUntil > now) return codexSnapshot(memory);
  if (!force && memory.at && now - memory.at < (memory.error ? 15_000 : 60_000)) return codexSnapshot(memory);
  let rpc;
  try {
    rpc = await CodexRPC.open(home);
    const identity = await rpc.identity();
    if (expectedIdentity && sameCodexAccount(identity, expectedIdentity) === false) throw failure('changed');
    let response;
    try { response = await rpc.request('account/rateLimits/read'); } catch (error) {
      if (error.code !== 'login') throw error;
      await rpc.identity(true);
      response = await rpc.request('account/rateLimits/read');
    }
    const usage = { ...mapRateLimits(response.rateLimits), coupons: codexCoupons(response, now) };
    Object.assign(memory, { at: now, usageAt: now, error: null, usage, identity, retryUntil: 0 });
  } catch (error) {
    Object.assign(memory, { at: now, error: error.code ?? 'request', retryUntil: error.code === 'rate-limited' ? now + error.retryAfter * 1000 : 0 });
  } finally { await rpc?.stop(); }
  return codexSnapshot(memory);
}

// false only when both name an account and the names differ.
export function sameCodexAccount(one, other) {
  if (one?.accountId && other?.accountId) return one.accountId === other.accountId;
  if (one?.email && other?.email) return one.email.toLowerCase() === other.email.toLowerCase();
  return null;
}

function codexSnapshot(memory) {
  const usage = memory.usage;
  return {
    provider: 'codex', updatedAt: usage ? memory.usageAt ?? null : null, identity: memory.identity ?? null,
    fiveHour: usage?.fiveHour ?? null, weekly: usage?.weekly ?? null, weeklyLabel: null, models: [], plan: usage?.plan ?? null,
    error: memory.error ?? null, stale: Boolean(memory.error), requiresLogin: memory.error === 'login',
    coupons: memory.error ? null : usage?.coupons ?? null,
  };
}

// Uses the coupon a person confirmed, through the account's own app-server.
export async function useCodexCoupon(home, expectedIdentity, memory, claim) {
  if (claim?.type !== 'codex') return 'tryLater';
  let rpc;
  try {
    rpc = await CodexRPC.open(home);
    if (expectedIdentity && sameCodexAccount(await rpc.identity(), expectedIdentity) === false) return 'signInAgain';
    const params = { idempotencyKey: randomUUID(), ...(claim.creditId ? { creditId: claim.creditId } : {}) };
    const outcome = codexOutcome(await rpc.request('account/rateLimitResetCredit/consume', params));
    if (outcome === 'reset') memory.at = 0;
    return outcome;
  } catch (error) {
    return error.code === 'login' ? 'signInAgain' : 'tryLater';
  } finally { await rpc?.stop(); }
}

// Signs a new account in with the browser into `home`. Answers its identity.
export async function loginCodex(home, control) {
  const rpc = await CodexRPC.open(home);
  try { return await rpc.login(control); } finally { await rpc.stop(); }
}
