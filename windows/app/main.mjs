// AgentBar for Windows. One Node process: it reads the accounts, keeps the notification-area icon and draws the
// panel that opens by it.
import { rmSync } from 'node:fs';
import path from 'node:path';
import { trayPixels } from './icon.mjs';
import { dataRoot, readJSON, version, writeAtomic } from './paths.mjs';
import { startServer } from './server.mjs';
import { Store } from './store.mjs';
import { drawPanel, PANEL_WIDTH } from './view.mjs';
import { EN, KO } from './words.mjs';

const T = Intl.DateTimeFormat().resolvedOptions().locale.startsWith('ko') ? KO : EN;
const runFile = path.join(dataRoot, 'run.json');
const ask = (run, name) => fetch(`http://127.0.0.1:${run.port}/api/${name}`, {
  method: 'POST', headers: { 'x-agentbar-token': run.token, 'content-type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(3000),
});

// Only one AgentBar runs. A second start asks the first to show its panel, or with --quit to end, and ends.
const running = readJSON(runFile);
const wantsQuit = process.argv.includes('--quit');
if (running) {
  try { if ((await ask(running, wantsQuit ? 'quit' : 'show')).ok) process.exit(0); } catch {}
}
if (wantsQuit) process.exit(0);
if (process.platform !== 'win32') { console.error('AgentBar for Windows runs on Windows. On a Mac, use the Mac app.'); process.exit(1); }

const win = await import('./win32.mjs');
const store = new Store();
const local = { asking: null }; // what only the panel knows: the question it is asking

// The line that starts AgentBar without a console window: conhost runs node with a hidden one.
const startCommand = `conhost.exe --headless "${process.execPath}" --disable-warning=ExperimentalWarning "${path.join(import.meta.dirname, 'main.mjs')}"`;

// MARK: The panel

const panel = new win.Panel({
  width: PANEL_WIDTH,
  draw: (ui) => drawPanel(ui, { ...store.state(), now: Date.now() }, local, { dark: process.env.AGENTBAR_THEME ? process.env.AGENTBAR_THEME === 'dark' : win.prefersDark(), T }),
  onAction: act,
});
panel.pinned = Boolean(process.env.AGENTBAR_KEEP_OPEN);

function showPanel() {
  panel.show();
  if (Date.now() - (store.lastRefresh ?? 0) > 60_000) store.refreshAll();
}
function togglePanel() {
  if (panel.visible) { panel.hide(); return; }
  // The click that closed the panel by taking the front from it is not also a click to open it.
  if (Date.now() - panel.hiddenAt < 400) return;
  showPanel();
}

// A menu opened from the panel must not close it.
function menuFromPanel(items) {
  const pinned = panel.pinned;
  panel.pinned = true;
  win.popupMenu(panel.window, items);
  setTimeout(() => { panel.pinned = pinned; }, 300);
}

const settingsItems = () => [
  { label: T.interval, items: [1, 2, 5, 10].map((minutes) => ({ label: T.minutes(minutes), checked: store.settings.interval === minutes * 60, action: () => store.setInterval(minutes * 60) })) },
  { label: T.autostart, checked: win.hasAutostart(), action: () => win.setAutostart(win.hasAutostart() ? null : startCommand) },
  null,
  { label: T.about(version, store.claudeVersion?.join('.')), disabled: true },
];

// What a click in the panel does.
function act(action) {
  const state = store.state();
  switch (action.do) {
    case 'refresh': store.refreshAll({ force: true }); break;
    case 'settings': menuFromPanel(settingsItems()); break;
    case 'add-menu': menuFromPanel([
      { label: T.addClaude, disabled: !state.claudeInstalled, action: () => store.addClaude() },
      { label: T.addCodex, disabled: !state.codexInstalled, action: () => store.addCodex() },
    ]); break;
    case 'add': if (action.provider === 'codex') store.addCodex(action.id ?? null); else store.addClaude(action.id ?? null); break;
    case 'switch': store.switchClaude(action.id); break;
    case 'cancel': store.cancelActivity(); break;
    case 'dismiss': store.notice = null; break;
    case 'coupon-ask': local.asking = { kind: 'coupon', id: action.id, index: action.index }; break;
    case 'remove-ask': local.asking = { kind: 'remove', id: action.id }; break;
    case 'ask-cancel': local.asking = null; break;
    case 'remove-yes': local.asking = null; store.remove(action.id); break;
    case 'coupon-yes': {
      const claim = state.accounts.find((item) => item.id === action.id)?.coupons?.options[action.index]?.claim;
      local.asking = null;
      if (claim) store.useCoupon(action.id, claim);
      break;
    }
    case 'quit': quit(); return;
  }
  panel.refresh();
}

function quit() {
  tray.remove();
  panel.hide();
  rmSync(runFile, { force: true });
  setTimeout(() => process.exit(0), 100);
}

// MARK: The notification-area icon

const percent = (window) => (window?.used == null ? '–' : `${window.used}%`);
function trayLook() {
  const { accounts } = store.state();
  const inUse = accounts.filter((item) => item.inUse);
  const windows = (item) => [[T.fiveHour, item.fiveHour], [T.week, item.weekly]].filter(([, window]) => window);
  const lines = inUse.map((item) => `${item.provider === 'claude' ? 'Claude' : 'Codex'} ${windows(item).map(([name, window]) => `${name} ${percent(window)}`).join(' · ') || '–'}`);
  // The bars are the account Claude Code is using; Codex's own when Claude has nothing to show.
  const shown = inUse.find((item) => item.provider === 'claude' && windows(item).length) ?? inUse.find((item) => windows(item).length);
  return { ...trayPixels([shown?.fiveHour?.used ?? null, shown?.weekly?.used ?? null]), tip: ['AgentBar', ...lines].join('\n') };
}

// A right click: open, refresh, the Claude accounts to switch between, settings, quit.
function trayMenu() {
  const state = store.state();
  const claude = state.accounts.filter((item) => item.provider === 'claude');
  return [
    { label: T.open, action: showPanel },
    { label: T.refresh, action: () => store.refreshAll({ force: true }) },
    null,
    ...claude.map((item) => ({
      label: `${item.email ?? 'Claude'}${item.inUse ? `  (${T.trayInUse})` : ''}`, checked: item.inUse,
      disabled: !item.inUse && (!item.canSwitch || !state.switchReady || Boolean(state.activity)),
      action: () => { if (!item.inUse) store.switchClaude(item.id); },
    })),
    ...(claude.length ? [null] : []),
    { label: T.settings, items: settingsItems() },
    { label: T.quit, action: quit },
  ];
}

const tray = new win.Tray({ onClick: togglePanel, menu: trayMenu });
let lastLook = '';
function drawTray() {
  const look = trayLook();
  const signature = look.tip + look.pixels.toString('base64');
  if (signature !== lastLook) { lastLook = signature; tray.set(look); }
}
store.on('change', () => { drawTray(); panel.refresh(); });
drawTray();
// "Resets in 27m" and "Updated 40s ago" move on while the panel is open.
setInterval(() => panel.refresh(), 20_000);

// MARK: The door for a second start and for tests

const server = await startServer({
  show: () => { showPanel(); },
  quit: () => { setTimeout(quit, 50); },
  state: () => store.state(),
  ...(process.env.AGENTBAR_TEST ? {
    act: (action) => { act(action); },
    hide: () => { panel.hide(); },
    pin: ({ pinned }) => { panel.pinned = pinned; },
  } : {}),
});
writeAtomic(runFile, JSON.stringify({ port: server.port, token: server.token, pid: process.pid }));

// MARK: Reading on a schedule

let timer;
function schedule() {
  clearInterval(timer);
  timer = setInterval(() => store.refreshAll(), store.settings.interval * 1000);
}
store.on('settings', schedule);
schedule();
store.refreshAll();
if (process.argv.includes('--show')) showPanel();
console.log(`AgentBar ${version} for Windows: pid ${process.pid}`);
