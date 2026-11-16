// The Windows parts, called straight from Node through node:ffi: the notification-area icon and its menu, the
// panel window (drawn here with GDI and GDI+, no browser), "open at sign-in" and the light or dark theme. There is
// no program of AgentBar's own for Windows to judge: node.exe is the official signed one.
import process from 'node:process';

const ffi = process.getBuiltinModule('node:ffi');
const P = 'pointer', U = 'uint32', I = 'int32', F = 'float', W = 'uint64', L = 'int64';

const user32Library = ffi.dlopen('user32.dll', {
  SetProcessDpiAwarenessContext: { arguments: [P], return: I },
  GetDpiForSystem: { arguments: [], return: U },
  RegisterClassExW: { arguments: [P], return: 'uint16' },
  CreateWindowExW: { arguments: [U, P, P, U, I, I, I, I, P, P, P, P], return: P },
  DefWindowProcW: { arguments: [P, U, W, L], return: L },
  PeekMessageW: { arguments: [P, P, U, U, U], return: I },
  TranslateMessage: { arguments: [P], return: I },
  DispatchMessageW: { arguments: [P], return: L },
  RegisterWindowMessageW: { arguments: [P], return: U },
  PostMessageW: { arguments: [P, U, W, L], return: I },
  CreateIcon: { arguments: [P, I, I, 'uint8', 'uint8', P, P], return: P },
  DestroyIcon: { arguments: [P], return: I },
  CreatePopupMenu: { arguments: [], return: P },
  AppendMenuW: { arguments: [P, U, W, P], return: I },
  TrackPopupMenu: { arguments: [P, U, I, I, I, P, P], return: I },
  DestroyMenu: { arguments: [P], return: I },
  SetForegroundWindow: { arguments: [P], return: I },
  GetForegroundWindow: { arguments: [], return: P },
  GetCursorPos: { arguments: [P], return: I },
  IsWindowVisible: { arguments: [P], return: I },
  ShowWindow: { arguments: [P, I], return: I },
  SetWindowPos: { arguments: [P, P, I, I, I, I, U], return: I },
  SystemParametersInfoW: { arguments: [U, U, P, U], return: I },
  InvalidateRect: { arguments: [P, P, I], return: I },
  BeginPaint: { arguments: [P, P], return: P },
  EndPaint: { arguments: [P, P], return: I },
  GetDC: { arguments: [P], return: P },
  ReleaseDC: { arguments: [P, P], return: I },
  DrawTextW: { arguments: [P, P, I, P, U], return: I },
  LoadCursorW: { arguments: [P, P], return: P },
  SetCursor: { arguments: [P], return: P },
  TrackMouseEvent: { arguments: [P], return: I },
});
const user32 = user32Library.functions;
const gdi32 = ffi.dlopen('gdi32.dll', {
  CreateCompatibleDC: { arguments: [P], return: P },
  CreateCompatibleBitmap: { arguments: [P, I, I], return: P },
  SelectObject: { arguments: [P, P], return: P },
  DeleteObject: { arguments: [P], return: I },
  DeleteDC: { arguments: [P], return: I },
  BitBlt: { arguments: [P, I, I, I, I, P, I, I, U], return: I },
  CreateFontW: { arguments: [I, I, I, I, I, U, U, U, U, U, U, U, U, P], return: P },
  SetBkMode: { arguments: [P, I], return: I },
  SetTextColor: { arguments: [P, U], return: U },
}).functions;
const gdiplus = ffi.dlopen('gdiplus.dll', {
  GdiplusStartup: { arguments: [P, P, P], return: I },
  GdipCreateFromHDC: { arguments: [P, P], return: I },
  GdipDeleteGraphics: { arguments: [P], return: I },
  GdipSetSmoothingMode: { arguments: [P, I], return: I },
  GdipSetPixelOffsetMode: { arguments: [P, I], return: I },
  GdipCreateSolidFill: { arguments: [U, P], return: I },
  GdipDeleteBrush: { arguments: [P], return: I },
  GdipCreatePen1: { arguments: [U, F, I, P], return: I },
  GdipDeletePen: { arguments: [P], return: I },
  GdipCreatePath: { arguments: [I, P], return: I },
  GdipDeletePath: { arguments: [P], return: I },
  GdipAddPathArc: { arguments: [P, F, F, F, F, F, F], return: I },
  GdipAddPathRectangle: { arguments: [P, F, F, F, F], return: I },
  GdipClosePathFigure: { arguments: [P], return: I },
  GdipFillPath: { arguments: [P, P, P], return: I },
  GdipDrawPath: { arguments: [P, P, P], return: I },
}).functions;
const shell32 = ffi.dlopen('shell32.dll', { Shell_NotifyIconW: { arguments: [U, P], return: I } }).functions;
const dwmapi = ffi.dlopen('dwmapi.dll', { DwmSetWindowAttribute: { arguments: [P, U, P, U], return: I } }).functions;
const advapi32 = ffi.dlopen('advapi32.dll', {
  RegSetKeyValueW: { arguments: [P, P, P, U, P, U], return: I },
  RegDeleteKeyValueW: { arguments: [P, P, P], return: I },
  RegGetValueW: { arguments: [P, P, P, U, P, P, P], return: I },
}).functions;

const wide = (text) => Buffer.from(`${text}\0`, 'utf16le');
const address = (value) => (typeof value === 'bigint' ? value : BigInt(value ?? 0));
const signed16 = (value) => { const word = Number(value & 0xffffn); return word > 0x7fff ? word - 0x10000 : word; };
const kept = []; // callbacks and the buffers Windows holds on to must outlive the calls that hand them over

// Per-monitor DPI awareness, before any window: the panel is drawn at the screen's real resolution.
user32.SetProcessDpiAwarenessContext(0xFFFFFFFFFFFFFFFCn);
const startup = Buffer.alloc(24); startup.writeUInt32LE(1, 0);
const gdiplusToken = Buffer.alloc(8);
gdiplus.GdiplusStartup(gdiplusToken, startup, null);

function registerClass(name, procedure, style = 0) {
  const callback = user32Library.lib.registerCallback({ arguments: [P, U, W, L], return: L }, procedure);
  const className = wide(name);
  const windowClass = Buffer.alloc(80);
  windowClass.writeUInt32LE(80, 0);
  windowClass.writeUInt32LE(style, 4);
  windowClass.writeBigUInt64LE(address(callback), 8);
  windowClass.writeBigUInt64LE(address(user32.LoadCursorW(null, 32512n)), 40);
  windowClass.writeBigUInt64LE(ffi.getRawPointer(className), 64);
  kept.push(callback, className, windowClass);
  user32.RegisterClassExW(windowClass);
  return className;
}

// One loop for every window of this process, run from Node's own loop. Work a message asks for is done after the
// message has been answered, never inside Windows' call.
const later = [];
const message = Buffer.alloc(48);
let pump = null;
function startPump() {
  pump ??= setInterval(() => {
    while (user32.PeekMessageW(message, null, 0, 0, 1)) { user32.TranslateMessage(message); user32.DispatchMessageW(message); }
    // One piece of work that fails does not end AgentBar.
    for (const work of later.splice(0)) { try { work(); } catch (error) { console.error(error); } }
  }, 16);
}
export function stopPump() { clearInterval(pump); pump = null; }

// MARK: Menus

// items: { label, action, checked, disabled, items: [...] } or null for a line. Answers the chosen item's action.
function buildMenu(items, actions) {
  const menu = user32.CreatePopupMenu();
  for (const item of items) {
    if (item === null) user32.AppendMenuW(menu, 0x800, 0n, null);
    else if (item.items) user32.AppendMenuW(menu, 0x10, address(buildMenu(item.items, actions)), wide(item.label));
    else {
      actions.push(item.action);
      user32.AppendMenuW(menu, (item.disabled ? 0x1 : 0) | (item.checked ? 0x8 : 0), BigInt(actions.length), wide(item.label));
    }
  }
  return menu;
}

// Shows a menu at the pointer and runs what was chosen. `owner` must be a window of this process.
export function popupMenu(owner, items) {
  const actions = [];
  const menu = buildMenu(items, actions);
  const point = Buffer.alloc(8);
  user32.GetCursorPos(point);
  // The menu closes on a click elsewhere only if its window is in front.
  user32.SetForegroundWindow(owner);
  const chosen = user32.TrackPopupMenu(menu, 0x100 | 0x80 | 0x20, point.readInt32LE(0), point.readInt32LE(4), 0, owner, null);
  user32.PostMessageW(owner, 0, 0n, 0n);
  user32.DestroyMenu(menu);
  if (chosen > 0) setImmediate(() => actions[chosen - 1]?.());
}

// MARK: The notification-area icon

const WM_TRAY = 0x8001, NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2;

// `onClick` is a left click; `menu()` answers the items a right click shows.
export class Tray {
  #data = Buffer.alloc(976); #icon = 0n;

  constructor({ onClick, menu }) {
    const taskbarCreated = user32.RegisterWindowMessageW(wide('TaskbarCreated'));
    const className = registerClass('AgentBarTray', (window, code, wParam, lParam) => {
      if (code === WM_TRAY) {
        const event = Number(BigInt(lParam) & 0xffffn);
        if (event === 0x202) later.push(() => onClick?.());
        else if (event === 0x205 || event === 0x7b) later.push(() => popupMenu(this.window, menu?.() ?? []));
        return 0n;
      }
      // Explorer restarted: the icon is put back.
      if (code === taskbarCreated) { later.push(() => shell32.Shell_NotifyIconW(NIM_ADD, this.#data)); return 0n; }
      return user32.DefWindowProcW(window, code, wParam, lParam);
    });
    this.window = user32.CreateWindowExW(0, className, wide('AgentBar'), 0, 0, 0, 0, 0, null, null, null, null);
    this.#data.writeUInt32LE(976, 0);
    this.#data.writeBigUInt64LE(address(this.window), 8);
    this.#data.writeUInt32LE(1, 16);
    this.#data.writeUInt32LE(0x1 | 0x2 | 0x4, 20); // message, icon, tip
    this.#data.writeUInt32LE(WM_TRAY, 24);
    startPump();
  }

  // `pixels` is size×size BGRA, top row first.
  set({ pixels, size, tip }) {
    const mask = Buffer.alloc((size * size) / 8);
    for (let index = 0; index < size * size; index++) if (pixels[index * 4 + 3] === 0) mask[index >> 3] |= 0x80 >> (index & 7);
    const icon = user32.CreateIcon(null, size, size, 1, 32, mask, pixels);
    this.#data.writeBigUInt64LE(address(icon), 32);
    this.#data.fill(0, 40, 296);
    wide(tip.slice(0, 127)).copy(this.#data, 40);
    if (!shell32.Shell_NotifyIconW(this.#icon ? NIM_MODIFY : NIM_ADD, this.#data)) shell32.Shell_NotifyIconW(NIM_ADD, this.#data);
    if (this.#icon) user32.DestroyIcon(this.#icon);
    this.#icon = icon;
  }

  remove() { shell32.Shell_NotifyIconW(NIM_DELETE, this.#data); }
}

// MARK: The panel window

const colorref = (rgb) => ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
const DT_RIGHT = 0x2, DT_CENTER = 0x1, DT_VCENTER = 0x4, DT_SINGLELINE = 0x20, DT_WORDBREAK = 0x10, DT_NOPREFIX = 0x800, DT_END_ELLIPSIS = 0x8000, DT_CALCRECT = 0x400;

// A borderless window by the notification area that goes away when something else comes to the front. What is in
// it comes from `draw(ui)`, which is called with a small drawing surface in 96-dpi units and answers the height of
// what it drew; `onAction` hears the action of whatever was clicked.
export class Panel {
  #fonts = new Map(); #hits = []; #mouse = null; #pressed = null; #height = 100; #tracking = false;
  hiddenAt = 0; visible = false;

  constructor({ width, draw, onAction, background }) {
    this.width = width; this.draw = draw; this.onAction = onAction; this.background = background;
    this.scale = user32.GetDpiForSystem() / 96;
    const hand = user32.LoadCursorW(null, 32649n), arrow = user32.LoadCursorW(null, 32512n);
    const className = registerClass('AgentBarPanel', (window, code, wParam, lParam) => {
      switch (code) {
        case 0x0f: this.#paint(); return 0n; // WM_PAINT
        case 0x14: return 1n; // WM_ERASEBKGND: everything is painted
        case 0x200: { // WM_MOUSEMOVE
          const before = this.#hitAt(this.#mouse);
          this.#mouse = { x: signed16(BigInt(lParam)) / this.scale, y: signed16(BigInt(lParam) >> 16n) / this.scale };
          const now = this.#hitAt(this.#mouse);
          user32.SetCursor(now ? hand : arrow);
          if (before !== now) user32.InvalidateRect(this.window, null, 0);
          if (!this.#tracking) {
            const track = Buffer.alloc(24); track.writeUInt32LE(24, 0); track.writeUInt32LE(2, 4); track.writeBigUInt64LE(address(this.window), 8);
            user32.TrackMouseEvent(track); this.#tracking = true;
          }
          return 0n;
        }
        case 0x2a3: this.#tracking = false; this.#mouse = null; user32.InvalidateRect(this.window, null, 0); return 0n; // WM_MOUSELEAVE
        case 0x201: this.#pressed = this.#hitAt(this.#mouse); return 0n; // WM_LBUTTONDOWN
        case 0x202: { // WM_LBUTTONUP
          const hit = this.#hitAt(this.#mouse);
          if (hit && hit === this.#pressed) { const { action } = hit; later.push(() => this.onAction(action)); }
          this.#pressed = null;
          return 0n;
        }
        case 0x100: if (Number(wParam) === 0x1b) later.push(() => this.hide()); return 0n; // Esc
        case 0x06: // WM_ACTIVATE: like a menu, it goes away when something else comes to the front
          if ((Number(wParam) & 0xffff) === 0 && this.visible && !this.pinned) later.push(() => { if (this.visible && !this.pinned) { this.hide(); this.hiddenAt = Date.now(); } });
          return 0n;
        default: return user32.DefWindowProcW(window, code, wParam, lParam);
      }
    }, 0x20000 /* a shadow under it */);
    // A popup that stays off the taskbar and above other windows.
    this.window = user32.CreateWindowExW(0x80 | 0x8, className, wide('AgentBar'), 0x80000000, 0, 0, 10, 10, null, null, null, null);
    const round = Buffer.alloc(4); round.writeUInt32LE(2, 0);
    dwmapi.DwmSetWindowAttribute(this.window, 33, round, 4); // rounded corners on Windows 11
    startPump();
  }

  #hitAt(point) {
    if (!point) return null;
    for (let index = this.#hits.length - 1; index >= 0; index--) {
      const hit = this.#hits[index];
      if (point.x >= hit.x && point.x < hit.x + hit.w && point.y >= hit.y && point.y < hit.y + hit.h) return hit;
    }
    return null;
  }

  #font(size, bold) {
    const key = `${size}|${bold}`;
    if (!this.#fonts.has(key)) {
      this.#fonts.set(key, gdi32.CreateFontW(-Math.round(size * this.scale), 0, 0, 0, bold ? 600 : 400, 0, 0, 0, 1, 0, 0, 5, 0, wide('Segoe UI')));
    }
    return this.#fonts.get(key);
  }

  // Runs `draw` against a device context. With `paint` false nothing is drawn: it only measures.
  #run(dc, paint) {
    const s = this.scale, shapes = [], texts = [], hits = [];
    const rectOf = (x, y, w, h) => { const rect = Buffer.alloc(16); rect.writeInt32LE(Math.round(x * s), 0); rect.writeInt32LE(Math.round(y * s), 4); rect.writeInt32LE(Math.round((x + w) * s), 8); rect.writeInt32LE(Math.round((y + h) * s), 12); return rect; };
    const mouse = this.#mouse, pressed = this.#pressed;
    const ui = {
      width: this.width,
      // A filled, optionally outlined, rounded rectangle. What it answers can still be resized before the drawing ends.
      rect: (x, y, w, h, { fill, stroke, radius = 0 } = {}) => { const shape = { x, y, w, h, fill, stroke, radius }; shapes.push(shape); return shape; },
      // One line, cut with "…" when it does not fit. align: left, right or center.
      text: (value, x, y, w, h, { size = 13, bold = false, color = 0, align = 'left' } = {}) => {
        texts.push({ value: String(value), rect: rectOf(x, y, w, h), size, bold, color, flags: DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS | (align === 'right' ? DT_RIGHT : align === 'center' ? DT_CENTER : 0) });
      },
      // The width one line needs.
      measure: (value, { size = 13, bold = false } = {}) => {
        const rect = Buffer.alloc(16), buffer = wide(String(value));
        const old = gdi32.SelectObject(dc, this.#font(size, bold));
        user32.DrawTextW(dc, buffer, -1, rect, DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
        gdi32.SelectObject(dc, old);
        return Math.ceil(rect.readInt32LE(8) / s) + 1;
      },
      // Wrapped lines; answers the height they take.
      paragraph: (value, x, y, w, { size = 12, bold = false, color = 0 } = {}) => {
        const rect = rectOf(x, y, w, 0), buffer = wide(String(value));
        const old = gdi32.SelectObject(dc, this.#font(size, bold));
        user32.DrawTextW(dc, buffer, -1, rect, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
        gdi32.SelectObject(dc, old);
        const height = Math.ceil((rect.readInt32LE(12) - rect.readInt32LE(4)) / s);
        texts.push({ value: String(value), rect: rectOf(x, y, w, height + 2), size, bold, color, flags: DT_WORDBREAK | DT_NOPREFIX });
        return height;
      },
      // Makes a place clickable; answers 'pressed', 'hover' or null so the caller can draw it that way.
      hit: (x, y, w, h, action) => {
        hits.push({ x, y, w, h, action });
        const over = mouse && mouse.x >= x && mouse.x < x + w && mouse.y >= y && mouse.y < y + h;
        return over ? (pressed && JSON.stringify(pressed.action) === JSON.stringify(action) ? 'pressed' : 'hover') : null;
      },
    };
    const height = this.draw(ui);
    if (paint) {
      const graphics = Buffer.alloc(8);
      gdiplus.GdipCreateFromHDC(dc, graphics);
      const g = graphics.readBigUInt64LE(0);
      gdiplus.GdipSetSmoothingMode(g, 4);
      gdiplus.GdipSetPixelOffsetMode(g, 4);
      for (const shape of shapes) this.#shape(g, shape);
      gdiplus.GdipDeleteGraphics(g);
      gdi32.SetBkMode(dc, 1);
      for (const text of texts) {
        const old = gdi32.SelectObject(dc, this.#font(text.size, text.bold));
        gdi32.SetTextColor(dc, colorref(text.color));
        user32.DrawTextW(dc, wide(text.value), -1, text.rect, text.flags);
        gdi32.SelectObject(dc, old);
      }
      this.#hits = hits;
    }
    return height;
  }

  #shape(g, { x, y, w, h, fill, stroke, radius }) {
    const s = this.scale, holder = Buffer.alloc(8);
    gdiplus.GdipCreatePath(0, holder);
    const path = holder.readBigUInt64LE(0);
    const left = x * s, top = y * s, width = w * s, height = h * s, d = Math.min(radius * 2 * s, width, height);
    if (d <= 0) gdiplus.GdipAddPathRectangle(path, left, top, width, height);
    else {
      gdiplus.GdipAddPathArc(path, left, top, d, d, 180, 90);
      gdiplus.GdipAddPathArc(path, left + width - d, top, d, d, 270, 90);
      gdiplus.GdipAddPathArc(path, left + width - d, top + height - d, d, d, 0, 90);
      gdiplus.GdipAddPathArc(path, left, top + height - d, d, d, 90, 90);
      gdiplus.GdipClosePathFigure(path);
    }
    if (fill != null) {
      gdiplus.GdipCreateSolidFill((0xff000000 | fill) >>> 0, holder);
      const brush = holder.readBigUInt64LE(0);
      gdiplus.GdipFillPath(g, brush, path);
      gdiplus.GdipDeleteBrush(brush);
    }
    if (stroke != null) {
      gdiplus.GdipCreatePen1((0xff000000 | stroke) >>> 0, Math.max(1, Math.round(s)), 2, holder);
      const pen = holder.readBigUInt64LE(0);
      gdiplus.GdipDrawPath(g, pen, path);
      gdiplus.GdipDeletePen(pen);
    }
    gdiplus.GdipDeletePath(path);
  }

  #paint() {
    const paint = Buffer.alloc(72);
    const dc = user32.BeginPaint(this.window, paint);
    const width = Math.round(this.width * this.scale), height = Math.round(this.#height * this.scale);
    // Drawn off screen and copied in one go, so nothing flickers.
    const memory = gdi32.CreateCompatibleDC(dc), bitmap = gdi32.CreateCompatibleBitmap(dc, width, height);
    const old = gdi32.SelectObject(memory, bitmap);
    this.#run(memory, true);
    gdi32.BitBlt(dc, 0, 0, width, height, memory, 0, 0, 0x00cc0020);
    gdi32.SelectObject(memory, old);
    gdi32.DeleteObject(bitmap);
    gdi32.DeleteDC(memory);
    user32.EndPaint(this.window, paint);
  }

  // Fits the window to what `draw` needs now, in the corner by the notification area, and paints it again.
  refresh() {
    if (!this.visible) return;
    const dc = user32.GetDC(this.window);
    const wanted = this.#run(dc, false);
    user32.ReleaseDC(this.window, dc);
    const area = Buffer.alloc(16);
    user32.SystemParametersInfoW(0x30, 0, area, 0);
    const margin = Math.round(12 * this.scale);
    this.#height = Math.min(wanted, (area.readInt32LE(12) - area.readInt32LE(4) - 2 * margin) / this.scale);
    const width = Math.round(this.width * this.scale), height = Math.round(this.#height * this.scale);
    user32.SetWindowPos(this.window, null, area.readInt32LE(8) - width - margin, area.readInt32LE(12) - height - margin, width, height, 0x4 | 0x10);
    user32.InvalidateRect(this.window, null, 0);
  }

  show() {
    this.visible = true;
    this.refresh();
    user32.ShowWindow(this.window, 5);
    user32.SetForegroundWindow(this.window);
    // Windows does not always let a window come to the front (a start at sign-in, a second start). Such a panel
    // never hears that it lost the front, so it also goes away when the window in front changes to another.
    let front = user32.GetForegroundWindow();
    clearInterval(this.watch);
    this.watch = setInterval(() => {
      const now = user32.GetForegroundWindow();
      if (!this.visible || this.pinned || now === front) return;
      front = now;
      if (now !== this.window) { this.hide(); this.hiddenAt = Date.now(); }
    }, 150);
  }

  hide() {
    this.visible = false;
    clearInterval(this.watch);
    user32.ShowWindow(this.window, 0);
  }
}

// MARK: Open at sign-in (the user's Run key) and the theme

const HKCU = 0x80000001n, RUN_KEY = wide('Software\\Microsoft\\Windows\\CurrentVersion\\Run'), RUN_NAME = wide('AgentBar');

export function setAutostart(command) {
  if (command === null) { advapi32.RegDeleteKeyValueW(HKCU, RUN_KEY, RUN_NAME); return; }
  const data = wide(command);
  advapi32.RegSetKeyValueW(HKCU, RUN_KEY, RUN_NAME, 1, data, data.length);
}
export const hasAutostart = () => advapi32.RegGetValueW(HKCU, RUN_KEY, RUN_NAME, 0x2, null, null, null) === 0;

// Whether apps are set to the dark look (Settings › Personalization › Colors).
export function prefersDark() {
  const value = Buffer.alloc(4), size = Buffer.alloc(4); size.writeUInt32LE(4, 0);
  const found = advapi32.RegGetValueW(HKCU, wide('Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize'), wide('AppsUseLightTheme'), 0x10, null, value, size);
  return found === 0 && value.readUInt32LE(0) === 0;
}
