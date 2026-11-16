// Where AgentBar for Windows keeps its files. Both roots can be moved for a test, so a test never
// reaches the real Claude Code and Codex logins.
import { mkdirSync, renameSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export const userHome = process.env.AGENTBAR_USER_HOME || os.homedir();
export const dataRoot = process.env.AGENTBAR_HOME || path.join(userHome, '.agentbar', 'windows-v1');
export const appRoot = path.resolve(import.meta.dirname, '..');

// The whole file or nothing: a reader never sees half of it.
export function writeAtomic(file, text) {
  mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  writeFileSync(temporary, text);
  renameSync(temporary, file);
}

export function readJSON(file) {
  if (!existsSync(file)) return null;
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return null; }
}

export const version = (() => {
  try { return readFileSync(path.join(appRoot, 'VERSION'), 'utf8').trim(); } catch { return 'dev'; }
})();
