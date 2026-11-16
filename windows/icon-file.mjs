// Writes the Start menu icon (.ico) from the same picture the notification area shows: `node icon-file.mjs <file>`.
import { writeFileSync } from 'node:fs';
import { trayPixels } from './app/icon.mjs';

const { pixels, size } = trayPixels([45, 70]);
const header = Buffer.alloc(6 + 16 + 40);
header.writeUInt16LE(1, 2); header.writeUInt16LE(1, 4);           // an icon, one picture
header.writeUInt8(size, 6); header.writeUInt8(size, 7);
header.writeUInt16LE(1, 10); header.writeUInt16LE(32, 12);
const mask = Buffer.alloc(size * 4);                              // all drawn; the alpha decides
header.writeUInt32LE(40 + pixels.length + mask.length, 14); header.writeUInt32LE(22, 18);
header.writeUInt32LE(40, 22); header.writeInt32LE(size, 26); header.writeInt32LE(size * 2, 30);
header.writeUInt16LE(1, 34); header.writeUInt16LE(32, 36);
// Rows go bottom to top in the file.
const rows = [];
for (let y = size - 1; y >= 0; y--) rows.push(pixels.subarray(y * size * 4, (y + 1) * size * 4));
writeFileSync(process.argv[2], Buffer.concat([header, ...rows, mask]));
