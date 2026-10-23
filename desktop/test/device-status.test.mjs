import test from 'node:test';
import assert from 'node:assert/strict';
import { createDashboard } from '../server.mjs';

test('dashboard preserves safe device identity and concurrent states without transport secrets', async t => {
  const devices = [
    { id: 'one', name: 'Work phone', connected: true, busy: true, readOnly: false, protocol: 2, capabilities: ['state'], token: 'must-not-appear', connectionId: 'c0a1e972-72b7-427e-963d-fc143de1f265', controlling: true, controlOwnerName: 'Work PC', waitingCount: 3 },
    { id: 'two', name: 'Home phone', connected: false, busy: false, readOnly: true, protocol: 2, capabilities: [], transfer: { name: 'test.png', size: 4, state: 'received', localPath: 'private-path' } },
  ];
  const dash = await createDashboard({ config: { hostAddress: '127.0.0.1', port: 8765 }, token: 'private', status: async () => ({ connected: true, devices }), networks: () => [], qr: async () => '' });
  t.after(() => dash.close());
  const response = await fetch(`${dash.url}/status`);
  const status = await response.json();
  assert.equal(status.connected, true);
  assert.equal(status.devices.length, 2);
  assert.deepEqual(status.devices[0], { id: 'one', name: 'Work phone', connected: true, protocol: 2, capabilities: ['state'], busy: true, readOnly: false, connectionId: 'c0a1e972-72b7-427e-963d-fc143de1f265', controlling: true, controlOwnerName: 'Work PC', waitingCount: 3 });
  assert.equal(status.devices[1].connected, false);
  assert.deepEqual(status.devices[1].transfer, { name: 'test.png', size: 4, state: 'received' });
  assert.equal(JSON.stringify(status).includes('must-not-appear'), false);
  assert.equal(JSON.stringify(status).includes('private-path'), false);
  for (const count of [0, 64, 65, -1, '2', 1.5]) {
    devices[0].waitingCount = count;
    const next = await (await fetch(`${dash.url}/status`)).json();
    assert.equal(next.devices[0].waitingCount, Number.isInteger(count) && count >= 0 && count <= 64 ? count : undefined);
  }
  const headers = { Origin: new URL(dash.url).origin, 'X-PhoneBridge-CSRF': dash.secret, 'Content-Type': 'application/json' };
  const invalid = await fetch(`${dash.url}/send-file`, { method: 'POST', headers, body: JSON.stringify({ path: '/unused', deviceId: 42 }) });
  assert.equal(invalid.status, 409);
  assert.match((await invalid.json()).error, /Invalid device target/);
  const invalidConnection = await fetch(`${dash.url}/send-file`, { method: 'POST', headers, body: JSON.stringify({ path: '/unused', deviceId: 'one', connectionId: 'bad-generation' }) });
  assert.equal(invalidConnection.status, 409);
  assert.match((await invalidConnection.json()).error, /Invalid connection identity/);
});
