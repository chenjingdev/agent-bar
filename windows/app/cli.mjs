// Finds and runs the two command-line programs AgentBar asks: Claude Code (`claude`) and Codex (`codex`).
// On Windows an npm-installed one is a `.cmd` file, which Node will not start without a shell; the script
// that file starts is read out of it and run with Node directly, so no argument ever passes through cmd.exe.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { userHome } from './paths.mjs';

const found = new Map();

function searchDirectories() {
  const fromPath = (process.env.PATH || process.env.Path || '').split(path.delimiter).filter(Boolean);
  const extra = [path.join(userHome, '.local', 'bin')];
  if (process.env.APPDATA) extra.push(path.join(process.env.APPDATA, 'npm'));
  if (process.platform !== 'win32') extra.push('/opt/homebrew/bin', '/usr/local/bin');
  return [...fromPath, ...extra];
}

// { command, prefix }: the program to start and the arguments that come before the caller's own; null when not installed.
export function findCLI(name) {
  if (found.has(name)) return found.get(name);
  const override = process.env[`AGENTBAR_${name.toUpperCase()}_CLI`];
  let result = null;
  if (override) {
    result = override.endsWith('.mjs') || override.endsWith('.js')
      ? { command: process.execPath, prefix: [override] } : { command: override, prefix: [] };
  } else {
    for (const directory of searchDirectories()) {
      if (process.platform !== 'win32') {
        const file = path.join(directory, name);
        if (existsSync(file)) { result = { command: file, prefix: [] }; break; }
        continue;
      }
      const exe = path.join(directory, `${name}.exe`);
      if (existsSync(exe)) { result = { command: exe, prefix: [] }; break; }
      const shim = path.join(directory, `${name}.cmd`);
      if (existsSync(shim)) { result = fromShim(shim); if (result) break; }
    }
  }
  if (result) found.set(name, result);
  return result;
}

// npm's shim ends in `"%_prog%"  "%dp0%\node_modules\…\cli.js" %*`, or names an .exe the same way.
function fromShim(shim) {
  const directory = path.dirname(shim);
  const match = readFileSync(shim, 'utf8').match(/"%dp0%\\([^"]+\.(js|mjs|cjs|exe))"\s+%\*/i);
  if (!match) return null;
  const target = path.join(directory, match[1]);
  if (!existsSync(target)) return null;
  if (match[2].toLowerCase() === 'exe') return { command: target, prefix: [] };
  const besideIt = path.join(directory, 'node.exe');
  return { command: existsSync(besideIt) ? besideIt : process.execPath, prefix: [target] };
}

// The environment a CLI gets: AgentBar's own, without the variables that would point it at another login.
export function cleanEnvironment(extra = {}) {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) {
    if (/^(CLAUDE_CONFIG_DIR|CLAUDE_SECURESTORAGE_CONFIG_DIR|CODEX_HOME|CLAUDE_CODE_OAUTH_.*|NODE_OPTIONS)$/i.test(key)) delete environment[key];
  }
  return { ...environment, ...extra };
}

// Starts the CLI with its input and output connected; the caller talks to it.
export function startCLI(name, args, { env, cwd } = {}) {
  const cli = findCLI(name);
  if (!cli) throw Object.assign(new Error(`${name} is not installed`), { code: 'not-installed' });
  return spawn(cli.command, [...cli.prefix, ...args], { env: env ?? cleanEnvironment(), cwd: cwd ?? userHome, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
}

// Runs the CLI to its end with input closed. `status` is null when it ran out of time; `text` is stdout and
// stderr together and may hold a secret until the caller has scrubbed it. `control.cancel()` ends it early.
// `keepInput` leaves the input open (a browser sign-in waits on it).
export function runCLI(name, args, { env, cwd, timeout = 20_000, control, keepInput = false } = {}) {
  return new Promise((resolve, reject) => {
    let child;
    try { child = startCLI(name, args, { env, cwd }); } catch (error) { reject(error); return; }
    let text = '';
    let done = false;
    const finish = (status, cancelled = false) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (status === null) child.kill();
      resolve({ status, text, timedOut: status === null && !cancelled, cancelled });
    };
    const timer = setTimeout(() => finish(null), timeout);
    if (control) control.cancel = () => finish(null, true);
    if (!keepInput) child.stdin.end();
    child.stdin.on('error', () => {});
    const hear = (chunk) => { if (text.length < 2_000_000) text += chunk; };
    child.stdout.on('data', hear);
    child.stderr.on('data', hear);
    child.on('error', () => finish(127));
    child.on('close', (code) => finish(code ?? 1));
  });
}

// Opens an address in the person's own browser.
export function openInBrowser(url) {
  if (process.env.AGENTBAR_NO_BROWSER) return;
  if (process.platform === 'win32') spawn('rundll32.exe', ['url.dll,FileProtocolHandler', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  else spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
}
