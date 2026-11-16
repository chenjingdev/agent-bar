// What is in the panel: the accounts with their limits, coupons and buttons. It draws through a small surface
// (rect, text, measure, paragraph, hit) in 96-dpi units, so the same code is tried on any computer with a
// stand-in surface; the Windows window gives the real one.
const LIGHT = {
  bg: 0xf3f3f3, card: 0xffffff, text: 0x1b1b1b, muted: 0x6b6b6b, line: 0xe2e2e2, track: 0xd9d9d9, accent: 0x0067c0, accentHover: 0x1975c5,
  accentSoft: 0xdbeafe, danger: 0xc42b1c, chip: 0xececec, chipHover: 0xdfdfdf, warnBg: 0xfff4ce, warnText: 0x5c4400, onAccent: 0xffffff,
};
const DARK = {
  bg: 0x202020, card: 0x2b2b2b, text: 0xf2f2f2, muted: 0xa6a6a6, line: 0x3a3a3a, track: 0x474747, accent: 0x4cc2ff, accentHover: 0x62cdff,
  accentSoft: 0x123a56, danger: 0xff99a4, chip: 0x3a3a3a, chipHover: 0x484848, warnBg: 0x433519, warnText: 0xffe9a8, onAccent: 0x00233a,
};
const PAD = 14;
export const PANEL_WIDTH = 388;

// "5d 6h", "27m", "40s": how long, in two parts at most.
export function span(milliseconds, T) {
  const seconds = Math.max(0, Math.round(milliseconds / 1000));
  if (seconds < 60) return `${seconds}${T.s}`;
  const minutes = Math.floor(seconds / 60), hours = Math.floor(minutes / 60), days = Math.floor(hours / 24);
  if (days > 0) return `${days}${T.d} ${hours % 24}${T.h}`;
  if (hours > 0) return `${hours}${T.h} ${minutes % 60}${T.m}`;
  return `${minutes}${T.m}`;
}

// A button that is only words until the pointer is on it. Drawn ending at `right`; answers the width it took.
function link(ui, c, label, right, y, action, { disabled = false } = {}) {
  const width = ui.measure(label, { size: 13 }) + 16;
  const state = disabled ? null : ui.hit(right - width, y, width, 26, action);
  if (state) ui.rect(right - width, y, width, 26, { fill: state === 'pressed' ? c.chipHover : c.chip, radius: 5 });
  ui.text(label, right - width, y, width, 26, { size: 13, color: disabled ? c.muted : c.text, align: 'center' });
  return width + 2;
}

// A filled button. kind: 'primary' or 'quiet'.
function pill(ui, c, label, right, y, action, { kind = 'primary', disabled = false } = {}) {
  const width = ui.measure(label, { size: 12, bold: true }) + 24;
  const state = disabled ? null : ui.hit(right - width, y, width, 24, action);
  const fill = disabled ? c.track : kind === 'primary' ? (state ? c.accentHover : c.accent) : (state ? c.chipHover : c.chip);
  ui.rect(right - width, y, width, 24, { fill, radius: 5 });
  ui.text(label, right - width, y, width, 24, { size: 12, bold: true, color: disabled ? c.muted : kind === 'primary' ? c.onAccent : c.text, align: 'center' });
  return width + 6;
}

// A question in a box, with No and Yes under it. Answers the height it took.
function confirm(ui, c, x, y, w, question, yes, yesAction, T) {
  const box = ui.rect(x, y, w, 0, { fill: c.warnBg, radius: 7 });
  let bottom = y + 8 + ui.paragraph(question, x + 10, y + 8, w - 20, { color: c.warnText }) + 8;
  let right = x + w - 4;
  right -= pill(ui, c, yes, right, bottom, yesAction);
  pill(ui, c, T.cancel, right, bottom, { do: 'ask-cancel' }, { kind: 'quiet' });
  bottom += 24 + 8;
  box.h = bottom - y;
  return box.h;
}

function limit(ui, c, T, now, x, y, w, name, window) {
  ui.text(name, x, y, w - 40, 16, { size: 12, color: c.muted });
  ui.text(window.used == null ? '–' : `${window.used}%`, x + w - 44, y, 44, 16, { size: 12, bold: true, color: c.text, align: 'right' });
  ui.rect(x, y + 20, w, 5, { fill: c.track, radius: 2.5 });
  if (window.used > 0) ui.rect(x, y + 20, Math.max(5, (w * Math.min(window.used, 100)) / 100), 5, { fill: window.used >= 90 ? c.danger : c.accent, radius: 2.5 });
  if (window.resetAt && window.resetAt > now) {
    // The long wording when it fits the column, else the short one.
    const left = span(window.resetAt - now, T), long = T.resetsIn(left);
    ui.text(ui.measure(long, { size: 11 }) <= w ? long : T.left(left), x, y + 28, w, 14, { size: 11, color: c.muted });
  }
}

function account(ui, c, T, state, local, item, top) {
  const x = PAD, w = ui.width - 2 * PAD, inner = x + 12, innerWidth = w - 24, busy = Boolean(state.activity);
  const card = ui.rect(x, top, w, 0, { fill: c.card, stroke: c.line, radius: 8 });
  let y = top + 10;
  const who = item.email ?? (item.provider === 'claude' ? 'Claude' : 'Codex');

  // The mark, who it is, and what can be done with it.
  ui.rect(inner, y, 24, 24, { fill: item.provider === 'claude' ? 0xd97757 : 0x10a37f, radius: 6 });
  ui.text(item.provider === 'claude' ? 'Cl' : 'Cx', inner, y, 24, 24, { size: 11, bold: true, color: 0xffffff, align: 'center' });
  let right = x + w - 12;
  if (!item.inUse && !item.builtIn) {
    const state_ = ui.hit(right - 20, y + 2, 20, 20, { do: 'remove-ask', id: item.id });
    if (state_) ui.rect(right - 20, y + 2, 20, 20, { fill: c.chip, radius: 4 });
    ui.text('✕', right - 20, y + 2, 20, 20, { size: 11, color: state_ ? c.danger : c.muted, align: 'center' });
    right -= 26;
  }
  if (item.provider === 'claude' ? item.inUse : item.builtIn) {
    const label = item.provider === 'claude' ? T.inUse : T.codexOwn;
    const width = ui.measure(label, { size: 12, bold: true }) + 18;
    ui.rect(right - width, y + 2, width, 20, { fill: c.accentSoft, radius: 10 });
    ui.text(label, right - width, y + 2, width, 20, { size: 12, bold: true, color: c.accent, align: 'center' });
    right -= width + 8;
  } else if (item.canSwitch) right -= pill(ui, c, T.use, right, y, { do: 'switch', id: item.id }, { disabled: busy || !state.switchReady }) + 2;
  let left = inner + 32;
  const chipWidth = item.plan ? ui.measure(item.plan, { size: 11, bold: true }) + 14 : 0;
  const nameWidth = Math.min(ui.measure(who, { size: 13, bold: true }), right - left - (chipWidth ? chipWidth + 6 : 0));
  ui.text(who, left, y, nameWidth, 24, { size: 13, bold: true, color: c.text });
  left += nameWidth + 6;
  if (item.plan) {
    ui.rect(left, y + 3, chipWidth, 18, { fill: c.chip, radius: 9 });
    ui.text(item.plan, left, y + 3, chipWidth, 18, { size: 11, bold: true, color: c.text, align: 'center' });
    left += chipWidth + 6;
  }
  if (item.organization && right - left > 40) ui.text(item.organization, left, y, right - left, 24, { size: 12, color: c.muted });
  y += 32;

  // The limits, three to a row.
  const windows = [[T.fiveHour, item.fiveHour], [item.weeklyLabel ?? T.week, item.weekly], ...item.models.map((model) => [model.label, model])].filter(([, window]) => window);
  const column = (innerWidth - 24) / 3;
  windows.forEach(([name, window], index) => limit(ui, c, T, state.now, inner + (index % 3) * (column + 12), y + Math.floor(index / 3) * 48, column, name, window));
  y += Math.ceil(windows.length / 3) * 48;

  // What is wrong, and the way out when there is one.
  if (item.requiresLogin) {
    const words = item.inUse && item.provider === 'claude' ? T.liveSignIn : T.errors[item.error] ?? T.errors.login;
    const buttonWidth = pill(ui, c, T.signIn, x + w - 12, y, { do: 'add', provider: item.provider, id: item.id }, { disabled: busy });
    y += Math.max(24, ui.paragraph(words, inner, y + 3, innerWidth - buttonWidth - 6, { color: c.danger })) + 8;
  } else if (item.error) {
    y += ui.paragraph(T.errors[item.error] ?? T.errors.other, inner, y, innerWidth, { color: item.error === 'rate-limited' ? c.muted : c.danger }) + 8;
  } else if (!item.loaded) {
    y += ui.paragraph(T.reading, inner, y, innerWidth, { color: c.muted }) + 8;
  }

  // Coupons: one row for each kind, with a button for one that can be used now.
  if (item.coupons) {
    ui.rect(inner, y, innerWidth, 1, { fill: c.line });
    y += 7;
    ui.text(T.coupon(item.coupons.totalCount), inner, y, innerWidth, 18, { size: 12, bold: true, color: c.text });
    y += 22;
    item.coupons.options.forEach((option, index) => {
      if (local.asking?.kind === 'coupon' && local.asking.id === item.id && local.asking.index === index) {
        y += confirm(ui, c, inner, y, innerWidth, T.couponAsk(T.scopes[option.scope], option.affectedUsagePercent), T.couponYes, { do: 'coupon-yes', id: item.id, index }, T) + 6;
        return;
      }
      const detail = option.redeemable ? (option.expiries[0] ? T.expires(span(option.expiries[0] - state.now, T)) : '') : T.blocks[option.blockReason] ?? T.blocks.unavailable;
      const buttonWidth = option.redeemable ? pill(ui, c, T.useCoupon, x + w - 12, y, { do: 'coupon-ask', id: item.id, index }, { kind: 'quiet', disabled: busy }) : 0;
      const label = `${T.scopes[option.scope]} × ${option.count}`;
      const labelWidth = Math.min(ui.measure(label, { size: 12 }), innerWidth - buttonWidth);
      ui.text(label, inner, y, labelWidth, 24, { size: 12, color: c.text });
      if (detail) ui.text(`· ${detail}`, inner + labelWidth + 4, y, innerWidth - buttonWidth - labelWidth - 8, 24, { size: 12, color: c.muted });
      y += 28;
    });
  }
  if (local.asking?.kind === 'remove' && local.asking.id === item.id) {
    y += confirm(ui, c, inner, y, innerWidth, T.removeAsk(who), T.removeYes, { do: 'remove-yes', id: item.id }, T) + 8;
  }
  card.h = y + 2 - top;
  return top + card.h;
}

// Draws the whole panel and answers its height. `local` is what only the panel knows: { asking }.
export function drawPanel(ui, state, local, { dark, T }) {
  const c = dark ? DARK : LIGHT, width = ui.width;
  const background = ui.rect(0, 0, width, 0, { fill: c.bg });
  ui.text('AgentBar', PAD, 10, 120, 26, { size: 16, bold: true, color: c.text });
  ui.text(T.accounts(state.accounts.length), PAD + ui.measure('AgentBar', { size: 16, bold: true }) + 6, 12, 120, 24, { size: 12, color: c.muted });
  let right = width - PAD + 6;
  right -= link(ui, c, T.settings, right, 10, { do: 'settings' });
  link(ui, c, state.refreshing ? T.reading : T.refresh, right, 10, { do: 'refresh' }, { disabled: state.refreshing });
  let y = 46;

  // What is going on, or how the last thing ended.
  const activity = state.activity;
  const notice = !activity && state.notice && T.notices[state.notice.code] ? T.notices[state.notice.code](state.notice.detail) : null;
  if (activity || notice) {
    const words = activity ? T.working[activity.kind] : notice;
    const box = ui.rect(PAD, y, width - 2 * PAD, 0, { fill: c.warnBg, radius: 7 });
    let bottom = y + 8 + ui.paragraph(words, PAD + 10, y + 8, width - 2 * PAD - 20, { color: c.warnText }) + 6;
    if (!activity || activity.kind === 'add') {
      const edge = width - PAD - 4;
      pill(ui, c, activity ? T.cancel : T.close, edge, bottom, { do: activity ? 'cancel' : 'dismiss' }, { kind: 'quiet' });
      bottom += 24 + 4;
    }
    box.h = bottom + 4 - y;
    y += box.h + 8;
  }
  if (state.claudeInstalled && !state.switchReady && state.accounts.some((item) => item.canSwitch)) {
    y += ui.paragraph(T.tooOld, PAD + 2, y, width - 2 * PAD - 4, { color: c.muted }) + 8;
  }

  if (state.accounts.length === 0) {
    const missing = [state.claudeInstalled ? '' : T.noClaude, state.codexInstalled ? '' : T.noCodex].filter(Boolean).join(' ');
    y += 22 + ui.paragraph(missing ? `${T.empty}\n\n${missing}` : T.empty, PAD + 14, y + 22, width - 2 * PAD - 28, { size: 13, color: c.muted }) + 26;
  }
  for (const item of state.accounts) y = account(ui, c, T, state, local, item, y) + 8;

  ui.rect(0, y + 2, width, 1, { fill: c.line });
  y += 9;
  ui.text(state.lastRefresh ? T.updated(span(state.now - state.lastRefresh, T)) : T.never, PAD, y, 150, 26, { size: 12, color: c.muted });
  right = width - PAD + 6;
  right -= link(ui, c, T.quit, right, y, { do: 'quit' });
  link(ui, c, T.add, right, y, { do: 'add-menu' }, { disabled: Boolean(activity) });
  y += 26 + 8;
  background.h = y;
  return y;
}
