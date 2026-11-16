// Usage-reset coupons, as the Mac app reads them (Sources/agent-bar/Providers/ClaudeResetCoupons.swift and
// Core/UsageResetCoupons.swift). Claude's are "cedar_ember" grants in the usage answer; Codex's are
// `rateLimitResetCredits` in its rate-limit answer. One is used only when a person confirms.

const KINDS = ['session', 'weekly', 'fable', 'full'];

export function parseDate(text) {
  if (typeof text !== 'string') return null;
  const time = Date.parse(text);
  return Number.isNaN(time) ? null : time;
}

const text = (value) => (typeof value === 'string' ? value : undefined);
const flag = (value) => (typeof value === 'boolean' ? value : undefined);
const texts = (value) => (Array.isArray(value) && value.every((item) => typeof item === 'string') ? value : undefined);

function decodeGrant(raw) {
  if (!raw || typeof raw.id !== 'string' || !Number.isInteger(raw.resets_left)) return null;
  const clears = texts(raw.clears);
  const cleared = new Set(clears ?? []);
  const percentages = raw.percent_used && typeof raw.percent_used === 'object' ? Object.entries(raw.percent_used) : [];
  const affected = percentages
    .filter(([limit, percent]) => cleared.has(limit) && Number.isInteger(percent) && percent >= 0 && percent <= 100)
    .map(([, percent]) => percent);
  return {
    id: raw.id, resetsLeft: raw.resets_left, startsAt: text(raw.starts_at), endsAt: text(raw.ends_at), clears,
    paused: flag(raw.paused), type: text(raw.type), givesBackWeekly: flag(raw.gives_back_weekly),
    usableNow: 'usable_now' in raw ? raw.usable_now === true : undefined,
    useRequiresLimit: flag(raw.use_requires_limit), unavailableReason: text(raw.unavailable_reason),
    blocking: texts(raw.blocking), affectedUsagePercent: affected.length ? Math.max(...affected) : undefined,
  };
}

// The coupon part of a usage answer; null when it has none.
export function cedarBlock(answer) {
  const raw = answer?.cedar_ember;
  if (!raw || typeof raw !== 'object') return null;
  return {
    eligible: flag(raw.eligible), ineligibleReason: text(raw.ineligible_reason), atLimit: flag(raw.at_limit),
    exhausted: texts(raw.exhausted), grants: Array.isArray(raw.grants) ? raw.grants.map(decodeGrant).filter(Boolean) : undefined,
    nextGrantId: text(raw.next_grant_id), cooldownUntil: text(raw.cooldown_until),
  };
}

// As Claude Code names a grant: what it gives back, else its type, else what it clears.
function kindOf(grant) {
  if (grant.givesBackWeekly === true) return 'fable';
  if (['session', 'weekly', 'full'].includes(grant.type)) return grant.type;
  const clears = new Set(grant.clears ?? []);
  if (clears.size === 1 && clears.has('five_hour')) return 'session';
  if (!clears.has('five_hour') && clears.size > 0) return 'weekly';
  return 'full';
}

const clearsAny = (grant, limits) =>
  (grant.clears ?? []).some((limit) => limits.has(limit)) || (grant.givesBackWeekly === true && limits.has('seven_day'));

const coolingDown = (block, now) => { const until = parseDate(block.cooldownUntil); return until !== null && until > now; };

function needsLimit(grant, block) {
  const exhausted = new Set(block.exhausted ?? []);
  return grant.useRequiresLimit === true && (block.atLimit !== true || (exhausted.size > 0 && !clearsAny(grant, exhausted)));
}

function remaining(block, now) {
  if (block.eligible !== true) return [];
  const result = [];
  for (const grant of block.grants ?? []) {
    if (!/^[a-z0-9_-]{1,40}$/.test(grant.id) || grant.resetsLeft <= 0 || grant.paused === true) continue;
    const starts = parseDate(grant.startsAt);
    if (starts !== null && starts > now) continue;
    const ends = parseDate(grant.endsAt);
    if (ends !== null && ends <= now) continue;
    result.push({ grant, ends, kind: kindOf(grant) });
  }
  return result;
}

function offers(block, available, now) {
  if (coolingDown(block, now)) return [];
  // The current Claude Code offers the first usable grant of each kind in the server's order.
  const kindsSeen = new Set();
  const legacyNext = block.nextGrantId && (block.grants ?? []).some((grant) => grant.id === block.nextGrantId) ? block.nextGrantId : null;
  return available.filter(({ grant, kind }) => {
    if (grant.unavailableReason !== undefined) return false;
    if (grant.usableNow !== undefined) {
      if (!grant.usableNow) return false;
      const firstOfKind = !kindsSeen.has(kind);
      kindsSeen.add(kind);
      return firstOfKind || grant.id === block.nextGrantId;
    }
    // Older replies either specify the only next grant or leave the order to the client.
    if (legacyNext && grant.id !== legacyNext) return false;
    return !(grant.blocking?.length > 0) && !needsLimit(grant, block);
  });
}

function blockReason(grant, block, now) {
  if (coolingDown(block, now) || grant.unavailableReason === 'cooldown') return 'cooldown';
  if (kindOf(grant) === 'fable' && (grant.unavailableReason === 'blocked_seven_day'
    || (grant.unavailableReason === undefined && grant.blocking?.includes('seven_day')))) return 'noFableUsage';
  if (grant.unavailableReason === 'needs_limit' || (grant.unavailableReason === undefined && needsLimit(grant, block))) return 'limitRequired';
  return 'unavailable';
}

const soonestExpiring = (items) =>
  items.reduce((best, item) => (best === null || (item.ends ?? Infinity) < (best.ends ?? Infinity) ? item : best), null);

function option(selected, matching, target, block, hasFiveHour, now) {
  const scope = {
    session: 'fiveHour', weekly: 'weekly', full: 'fiveHourAndWeekly',
    fable: hasFiveHour === true || selected.grant.clears?.includes('five_hour') ? 'fiveHourAndFableWeekly' : 'fableWeekly',
  }[selected.kind];
  const expiries = matching.flatMap((item) => (item.ends === null ? [] : Array(item.grant.resetsLeft).fill(item.ends))).sort((a, b) => a - b);
  return {
    scope, claim: { type: 'claude', grantId: selected.grant.id },
    count: matching.reduce((sum, item) => sum + item.grant.resetsLeft, 0), expiries,
    redeemable: target !== null, blockReason: target === null ? blockReason(selected.grant, block, now) : undefined,
    affectedUsagePercent: target?.grant.affectedUsagePercent,
  };
}

// The account's coupons, one option per kind, remaining ones shown even when the server blocks using them now.
export function cedarCoupons(block, hasFiveHour, now = Date.now()) {
  const available = remaining(block, now);
  const redeemable = offers(block, available, now);
  const exhausted = new Set(block.exhausted ?? []);
  const clearing = block.atLimit === true ? redeemable.filter((item) => clearsAny(item.grant, exhausted)) : [];
  const preferred = redeemable.find((item) => item.grant.id === block.nextGrantId)
    ?? soonestExpiring(clearing.length ? clearing : redeemable);
  const selected = preferred ?? soonestExpiring(available);
  if (!selected) return null;
  const options = [];
  for (const kind of KINDS) {
    const matching = available.filter((item) => item.kind === kind);
    const actionable = redeemable.filter((item) => item.kind === kind);
    const target = actionable.find((item) => item.grant.id === block.nextGrantId)
      ?? (preferred?.kind === kind ? preferred : null) ?? soonestExpiring(actionable);
    const representative = target ?? soonestExpiring(matching);
    if (representative) options.push(option(representative, matching, target, block, hasFiveHour, now));
  }
  if (!options.some((item) => item.claim.grantId === selected.grant.id)) return null;
  return { totalCount: options.reduce((sum, item) => sum + item.count, 0), options };
}

// Recheck the exact grant the person confirmed against the server's current offers.
export function cedarCanRedeem(grantId, block, now = Date.now()) {
  return offers(block, remaining(block, now), now).some((item) => item.grant.id === grantId);
}

// The answer to a claim: how it ended, and whether it may have gone through without saying so.
export function cedarOutcome(answer) {
  switch (answer?.result) {
    case 'reset': return { outcome: 'reset', unconfirmed: false };
    case 'not_limited': return { outcome: 'nothingToReset', unconfirmed: false };
    case 'already_used': case 'ineligible': return { outcome: 'noCoupon', unconfirmed: false };
    case 'cooldown': return { outcome: 'tryLater', unconfirmed: false };
    default: return { outcome: 'tryLater', unconfirmed: true };
  }
}

// Remembered coupons less any whose last day has passed. One that lost a coupon waits for the next answer before it can be used.
export function pruneExpired(coupons, now = Date.now()) {
  if (!coupons) return null;
  const options = [];
  for (const item of coupons.options) {
    const expired = item.expiries.filter((time) => time <= now).length;
    if (item.count - expired <= 0) continue;
    options.push(expired === 0 ? item : {
      ...item, count: item.count - expired, expiries: item.expiries.filter((time) => time > now),
      redeemable: false, blockReason: 'unavailable', affectedUsagePercent: undefined,
    });
  }
  return options.length ? { totalCount: options.reduce((sum, item) => sum + item.count, 0), options } : null;
}

// Codex's coupons, from the rate-limit answer it already gives. Null when the account has none.
export function codexCoupons(result, now = Date.now()) {
  const summary = result?.rateLimitResetCredits;
  const count = summary?.availableCount ?? 0;
  if (!summary || count <= 0) return null;
  // Only coupons that can still be used; the list may be cut short, so the count comes from `availableCount`.
  const available = (summary.credits ?? []).filter((credit) => credit.status === 'available')
    .map((credit) => ({ id: credit.id, expires: Number.isFinite(credit.expiresAt) ? credit.expiresAt * 1000 : null }))
    .filter((credit) => credit.expires === null || credit.expires > now);
  const first = available.reduce((best, credit) => (best === null || (credit.expires ?? Infinity) < (best.expires ?? Infinity) ? credit : best), null);
  return {
    totalCount: count,
    options: [{
      scope: 'fiveHourAndWeekly', claim: { type: 'codex', creditId: first?.id ?? null }, count,
      expiries: available.map((credit) => credit.expires).filter((time) => time !== null).sort((a, b) => a - b), redeemable: true,
    }],
  };
}

// The answer to `account/rateLimitResetCredit/consume`.
export function codexOutcome(result) {
  switch (result?.outcome) {
    case 'reset': case 'alreadyRedeemed': return 'reset';
    case 'nothingToReset': return 'nothingToReset';
    case 'noCredit': return 'noCoupon';
    default: return 'tryLater';
  }
}
