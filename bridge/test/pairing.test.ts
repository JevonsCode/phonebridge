import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { pairingUri, startPairingDisplay } from '../src/pairing.js';

const token = 'test_token_for_pairing_only_0123456789';
test('pairing payload preserves credentials and rejects credential-bearing endpoints', () => {
  const uri = new URL(pairingUri('ws://192.168.1.10:8765/device', token));
  assert.equal(uri.protocol, 'phonebridge:');
  assert.equal(uri.hostname, 'pair');
  assert.deepEqual(Object.fromEntries(uri.searchParams), { v: '1', endpoint: 'ws://192.168.1.10:8765/device', token });
  for (const endpoint of ['http://localhost/device', 'ws://user:password@localhost/device', 'ws://localhost/other', 'ws://localhost/device?secret=x', 'ws://localhost/device#x']) assert.throws(() => pairingUri(endpoint, token));
  assert.throws(() => pairingUri('ws://localhost/device', 'short'));
});

test('pairing display is uncached, loopback, protected from foreign origins and host rebinding', async () => {
  const display = await startPairingDisplay('ws://192.168.1.10:8765/device', token);
  try {
    const response = await fetch(display.url);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.match(response.headers.get('content-security-policy')!, /frame-ancestors 'none'/);
    const html = await response.text();
    assert.match(html, /data:image\/png;base64,/);
    assert.equal(html.includes(token), false);
    assert.equal((await fetch(new URL('/', display.url))).status, 404);
    assert.equal((await fetch(display.url, { headers: { Origin: 'https://evil.example' } })).status, 404);
    assert.equal((await fetch(display.url, { headers: { 'Sec-Fetch-Site': 'cross-site' } })).status, 404);
    assert.equal((await fetch(display.url, { method: 'POST' })).status, 404);
    const status = await new Promise<number | undefined>((resolve, reject) => { const req = http.get(display.url, { headers: { Host: 'evil.example' } }, res => { res.resume(); resolve(res.statusCode); }); req.on('error', reject); });
    assert.equal(status, 404);
  } finally { await display.close(); }
});

test('pairing display remains available beyond five minutes without a refresh timer', async (t) => {
  const display = await startPairingDisplay('ws://192.168.1.10:8765/device', token);
  try {
    const later = Date.now() + 600_000;
    t.mock.method(Date, 'now', () => later);
    const response = await fetch(display.url);
    assert.equal(response.status, 200);
    const html = await response.text();
    assert.match(html, /data:image\/png;base64,/);
    assert.doesNotMatch(html, /http-equiv="refresh"/);
  } finally { await display.close(); }
});
