// A stand-in for Anthropic for trying the app by hand (see demo.mjs). The state file says what each account's
// usage answer is ("access-<name>…" tokens name the account); claims are written back to it.
import { readFileSync, writeFileSync } from 'node:fs';
import http from 'node:http';

// Answers the port it listens on.
export function startMock(stateFile) {
  const read = () => JSON.parse(readFileSync(stateFile, 'utf8'));
  const server = http.createServer((request, response) => {
  let body = '';
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    const send = (status, value) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(value)); };
    const state = read();
    const bearer = (request.headers.authorization ?? '').replace('Bearer ', '');
    const name = /^access-([a-z0-9]+)/.exec(bearer)?.[1];
    if (request.url.startsWith('/api/oauth/usage')) {
      const account = state.usage[name];
      if (!account) return send(401, { error: 'unauthorized' });
      const answer = structuredClone(account);
      for (const window of [answer.five_hour, answer.seven_day, ...(answer.limits ?? [])]) if (window?.resets_in) { window.resets_at = new Date(Date.now() + window.resets_in * 1000).toISOString(); delete window.resets_in; }
      for (const grant of answer.cedar_ember?.grants ?? []) if (grant.ends_in) { grant.ends_at = new Date(Date.now() + grant.ends_in * 1000).toISOString(); delete grant.ends_in; }
      if (!request.url.includes('cedar_ember=1')) delete answer.cedar_ember;
      return send(200, answer);
    }
    if (request.url === '/v1/oauth/token') return send(200, { access_token: `access-${/^refresh-([a-z0-9]+)/.exec(JSON.parse(body).refresh_token)?.[1]}-renewed`, refresh_token: `${JSON.parse(body).refresh_token}~`, expires_in: 3600 });
    const claim = /^\/api\/organizations\/([^/]+)\/reset_rate_limits$/.exec(request.url);
    if (claim && request.method === 'POST') {
      const sent = JSON.parse(body);
      state.claims = [...(state.claims ?? []), { organization: claim[1], ...sent, agent: request.headers['user-agent'], at: new Date().toISOString() }];
      // The coupon is spent and the limit it clears is back to zero.
      const account = state.usage[name];
      const grant = account?.cedar_ember?.grants.find((item) => item.id === sent.grant_id);
      if (grant) { grant.resets_left -= 1; if ((grant.clears ?? []).includes('five_hour')) account.five_hour.utilization = 0; account.cedar_ember.at_limit = false; account.cedar_ember.exhausted = []; }
      writeFileSync(stateFile, JSON.stringify(state, null, 2));
      return send(200, { result: 'reset' });
    }
    send(404, {});
  });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}
