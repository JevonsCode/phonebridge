import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import WebSocket from '../../bridge/node_modules/ws/wrapper.mjs';
import { PhoneHub } from '../../bridge/dist/hub.js';
import { MemoryOperationJournal } from '../../bridge/dist/operation-journal.js';
import { createDashboard, authenticatedStatus } from '../server.mjs';

test('desktop file sender preserves local CSRF checks and reports pending until phone receipt', async t => {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal: new MemoryOperationJournal() });
  const url = new URL(await hub.start()); t.after(() => hub.close());
  const config = { hostAddress: url.hostname, port: Number(url.port) };
  const dash = await createDashboard({ config, token, status: () => authenticatedStatus(config, token), networks: () => [], qr: async () => '' }); t.after(() => dash.close());
  const ws = new WebSocket(url.toString().replace('http', 'ws') + 'device', { headers: { Authorization: `Bearer ${token}` } }); await once(ws, 'open');
  ws.send(JSON.stringify({ type: 'hello', protocol: 1, readOnly: true }));
  while (!(await authenticatedStatus(config, token)).connected) await new Promise(r => setTimeout(r, 5));
  assert.equal((await (await fetch(`${dash.url}/status`)).json()).devices[0].readOnly, true);
  ws.on('message', bytes => { const request = JSON.parse(bytes.toString()); ws.send(JSON.stringify({ id: request.id, result: { queued: true } })); });
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-desktop-file-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'fixture.png'); await writeFile(path, 'fixture');
  const body = JSON.stringify({ path });
  assert.equal((await fetch(`${dash.url}/send-file`, { method: 'POST', body })).status, 403);
  const headers = { Origin: new URL(dash.url).origin, 'X-PhoneBridge-CSRF': dash.secret, 'Content-Type': 'application/json' };
  const result = await fetch(`${dash.url}/send-file`, { method: 'POST', headers, body });
  assert.equal(result.status, 200); assert.equal((await result.json()).transfer.state, 'pending');
  assert.equal((await (await fetch(`${dash.url}/status`)).json()).transfer.state, 'pending');
});

test('desktop rejects a stale legacy connection generation instead of sending to its replacement', async t => {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal: new MemoryOperationJournal() });
  const url = new URL(await hub.start()); t.after(() => hub.close());
  const config = { hostAddress: url.hostname, port: Number(url.port) };
  const dash = await createDashboard({ config, token, status: () => authenticatedStatus(config, token), networks: () => [], qr: async () => '' }); t.after(() => dash.close());
  const connectLegacy = async () => {
    const ws = new WebSocket(url.toString().replace('http', 'ws') + 'device', { headers: { Authorization: `Bearer ${token}` } });
    await once(ws, 'open'); ws.send(JSON.stringify({ type: 'hello', protocol: 1, readOnly: true }));
    return ws;
  };
  const first = await connectLegacy();
  while (!(await authenticatedStatus(config, token)).connected) await new Promise(r => setTimeout(r, 5));
  const original = (await (await fetch(`${dash.url}/status`)).json()).devices[0];
  const closed = once(first, 'close'); first.close(); await closed;
  while ((await authenticatedStatus(config, token)).connected) await new Promise(r => setTimeout(r, 5));
  const replacement = await connectLegacy();
  const received = [];
  replacement.on('message', bytes => {
    const request = JSON.parse(bytes.toString()); received.push(request);
    replacement.send(JSON.stringify({ id: request.id, result: { queued: true } }));
  });
  while (!(await authenticatedStatus(config, token)).connected) await new Promise(r => setTimeout(r, 5));
  const current = (await (await fetch(`${dash.url}/status`)).json()).devices[0];
  assert.equal(original.id, current.id);
  assert.notEqual(original.connectionId, current.connectionId);
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-legacy-file-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'fixture.png'); await writeFile(path, 'fixture');
  const headers = { Origin: new URL(dash.url).origin, 'X-PhoneBridge-CSRF': dash.secret, 'Content-Type': 'application/json' };
  const send = connectionId => fetch(`${dash.url}/send-file`, { method: 'POST', headers, body: JSON.stringify({ path, deviceId: original.id, connectionId }) });
  const stale = await send(original.connectionId);
  assert.equal(stale.status, 409);
  assert.match((await stale.json()).error, /connection has changed/i);
  assert.equal(received.length, 0);
  assert.equal((await send(current.connectionId)).status, 200);
  assert.equal(received.length, 1);
});

test('desktop file target is explicit with two phones and never falls back after disconnect', async t => {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal: new MemoryOperationJournal() });
  const url = new URL(await hub.start()); t.after(() => hub.close());
  const config = { hostAddress: url.hostname, port: Number(url.port) };
  const dash = await createDashboard({ config, token, status: () => authenticatedStatus(config, token), networks: () => [], qr: async () => '' }); t.after(() => dash.close());
  const ids = [randomUUID(), randomUUID()];
  const received = [[], []];
  const phones = await Promise.all(ids.map(async (id, index) => {
    const ws = new WebSocket(url.toString().replace('http', 'ws') + 'device', { headers: { Authorization: `Bearer ${token}` } });
    await once(ws, 'open');
    ws.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId: id, device: `Phone ${index + 1}`, readOnly: false, capabilities: [] }));
    ws.on('message', bytes => {
      const request = JSON.parse(bytes.toString()); received[index].push(request);
      ws.send(JSON.stringify({ id: request.id, result: { queued: true } }));
    });
    return ws;
  }));
  while ((await authenticatedStatus(config, token)).devices.filter(d => d.connected).length !== 2) await new Promise(r => setTimeout(r, 5));
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-device-file-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'fixture.png'); await writeFile(path, 'fixture');
  const headers = { Origin: new URL(dash.url).origin, 'X-PhoneBridge-CSRF': dash.secret, 'Content-Type': 'application/json' };
  const send = deviceId => fetch(`${dash.url}/send-file`, { method: 'POST', headers, body: JSON.stringify({ path, deviceId }) });
  assert.equal((await send(undefined)).status, 409);
  assert.equal((await send(ids[1])).status, 200);
  assert.equal(received[0].length, 0);
  assert.equal(received[1].length, 1);
  const closed = once(phones[1], 'close'); phones[1].close(); await closed;
  while ((await authenticatedStatus(config, token)).devices.some(d => d.id === ids[1] && d.connected)) await new Promise(r => setTimeout(r, 5));
  assert.equal((await send(ids[1])).status, 409);
  assert.equal(received[0].length, 0);
});
