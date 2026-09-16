import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';

process.env.DEVBOX_WEB_TEST = '1';
process.env.DEVBOX_WEB_TOKEN = 'secret-test-token-12345';

const {
  server,
  wss,
  parseCookies,
  checkAuth,
  isAllowedOrigin,
  safeTokenCompare,
  isDaResponse
} = await import('../server.js');

test('parseCookies correctly parses cookie strings', () => {
  assert.deepEqual(parseCookies(''), {});
  assert.deepEqual(parseCookies(undefined), {});

  const cookieStr = 'devbox_token=secret-token; theme=dark; session_id=abc123';
  const cookies = parseCookies(cookieStr);
  assert.equal(cookies['devbox_token'], 'secret-token');
  assert.equal(cookies['theme'], 'dark');
  assert.equal(cookies['session_id'], 'abc123');

  // URL-encoded values
  const encoded = 'devbox_token=hello%20world%21';
  assert.equal(parseCookies(encoded)['devbox_token'], 'hello world!');

  // Malformed URL-encoded value does not throw URIError (DoS protection)
  const malformed = 'devbox_token=%E0%A4%A; theme=dark';
  assert.doesNotThrow(() => {
    const parsed = parseCookies(malformed);
    assert.equal(parsed['devbox_token'], '%E0%A4%A');
    assert.equal(parsed['theme'], 'dark');
  });
});

test('checkAuth verifies authentication via headers, cookies, and query params', () => {
  const validToken = 'secret-test-token-12345';

  // 1. Authorization: Bearer
  const reqBearer = {
    headers: { authorization: `Bearer ${validToken}` }
  };
  assert.equal(checkAuth(reqBearer, new URL('http://localhost/api/status')), true);

  // 2. Custom header: x-devbox-token
  const reqHeader = {
    headers: { 'x-devbox-token': validToken }
  };
  assert.equal(checkAuth(reqHeader, new URL('http://localhost/api/status')), true);

  // 3. Cookie: devbox_token
  const reqCookie = {
    headers: { cookie: `devbox_token=${validToken}` }
  };
  assert.equal(checkAuth(reqCookie, new URL('http://localhost/api/status')), true);

  // 4. Query param ?token=
  const reqQuery = {
    headers: {}
  };
  assert.equal(checkAuth(reqQuery, new URL(`http://localhost/api/status?token=${validToken}`)), true);

  // 5. Invalid token rejected
  const reqInvalid = {
    headers: { authorization: 'Bearer wrong-token' }
  };
  assert.equal(checkAuth(reqInvalid, new URL('http://localhost/api/status')), false);

  // 6. No credentials rejected
  assert.equal(checkAuth({ headers: {} }, new URL('http://localhost/api/status')), false);
});

test('isAllowedOrigin validates origins against Host and X-Forwarded-Host', () => {
  // Matching origin and host on HTTP
  assert.equal(isAllowedOrigin('http://localhost:7681', 'localhost:7681'), true);
  assert.equal(isAllowedOrigin('http://127.0.0.1:7681', '127.0.0.1:7681'), true);

  // Scheme mismatch on plain HTTP rejected
  assert.equal(isAllowedOrigin('https://localhost:7681', 'localhost:7681'), false);

  // HTTPS connection accepts HTTPS origin, rejects HTTP
  assert.equal(isAllowedOrigin('https://agent-devbox.tailnet.ts.net', 'agent-devbox.tailnet.ts.net', null, false, null, true), true);
  assert.equal(isAllowedOrigin('http://agent-devbox.tailnet.ts.net', 'agent-devbox.tailnet.ts.net', null, false, null, true), false);

  // Different port on same host must be REJECTED
  assert.equal(isAllowedOrigin('http://devbox:3000', 'devbox:7681'), false);
  assert.equal(isAllowedOrigin('http://localhost:3000', 'localhost:7681'), false);

  // Invalid schemes rejected
  assert.equal(isAllowedOrigin('ftp://localhost:7681', 'localhost:7681'), false);
  assert.equal(isAllowedOrigin('javascript:alert(1)', 'localhost:7681'), false);

  // X-Forwarded-Host with X-Forwarded-Proto only trusted when isTrustedProxy is true
  assert.equal(isAllowedOrigin('https://my-proxy.internal', 'localhost:7681', 'my-proxy.internal', true, 'https'), true);
  assert.equal(isAllowedOrigin('http://my-proxy.internal', 'localhost:7681', 'my-proxy.internal', true, 'https'), false);
  assert.equal(isAllowedOrigin('https://my-proxy.internal', 'localhost:7681', 'my-proxy.internal', false, 'https'), false);

  // Foreign origin rejected
  assert.equal(isAllowedOrigin('http://attacker.com', 'localhost:7681'), false);
  assert.equal(isAllowedOrigin('http://malicious.org', 'agent-devbox.tailnet.ts.net'), false);
});

test('server rejects cross-origin POST requests with 403 Forbidden', async () => {
  // Start ephemeral server on random port for testing
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  try {
    // Attempt POST to /api/upload from foreign origin
    const resUpload = await makeRequest({
      port,
      path: '/api/upload',
      method: 'POST',
      headers: {
        'Origin': 'http://evil-site.com',
        'Host': `127.0.0.1:${port}`,
        'Authorization': 'Bearer secret-test-token-12345'
      }
    });
    assert.equal(resUpload.statusCode, 403);
    assert.match(resUpload.body, /cross-origin POST not allowed/i);

    // Attempt POST to /api/action from foreign origin
    const resAction = await makeRequest({
      port,
      path: '/api/action',
      method: 'POST',
      headers: {
        'Origin': 'http://evil-site.com',
        'Host': `127.0.0.1:${port}`,
        'Authorization': 'Bearer secret-test-token-12345'
      }
    });
    assert.equal(resAction.statusCode, 403);
    assert.match(resAction.body, /cross-origin POST not allowed/i);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await new Promise((resolve) => wss.close(resolve));
  }
});

test('server does not crash on malformed cookie request (DoS resistance)', async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  try {
    const res = await makeRequest({
      port,
      path: '/api/status',
      method: 'GET',
      headers: {
        'Cookie': 'devbox_token=%E0%A4%A; test=123',
        'Host': `127.0.0.1:${port}`
      }
    });
    // Should reject with 401 Unauthorized (since token is invalid), not crash
    assert.equal(res.statusCode, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await new Promise((resolve) => wss.close(resolve));
  }
});

test('server handles malformed multipart upload gracefully without crashing', async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  try {
    const validToken = 'secret-test-token-12345';
    // Malformed multipart: Content-Type boundary declared but body abruptly cut off
    const res = await new Promise((resolve, reject) => {
      const req = http.request({
        hostname: '127.0.0.1',
        port,
        path: '/api/upload',
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${validToken}`,
          'Content-Type': 'multipart/form-data; boundary=---------------------------974767299852498929531610575',
          'Host': `127.0.0.1:${port}`
        }
      }, (res) => {
        let data = '';
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => {
          resolve({ statusCode: res.statusCode, headers: res.headers, body: data });
        });
      });
      req.on('error', reject);
      // Send incomplete body without closing boundary
      req.write('-----------------------------974767299852498929531610575\r\n');
      req.write('Content-Disposition: form-data; name="file"; filename="broken.txt"\r\n\r\n');
      req.write('partial content...');
      req.end();
    });

    assert.equal(res.statusCode, 400);
    const parsed = JSON.parse(res.body);
    assert.ok(parsed.error);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await new Promise((resolve) => wss.close(resolve));
  }
});

test('server handles upload with 254-char filename gracefully without crashing', async () => {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  try {
    const longName = 'a'.repeat(250) + '.txt';
    const boundary = '---------------------------longfilename12345';
    const bodyParts = [
      `--${boundary}\r\n`,
      `Content-Disposition: form-data; name="file"; filename="${longName}"\r\n`,
      'Content-Type: text/plain\r\n\r\n',
      'hello world from long file\r\n',
      `--${boundary}--\r\n`
    ].join('');

    const res = await new Promise((resolve, reject) => {
      const req = http.request({
        hostname: '127.0.0.1',
        port,
        path: '/api/upload',
        method: 'POST',
        headers: {
          'Content-Type': `multipart/form-data; boundary=${boundary}`,
          'Content-Length': Buffer.byteLength(bodyParts),
          'Authorization': 'Bearer secret-test-token-12345'
        }
      }, (res) => {
        let data = '';
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => {
          resolve({ statusCode: res.statusCode, headers: res.headers, body: data });
        });
      });
      req.on('error', reject);
      req.write(bodyParts);
      req.end();
    });

    assert.equal(res.statusCode, 200);
    const parsed = JSON.parse(res.body);
    assert.equal(parsed.ok, true);
    assert.ok(parsed.file.filename.length <= 255);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await new Promise((resolve) => wss.close(resolve));
  }
});

test('isDaResponse identifies Device Attributes responses and passes regular input', () => {
  // DA2 (Secondary Device Attributes response from xterm.js)
  assert.equal(isDaResponse('\x1b[>0;276;0c'), true);
  assert.equal(isDaResponse('\x1b[>1;10;0c'), true);

  // DA1 (Primary Device Attributes response)
  assert.equal(isDaResponse('\x1b[?1;2c'), true);
  assert.equal(isDaResponse('\x1b[?62;1;2;7;8;9c'), true);

  // Regular text and keypresses must NOT be filtered
  assert.equal(isDaResponse('ls -la\n'), false);
  assert.equal(isDaResponse('c'), false);
  assert.equal(isDaResponse('\x1b[A'), false); // Up arrow
  assert.equal(isDaResponse('\x1b[B'), false); // Down arrow
  assert.equal(isDaResponse('\x1b[C'), false); // Right arrow
  assert.equal(isDaResponse('\x1b[1;2C'), false); // Shift-Right arrow
  assert.equal(isDaResponse('echo "0;276;0c"'), false);
  assert.equal(isDaResponse(null), false);
  assert.equal(isDaResponse(undefined), false);
});

function makeRequest(options) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: '127.0.0.1',
      port: options.port,
      path: options.path,
      method: options.method,
      headers: options.headers
    }, (res) => {
      let data = '';
      res.on('data', chunk => { data += chunk; });
      res.on('end', () => {
        resolve({ statusCode: res.statusCode, headers: res.headers, body: data });
      });
    });
    req.on('error', reject);
    req.end();
  });
}
