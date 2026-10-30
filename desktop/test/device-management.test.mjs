import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import WebSocket from '../../bridge/node_modules/ws/wrapper.mjs';
import { DesktopSupervisor } from '../../bridge/dist/supervisor.js';
import { createDashboard } from '../server.mjs';

test('desktop phone management keeps CSRF protection and reaches the managed service', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-manager-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const token = randomBytes(32).toString('base64url');
  const supervisor = new DesktopSupervisor({ token, port: 0, discovery: false, phoneDirectoryPath: join(dir, 'phones.json'), logFile: join(dir, 'operations.jsonl') });
  const url = await supervisor.start(); t.after(() => supervisor.close());
  const headers = { Authorization: `Bearer ${token}` }; const id = randomUUID();
  const ws = new WebSocket(url.replace('http', 'ws') + '/device', { headers }); t.after(() => ws.terminate()); await once(ws, 'open');
  ws.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId: id, registrationId: randomUUID(), device: 'Test phone', readOnly: true, capabilities: [] }));
  const state = async () => (await fetch(`${url}/status`, { headers })).json();
  const deadline = Date.now() + 5000; while (!(await state()).connected) { assert.ok(Date.now() < deadline); await new Promise(r => setTimeout(r, 10)); }
  const dash = await createDashboard({ config: { hostAddress: '127.0.0.1', port: Number(new URL(url).port) }, token, status: state, networks: () => [], qr: async () => '' }); t.after(() => dash.close());
  const body = JSON.stringify({ id, action: 'rename', name: 'My phone' });
  assert.equal((await fetch(`${dash.url}/device-management`, { method: 'POST', body })).status, 403);
  const mutationHeaders = { Origin: new URL(dash.url).origin, 'X-PhoneBridge-CSRF': dash.secret, 'Content-Type': 'application/json' };
  assert.equal((await fetch(`${dash.url}/device-management`, { method: 'POST', headers: mutationHeaders, body })).status, 200);
  const result = await (await fetch(`${dash.url}/status`)).json();
  assert.equal(result.devices[0].name, 'My phone'); assert.equal(result.devices[0].modelName, 'Test phone');
  assert.equal(result.devices[0].paused, false);
});
