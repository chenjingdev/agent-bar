// A door on this computer only, for AgentBar itself: a second start uses it to tell the running one to show its
// panel or to quit, and a test uses it to read the state and press things. Every request has to carry the token
// in run.json (a file only this user can read) and name this address as its host, so no page in a browser can ask.
import { randomBytes } from 'node:crypto';
import http from 'node:http';

// `actions` maps a name to a function of the request's JSON body; what it answers is sent back as JSON.
export async function startServer(actions) {
  const token = randomBytes(24).toString('hex');
  const server = http.createServer((request, response) => {
    const send = (status, body) => { response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); response.end(body); };
    const port = server.address().port;
    const action = request.url.startsWith('/api/') ? actions[request.url.slice('/api/'.length)] : null;
    if (request.method !== 'POST' || request.headers.host !== `127.0.0.1:${port}` || request.headers.origin
      || request.headers['x-agentbar-token'] !== token || !action) return send(403, '{}');
    let body = '';
    request.on('data', (chunk) => { if (body.length < 100_000) body += chunk; });
    request.on('end', async () => {
      try { send(200, JSON.stringify((await action(body ? JSON.parse(body) : {})) ?? {})); } catch { send(500, '{}'); }
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { port: server.address().port, token, close: () => server.close() };
}
