// A stand-in for `codex app-server` in tests: JSON lines on stdio, answering from <CODEX_HOME>/fake.json
// ({ account, rateLimits, rateLimitResetCredits }). What it is asked to consume is appended to consumed.json.
import { appendFileSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';

const home = process.env.CODEX_HOME;
const data = () => JSON.parse(readFileSync(path.join(home, 'fake.json'), 'utf8'));
const answer = (id, result) => process.stdout.write(`${JSON.stringify({ id, result })}\n`);
createInterface({ input: process.stdin }).on('line', (line) => {
  const { id, method, params } = JSON.parse(line);
  if (method === 'initialize') answer(id, { userAgent: 'fake-codex' });
  else if (method === 'account/read') answer(id, { account: data().account });
  else if (method === 'account/rateLimits/read') answer(id, { rateLimits: data().rateLimits, rateLimitResetCredits: data().rateLimitResetCredits ?? null });
  else if (method === 'account/rateLimitResetCredit/consume') { appendFileSync(path.join(home, 'consumed.json'), `${JSON.stringify(params)}\n`); answer(id, { outcome: 'reset' }); }
  else if (id !== undefined) process.stdout.write(`${JSON.stringify({ id, error: { message: `unknown ${method}` } })}\n`);
});
