import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

// Tailnet identity mode: no shared token, identity comes from `tailscale whois`
// (faked by fixtures/fake-tailscale.sh) or from `tailscale serve` headers.
delete process.env.DEVBOX_WEB_TOKEN;
delete process.env.AUTH_TOKEN;
delete process.env.DEVBOX_WEB_TEST;
delete process.env.DEVBOX_WEB_USERS;
process.env.DEVBOX_WEB_AUTH = 'tailscale';
process.env.DEVBOX_TAILSCALE_BIN = fileURLToPath(new URL('./fixtures/fake-tailscale.sh', import.meta.url));
process.env.HOST = '127.0.0.1';

const {
  server,
  wss,
  AUTH_MODE,
  hostnameOf,
  isAllowedHost,
  resolveIdentity,
  identityAllowed,
  authorize,
  checkAuth
} = await import('../server.js');

const fakeReq = (remoteAddress, headers = {}) => ({ socket: { remoteAddress }, headers });

test('starts in tailscale mode without a token', () => {
  assert.equal(AUTH_MODE, 'tailscale');
  assert.equal(checkAuth({ headers: { authorization: 'Bearer anything' } }, new URL('http://localhost/api/status')), false);
});

test('hostnameOf strips ports and IPv6 brackets', () => {
  assert.equal(hostnameOf('agent-devbox:7681'), 'agent-devbox');
  assert.equal(hostnameOf('Agent-Devbox-1.TailXYZ.ts.net'), 'agent-devbox-1.tailxyz.ts.net');
  assert.equal(hostnameOf('[fd7a:115c:a1e0::10]:7681'), 'fd7a:115c:a1e0::10');
  assert.equal(hostnameOf('100.64.0.10'), '100.64.0.10');
  assert.equal(hostnameOf(''), '');
});

test('isAllowedHost accepts only names this node answers to', async () => {
  assert.equal(await isAllowedHost('agent-devbox-1.tailxyz.ts.net:7681'), true);
  assert.equal(await isAllowedHost('agent-devbox-1'), true);
  assert.equal(await isAllowedHost('100.64.0.10:7681'), true);
  assert.equal(await isAllowedHost('[fd7a:115c:a1e0::10]:7681'), true);
  assert.equal(await isAllowedHost('localhost:7681'), true);
  assert.equal(await isAllowedHost('evil.example.com'), false);
  assert.equal(await isAllowedHost('100.64.0.99'), false);

  process.env.DEVBOX_ALLOWED_HOSTS = 'devbox.internal';
  try {
    assert.equal(await isAllowedHost('devbox.internal:7681'), true);
  } finally {
    delete process.env.DEVBOX_ALLOWED_HOSTS;
  }
});

test('resolveIdentity uses whois for tailnet peers and headers for tailscale serve', async () => {
  const human = await resolveIdentity(fakeReq('::ffff:100.64.0.20'));
  assert.equal(human.login, 'bohdan@example.com');
  assert.equal(human.via, 'whois');
  assert.equal(identityAllowed(human), true);

  const machine = await resolveIdentity(fakeReq('100.64.0.30'));
  assert.equal(machine.tagged, true);
  assert.equal(identityAllowed(machine), false);

  assert.equal(await resolveIdentity(fakeReq('100.64.0.99')), null);
  assert.equal(await resolveIdentity(fakeReq('127.0.0.1')), null);

  const served = await resolveIdentity(fakeReq('127.0.0.1', { 'tailscale-user-login': 'bohdan@example.com' }));
  assert.equal(served.via, 'serve');
  assert.equal(identityAllowed(served), true);
});

test('DEVBOX_WEB_USERS restricts logins', async () => {
  const human = await resolveIdentity(fakeReq('100.64.0.20'));
  process.env.DEVBOX_WEB_USERS = 'other@example.com';
  try {
    assert.equal(identityAllowed(human), false);
    process.env.DEVBOX_WEB_USERS = 'Other@example.com, BOHDAN@example.com';
    assert.equal(identityAllowed(human), true);
  } finally {
    delete process.env.DEVBOX_WEB_USERS;
  }
  const denied = await authorize(fakeReq('100.64.0.30'), new URL('http://agent-devbox-1/api/status'));
  assert.equal(denied.ok, false);
});

test('HTTP: host allowlist, serve identity, and rejection without identity', async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  try {
    const rebinding = await makeRequest(port, '/api/status', { Host: 'evil.example.com' });
    assert.equal(rebinding.statusCode, 421);

    const anonymous = await makeRequest(port, '/api/status', { Host: `agent-devbox-1:${port}` });
    assert.equal(anonymous.statusCode, 401);
    assert.match(anonymous.body, /no tailnet identity/i);

    const served = await makeRequest(port, '/api/status', {
      Host: `agent-devbox-1:${port}`,
      'Tailscale-User-Login': 'bohdan@example.com'
    });
    assert.equal(served.statusCode, 200);
    const body = JSON.parse(served.body);
    assert.equal(body.auth, 'tailscale');
    assert.equal(body.user, 'bohdan@example.com');

    const tokenIgnored = await makeRequest(port, '/?token=anything', { Host: `agent-devbox-1:${port}` });
    assert.equal(tokenIgnored.statusCode, 200); // no cookie bootstrap in tailscale mode
    assert.equal(tokenIgnored.headers['set-cookie'], undefined);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('WebSocket upgrade is refused without a tailnet identity', async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  try {
    const status = await new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?client=desktop`, {
        headers: { Host: `agent-devbox-1:${port}` }
      });
      ws.on('unexpected-response', (req, res) => {
        res.resume();
        resolve(res.statusCode);
      });
      ws.on('open', () => reject(new Error('handshake should have been refused')));
      ws.on('error', err => reject(err));
    });
    assert.equal(status, 401);
  } finally {
    await new Promise(resolve => server.close(resolve));
    await new Promise(resolve => wss.close(resolve));
  }
});

function makeRequest(port, path, headers) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port, path, method: 'GET', headers }, res => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => resolve({ statusCode: res.statusCode, headers: res.headers, body: data }));
    });
    req.on('error', reject);
    req.end();
  });
}
