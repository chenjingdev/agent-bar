// The panel's layout against a stand-in drawing surface: what is shown and what can be pressed.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { drawPanel, span } from '../app/view.mjs';
import { EN, KO } from '../app/words.mjs';

function surface() {
  const drawn = { texts: [], hits: [], rects: [] };
  const ui = {
    width: 388,
    rect: (x, y, w, h, style) => { const shape = { x, y, w, h, ...style }; drawn.rects.push(shape); return shape; },
    text: (value) => { drawn.texts.push(String(value)); },
    measure: (value) => String(value).length * 6,
    paragraph: (value) => { drawn.texts.push(String(value)); return 16; },
    hit: (x, y, w, h, action) => { drawn.hits.push(action); return null; },
  };
  return { ui, drawn };
}
const account = (extra) => ({
  id: 'a', provider: 'claude', builtIn: false, email: 'work@example.com', organization: 'Example Inc', inUse: true, hasLogin: true, canSwitch: false,
  fiveHour: { used: 59, resetAt: 27 * 60_000 }, weekly: { used: 95, resetAt: 5 * 86400_000 }, weeklyLabel: null, models: [{ label: 'Fable', used: 1, resetAt: null }],
  plan: 'Team', error: null, stale: false, requiresLogin: false, coupons: null, loaded: true, ...extra,
});
const state = (accounts, extra = {}) => ({ now: 0, accounts, activity: null, notice: null, refreshing: false, lastRefresh: -25_000, claudeInstalled: true, codexInstalled: true, switchReady: true, ...extra });

test('an account shows who it is, its limits and when they reset', () => {
  const { ui, drawn } = surface();
  const height = drawPanel(ui, state([account()]), { asking: null }, { dark: false, T: EN });
  for (const words of ['work@example.com', 'Team', 'Example Inc', 'In use', '5h', '59%', 'Resets in 27m', 'Week', '95%', 'Resets in 5d 0h', 'Fable', '1%', 'Updated 25s ago', '1 account']) {
    assert.ok(drawn.texts.includes(words), `missing "${words}"`);
  }
  assert.ok(height > 150);
  assert.equal(drawn.rects[0].h, height, 'the background covers the whole panel');
  assert.ok(drawn.rects.some((shape) => shape.fill === 0xc42b1c), 'a limit over 90% is red');
});

test('another account can be switched to and removed; the one in use cannot', () => {
  const { ui, drawn } = surface();
  drawPanel(ui, state([account(), account({ id: 'b', email: 'me@example.com', inUse: false, canSwitch: true })]), { asking: null }, { dark: true, T: KO });
  assert.deepEqual(drawn.hits.filter((action) => action.id), [{ do: 'remove-ask', id: 'b' }, { do: 'switch', id: 'b' }]);
  assert.ok(drawn.texts.includes('쓰기') && drawn.texts.includes('사용 중') && drawn.texts.includes('계정 2개'));
});

test('nothing can be started while something is under way, except cancelling it', () => {
  const { ui, drawn } = surface();
  drawPanel(ui, state([account({ inUse: false, canSwitch: true })], { activity: { kind: 'add', provider: 'claude' } }), { asking: null }, { dark: false, T: EN });
  assert.ok(!drawn.hits.some((action) => action.do === 'switch' || action.do === 'add-menu'));
  assert.ok(drawn.hits.some((action) => action.do === 'cancel'));
});

test('a coupon is used only after a second, explicit yes', () => {
  const coupons = { totalCount: 3, options: [
    { scope: 'fiveHour', claim: { type: 'claude', grantId: 'g1' }, count: 2, expiries: [3 * 86400_000], redeemable: true, affectedUsagePercent: 100 },
    { scope: 'weekly', claim: { type: 'claude', grantId: 'g2' }, count: 1, expiries: [], redeemable: false, blockReason: 'limitRequired' }] };
  let { ui, drawn } = surface();
  drawPanel(ui, state([account({ coupons })]), { asking: null }, { dark: false, T: KO });
  assert.ok(drawn.texts.includes('초기화 쿠폰 3장') && drawn.texts.includes('5시간 한도 × 2') && drawn.texts.includes('· 한도에 닿으면 쓸 수 있음'));
  assert.deepEqual(drawn.hits.filter((action) => action.do.startsWith('coupon')), [{ do: 'coupon-ask', id: 'a', index: 0 }]);
  ({ ui, drawn } = surface());
  drawPanel(ui, state([account({ coupons })]), { asking: { kind: 'coupon', id: 'a', index: 0 } }, { dark: false, T: KO });
  assert.ok(drawn.texts.some((words) => words.includes('되돌릴 수 없습니다') && words.includes('100%')));
  assert.deepEqual(drawn.hits.filter((action) => action.do.startsWith('coupon') || action.do === 'ask-cancel'), [{ do: 'coupon-yes', id: 'a', index: 0 }, { do: 'ask-cancel' }]);
});

test('an account whose login is gone offers to sign in', () => {
  const { ui, drawn } = surface();
  drawPanel(ui, state([account({ inUse: false, hasLogin: false, requiresLogin: true, error: 'missing-credentials', fiveHour: null, weekly: null, models: [] })]), { asking: null }, { dark: false, T: EN });
  assert.ok(drawn.hits.some((action) => action.do === 'add' && action.id === 'a'));
  assert.ok(drawn.texts.includes('Sign-in required.'));
});

test('time spans', () => {
  assert.equal(span(40_000, EN), '40s');
  assert.equal(span(27 * 60_000, KO), '27분');
  assert.equal(span((5 * 24 + 6) * 3600_000, KO), '5일 6시간');
});
