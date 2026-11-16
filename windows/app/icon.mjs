// The notification-area picture: two bars, the 5-hour and the weekly limit of the account Claude Code is using
// (Codex's when there is no Claude account). A bar turns red from 90%. Drawn by hand into BGRA pixels, so there is
// no image file and no drawing library.
const SIZE = 32;
const TRACK = [0x98, 0x8f, 0x8a], BLUE = [0xf6, 0x82, 0x3b], RED = [0x44, 0x44, 0xef]; // B, G, R

export function trayPixels(bars) {
  const pixels = Buffer.alloc(SIZE * SIZE * 4);
  const paint = (x, y, [b, g, r]) => { const at = (y * SIZE + x) * 4; pixels[at] = b; pixels[at + 1] = g; pixels[at + 2] = r; pixels[at + 3] = 255; };
  [[5, 13], [18, 26]].forEach(([top, bottom], index) => {
    const used = bars[index];
    const filled = used == null ? 0 : Math.max(used > 0 ? 2 : 0, Math.round((Math.min(used, 100) / 100) * 28));
    for (let y = top; y <= bottom; y++) {
      for (let x = 2; x <= 29; x++) {
        const corner = (x === 2 || x === 29) && (y === top || y === bottom);
        if (!corner) paint(x, y, x - 2 < filled ? (used >= 90 ? RED : BLUE) : TRACK);
      }
    }
  });
  return { pixels, size: SIZE };
}
