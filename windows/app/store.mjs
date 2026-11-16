// The accounts AgentBar knows and what it last read about each: the one object the tray, the panel and the tests talk to.
//
// A Claude account's login is in one of two places. The account Claude Code is using has it in Claude Code's own
// folder (the "live" login); every other account has it in a folder of its own under AgentBar's data folder, where
// only AgentBar reads and renews it. Switching hands a folder login to Claude Code with Claude Code's own command
// (`claude auth login --claudeai`, fed the refresh token, as the Mac app does) and moves the login that was live
// into its account's folder, so each login exists once.
//
// A Codex account is a `CODEX_HOME` folder; the one Codex itself uses is always shown.
import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { existsSync, mkdirSync, renameSync, rmSync } from 'node:fs';
import path from 'node:path';
import { cleanEnvironment, findCLI, runCLI } from './cli.mjs';
import {
  compareIdentity, folderSlot, forgetInstalledVersion, installedVersion, keepLogin, liveEnvironment, liveSlot, loadClaude, readCredentials, readIdentity,
  SWITCH_MINIMUM, useClaudeCoupon, versionAtLeast,
} from './claude.mjs';
import { defaultCodexHome, loadCodex, loginCodex, sameCodexAccount, useCodexCoupon } from './codex.mjs';
import { dataRoot, readJSON, version, writeAtomic } from './paths.mjs';

export const CODEX_DEFAULT = 'codex-default';

export class Store extends EventEmitter {
  constructor(root = dataRoot) {
    super();
    this.root = root;
    this.registryFile = path.join(root, 'accounts.json');
    const saved = readJSON(this.registryFile);
    this.accounts = saved?.accounts ?? [];
    this.settings = { interval: 120, ...saved?.settings };
    this.memory = new Map();
    this.snapshots = new Map();
    this.reading = new Map(); // id → the read of that account going on now
    this.liveClaudeId = null;
    this.activity = null; // { kind: 'switch' | 'add' | 'coupon', provider, id, control }
    this.notice = null; // { code, at, detail }
    this.refreshing = false;
    this.claudeVersion = undefined;
  }

  // MARK: Files

  save() { writeAtomic(this.registryFile, JSON.stringify({ version: 1, accounts: this.accounts, settings: this.settings }, null, 2)); }
  claudeFolder(id) { return path.join(this.root, 'claude', id); }
  codexFolder(id) { return id === CODEX_DEFAULT ? defaultCodexHome() : path.join(this.root, 'codex', id); }
  memoryOf(id) {
    if (!this.memory.has(id)) this.memory.set(id, readJSON(path.join(this.root, 'cache', `${id}.json`)) ?? {});
    return this.memory.get(id);
  }
  keep(id) { writeAtomic(path.join(this.root, 'cache', `${id}.json`), JSON.stringify(this.memoryOf(id))); }
  slotOf(account) { return account.id === this.liveClaudeId ? liveSlot() : folderSlot(this.claudeFolder(account.id)); }
  claudeAccounts() { return this.accounts.filter((account) => account.provider === 'claude'); }
  say(code, detail) { this.notice = { code, detail: detail ?? null, at: Date.now() }; this.emit('change'); }

  findClaude(identity) {
    const accounts = this.claudeAccounts();
    return accounts.find((account) => compareIdentity(account.identity, identity) === 'same')
      ?? accounts.find((account) => compareIdentity(account.identity, identity) === 'unverified'
        && account.identity?.email && account.identity.email.toLowerCase() === identity.email?.toLowerCase()) ?? null;
  }

  // MARK: Reading

  // Notes which account Claude Code is using now. One AgentBar has not seen before is added by itself.
  reconcileLive() {
    const slot = liveSlot();
    const identity = readIdentity(slot);
    if (!identity || !readCredentials(slot)) { this.liveClaudeId = null; return; }
    let account = this.findClaude(identity);
    if (!account) {
      account = { id: randomUUID(), provider: 'claude', identity, addedAt: Date.now() };
      this.accounts.push(account);
      this.save();
    } else if (JSON.stringify(account.identity) !== JSON.stringify(identity)) {
      account.identity = identity;
      this.save();
    }
    this.liveClaudeId = account.id;
  }

  async refreshOne(account, { force = false } = {}) {
    const memory = this.memoryOf(account.id);
    const read = account.provider === 'claude'
      ? loadClaude(this.slotOf(account), memory, { force })
      : loadCodex(this.codexFolder(account.id), account.identity ?? null, memory, { force });
    this.reading.set(account.id, read);
    let snapshot;
    try { snapshot = await read; } finally { if (this.reading.get(account.id) === read) this.reading.delete(account.id); }
    // An account removed while it was read is not brought back.
    if (!account.builtIn && !this.accounts.includes(account)) return;
    if (account.provider === 'codex' && snapshot.identity && !account.builtIn && !account.identity?.accountId) {
      account.identity = snapshot.identity;
      this.save();
    }
    this.snapshots.set(account.id, snapshot);
    this.keep(account.id);
    this.emit('change');
  }

  listed() {
    const codexDefault = findCLI('codex') && existsSync(path.join(defaultCodexHome(), 'auth.json'))
      ? [{ id: CODEX_DEFAULT, provider: 'codex', builtIn: true, identity: this.memoryOf(CODEX_DEFAULT).identity ?? null }] : [];
    return [...this.claudeAccounts(), ...codexDefault, ...this.accounts.filter((account) => account.provider === 'codex')];
  }

  refreshAll({ force = false } = {}) {
    if (this.refreshing) {
      // A forced read asked for while one is going on (after a switch or a sign-in) comes right after it.
      if (force) this.again ??= this.running.then(() => { this.again = null; return this.refreshAll({ force: true }); });
      return this.again ?? this.running;
    }
    this.running = this.#refresh(force).catch(() => {});
    return this.running;
  }

  async #refresh(force) {
    this.refreshing = true;
    this.emit('change');
    try {
      if (this.claudeVersion === undefined) this.claudeVersion = await installedVersion();
      // While Claude Code's account is being switched, its logins are not read (a read may renew one); the switch
      // reads them all when it ends.
      const switching = this.activity?.kind === 'switch';
      if (!switching) this.reconcileLive();
      const accounts = this.listed().filter((account) => !(switching && account.provider === 'claude'));
      await Promise.all(accounts.map((account) => this.refreshOne(account, { force }).catch(() => {})));
      this.lastRefresh = Date.now();
    } finally {
      this.refreshing = false;
      this.emit('change');
    }
  }

  // What the panel and the tray show.
  state() {
    const accounts = this.listed().map((account) => {
      const snapshot = this.snapshots.get(account.id) ?? {};
      const inUse = account.provider === 'claude' ? account.id === this.liveClaudeId : Boolean(account.builtIn);
      const hasLogin = account.provider === 'claude' ? (inUse || Boolean(readCredentials(folderSlot(this.claudeFolder(account.id)))?.refreshToken)) : true;
      const identity = account.identity ?? snapshot.identity ?? null;
      return {
        id: account.id, provider: account.provider, builtIn: Boolean(account.builtIn), email: identity?.email ?? null,
        organization: visibleOrganization(identity), inUse, hasLogin, canSwitch: account.provider === 'claude' && !inUse && hasLogin,
        updatedAt: snapshot.updatedAt ?? null, fiveHour: snapshot.fiveHour ?? null, weekly: snapshot.weekly ?? null,
        weeklyLabel: snapshot.weeklyLabel ?? null, models: snapshot.models ?? [], plan: snapshot.plan ?? null,
        error: hasLogin ? snapshot.error ?? null : 'missing-credentials', stale: Boolean(snapshot.stale),
        requiresLogin: !hasLogin || Boolean(snapshot.requiresLogin), coupons: snapshot.coupons ?? null, loaded: this.snapshots.has(account.id),
      };
    });
    return {
      version, now: Date.now(), interval: this.settings.interval, refreshing: this.refreshing, lastRefresh: this.lastRefresh ?? null,
      claudeInstalled: Boolean(findCLI('claude')), codexInstalled: Boolean(findCLI('codex')),
      claudeVersion: this.claudeVersion ? this.claudeVersion.join('.') : null,
      switchReady: Boolean(this.claudeVersion && versionAtLeast(this.claudeVersion, SWITCH_MINIMUM)),
      activity: this.activity ? { kind: this.activity.kind, provider: this.activity.provider, id: this.activity.id ?? null } : null,
      notice: this.notice, accounts,
    };
  }

  // MARK: Switching Claude Code to another account

  // Answers { outcome }: switched, already, needsLogin (the account has no login to hand over, or it was refused),
  // failed (nothing changed, it can be tried again), busy, tooOld.
  async switchClaude(id) {
    if (this.activity) return { outcome: 'busy' };
    const target = this.claudeAccounts().find((account) => account.id === id);
    if (!target) return { outcome: 'failed' };
    this.activity = { kind: 'switch', provider: 'claude', id };
    this.emit('change');
    try {
      const outcome = await this.#handOver(target);
      this.say(`switch-${outcome}`, target.identity?.email);
      return { outcome };
    } finally {
      this.activity = null;
      await this.refreshAll({ force: true });
    }
  }

  async #handOver(target) {
    forgetInstalledVersion();
    this.claudeVersion = await installedVersion();
    if (!this.claudeVersion || !versionAtLeast(this.claudeVersion, SWITCH_MINIMUM)) return 'tooOld';
    this.reconcileLive();
    if (this.liveClaudeId === target.id) return 'already';
    // A read going on may be renewing one of the two logins: the refresh token it holds is used up when it ends.
    await Promise.all([target.id, this.liveClaudeId].map((id) => this.reading.get(id)?.catch(() => {})));
    const targetSlot = folderSlot(this.claudeFolder(target.id));
    const saved = readCredentials(targetSlot);
    if (!saved?.refreshToken) return 'needsLogin';

    // The login Claude Code holds now goes to its own account's folder first, so it is never lost; if nothing
    // changes after all, that copy is removed again, because the login is still Claude Code's.
    const live = liveSlot();
    const before = readCredentials(live);
    const previous = this.claudeAccounts().find((account) => account.id === this.liveClaudeId) ?? null;
    const previousSlot = previous ? folderSlot(this.claudeFolder(previous.id)) : null;
    if (previousSlot && before?.refreshToken) writeAtomic(previousSlot.credentialsFile, before.raw);

    // The token only travels in the environment.
    const run = await runCLI('claude', ['auth', 'login', '--claudeai'], {
      env: liveEnvironment({ CLAUDE_CODE_OAUTH_REFRESH_TOKEN: saved.refreshToken, CLAUDE_CODE_OAUTH_SCOPES: saved.scopes.join(' ') }),
      timeout: 60_000,
    }).catch(() => ({ status: 127, text: '' }));

    const after = readCredentials(live);
    const nowIdentity = readIdentity(live);
    const moved = Boolean(after?.refreshToken) && after.refreshToken !== before?.refreshToken;
    if (run.status === 0 && moved && compareIdentity(nowIdentity, target.identity) !== 'different') {
      // The copy that stayed in the account's folder was used up.
      rmSync(targetSlot.credentialsFile, { force: true });
      this.liveClaudeId = target.id;
      return 'switched';
    }
    // Claude Code still holds the previous account's login: its copy must not stay beside it.
    if (previous && previousSlot && compareIdentity(nowIdentity, previous.identity) !== 'different' && after) rmSync(previousSlot.credentialsFile, { force: true });
    // A login the provider refused will never work again: the account signs in once more.
    if (isRefused(run.text) || moved) {
      rmSync(targetSlot.credentialsFile, { force: true });
      return 'needsLogin';
    }
    return 'failed';
  }

  // MARK: Adding and removing accounts

  cancelActivity() { this.activity?.control?.cancel?.(); }

  // Signs a Claude account in with the browser into a folder of its own. Claude Code's own login is not touched.
  // With `id`, the sign-in is for that account (one whose login is gone). Answers { outcome }: added, renewed,
  // cancelled, wrongAccount, failed, busy.
  async addClaude(id = null) {
    if (this.activity) return { outcome: 'busy' };
    const control = {};
    this.activity = { kind: 'add', provider: 'claude', id, control };
    this.emit('change');
    // The account Claude Code is using signs in again where Claude Code keeps its login; any other into a folder of its own.
    const intoLive = id !== null && id === this.liveClaudeId;
    const pending = path.join(this.root, 'claude', `pending-${randomUUID()}`);
    if (!intoLive) mkdirSync(pending, { recursive: true });
    const putBack = intoLive ? keepLogin(liveSlot()) : null;
    let outcome = 'failed';
    try {
      const run = await runCLI('claude', ['auth', 'login', '--claudeai'], {
        env: intoLive ? liveEnvironment() : cleanEnvironment({ CLAUDE_CONFIG_DIR: pending, CLAUDE_SECURESTORAGE_CONFIG_DIR: pending }), cwd: intoLive ? undefined : pending,
        // Claude Code opens the browser itself and waits for it; its input stays open as it expects.
        timeout: 300_000, control, keepInput: true,
      });
      const slot = folderSlot(pending);
      const identity = intoLive ? null : readIdentity(slot);
      if (run.cancelled) outcome = 'cancelled';
      else if (intoLive && run.status !== 0) outcome = 'failed';
      else if (intoLive) {
        // The browser may be signed in to another account: then Claude Code goes back to the login it had.
        const wanted = this.claudeAccounts().find((account) => account.id === id);
        if (compareIdentity(readIdentity(liveSlot()), wanted?.identity) === 'different') { putBack(); outcome = 'wrongAccount'; } else outcome = 'renewed';
      }
      else if (run.status === 0 && identity && readCredentials(slot)?.refreshToken) {
        const wanted = id ? this.claudeAccounts().find((account) => account.id === id) : null;
        let account = this.findClaude(identity);
        if (wanted && account !== wanted) outcome = 'wrongAccount';
        else {
          outcome = account ? 'renewed' : 'added';
          if (!account) { account = { id: randomUUID(), provider: 'claude', identity, addedAt: Date.now() }; this.accounts.push(account); }
          else account.identity = identity;
          const folder = this.claudeFolder(account.id);
          rmSync(folder, { recursive: true, force: true });
          renameSync(pending, folder);
          this.memory.set(account.id, {});
          this.save();
        }
      }
    } catch { outcome = 'failed'; } finally {
      rmSync(pending, { recursive: true, force: true });
      this.activity = null;
    }
    this.say(`add-${outcome}`);
    if (outcome === 'added' || outcome === 'renewed') await this.refreshAll({ force: true });
    return { outcome };
  }

  // Signs a Codex account in with the browser into a folder of its own.
  async addCodex(id = null) {
    if (this.activity) return { outcome: 'busy' };
    const control = {};
    this.activity = { kind: 'add', provider: 'codex', id, control };
    this.emit('change');
    const pending = path.join(this.root, 'codex', `pending-${randomUUID()}`);
    let outcome = 'failed';
    try {
      // Codex's own login signs in again where Codex keeps it.
      if (id === CODEX_DEFAULT) { await loginCodex(defaultCodexHome(), control); throw Object.assign(new Error('done'), { code: 'renewed-default' }); }
      mkdirSync(pending, { recursive: true });
      const identity = await loginCodex(pending, control);
      const wanted = id ? this.accounts.find((account) => account.id === id) : null;
      let account = this.accounts.find((item) => item.provider === 'codex' && sameCodexAccount(item.identity, identity) === true) ?? null;
      if (wanted && account !== wanted) outcome = 'wrongAccount';
      else if (!account && sameCodexAccount(this.memoryOf(CODEX_DEFAULT).identity, identity) === true) outcome = 'alreadyDefault';
      else {
        outcome = account ? 'renewed' : 'added';
        if (!account) { account = { id: randomUUID(), provider: 'codex', identity, addedAt: Date.now() }; this.accounts.push(account); }
        else account.identity = identity;
        const folder = this.codexFolder(account.id);
        rmSync(folder, { recursive: true, force: true });
        renameSync(pending, folder);
        this.memory.set(account.id, {});
        this.save();
      }
    } catch (error) { outcome = error.code === 'renewed-default' ? 'renewed' : error.code === 'cancelled' ? 'cancelled' : 'failed'; } finally {
      rmSync(pending, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
      this.activity = null;
    }
    this.say(`add-${outcome}`);
    if (outcome === 'added' || outcome === 'renewed') await this.refreshAll({ force: true });
    return { outcome };
  }

  // Forgets an account and its saved login. The account Claude Code is using and Codex's own stay.
  remove(id) {
    const account = this.accounts.find((item) => item.id === id);
    if (!account || id === this.liveClaudeId || this.activity) return false;
    this.accounts = this.accounts.filter((item) => item.id !== id);
    this.memory.delete(id);
    this.snapshots.delete(id);
    this.save();
    this.emit('change');
    // Its files go once a read of it has ended: on Windows the Codex app-server keeps its folder locked until then.
    const folder = account.provider === 'claude' ? this.claudeFolder(id) : this.codexFolder(id);
    const forget = () => {
      try {
        rmSync(folder, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
        rmSync(path.join(this.root, 'cache', `${id}.json`), { force: true });
      } catch {}
    };
    const reading = this.reading.get(id);
    if (reading) this.removed = reading.catch(() => {}).then(forget); else forget();
    return true;
  }

  // MARK: Coupons

  // Uses one coupon; only a person's confirmed press calls this.
  async useCoupon(id, claim) {
    if (this.activity) return { outcome: 'busy' };
    const account = this.listed().find((item) => item.id === id);
    const offered = this.snapshots.get(id)?.coupons?.options.find((item) => JSON.stringify(item.claim) === JSON.stringify(claim));
    if (!account || !offered?.redeemable) return { outcome: 'conditionsChanged' };
    this.activity = { kind: 'coupon', provider: account.provider, id };
    this.emit('change');
    let outcome = 'tryLater';
    try {
      outcome = account.provider === 'claude'
        ? await useClaudeCoupon(this.slotOf(account), account.identity, this.memoryOf(id), offered.claim)
        : await useCodexCoupon(this.codexFolder(id), account.identity ?? null, this.memoryOf(id), offered.claim);
    } finally { this.activity = null; }
    this.say(`coupon-${outcome}`);
    await this.refreshOne(account, { force: outcome === 'reset' });
    return { outcome };
  }

  setInterval(seconds) {
    this.settings.interval = Math.max(60, Math.round(seconds) || 120);
    this.save();
    this.emit('settings');
  }
}

// The organization worth showing beside the email. A personal one named after the email only repeats it.
function visibleOrganization(identity) {
  const organization = identity?.organization?.trim();
  if (!organization) return null;
  if (identity.email && organization.toLowerCase().includes(identity.email.toLowerCase())) return null;
  return organization;
}

// invalid_grant, or a 400 or 401 reply, means the saved login is dead. Anything else may pass next time.
export function isRefused(text) {
  return [/invalid_grant/, /(status( code)?|http|error|response)[ :=(]*(400|401)(?![0-9])/i, /http\/[0-9.]+ +(400|401)(?![0-9])/i,
    /(?<![0-9])(400|401)[ :)]+(bad request|unauthorized)/i].some((pattern) => pattern.test(text ?? ''));
}
