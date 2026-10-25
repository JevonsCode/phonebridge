import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import WebSocket from 'ws';
import { PhoneHub } from '../src/hub.js';
import { MemoryOperationJournal } from '../src/operation-journal.js';

async function fixture(t: TestContext, options: { timeoutMs?: number; heartbeatIntervalMs?: number } = {}) {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal: new MemoryOperationJournal(), ...options });
  const url = await hub.start(); t.after(() => hub.close());
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const status = async () => (await (await fetch(`${url}/devices`, { headers })).json());
  const poll = async (condition: () => Promise<boolean>) => {
    for (let attempt = 0; attempt < 300; attempt++) { if (await condition()) return; await new Promise(done => setTimeout(done, 5)); }
    throw new Error('Expected Hub diagnostic state did not arrive.');
  };
  const connect = async (deviceId = randomUUID(), autoPong = true) => {
    const phone = new WebSocket(url.replace('http', 'ws') + '/device', { headers, autoPong }); await once(phone, 'open');
    phone.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId, device: 'Diagnostics fixture', readOnly: false, capabilities: ['control_lease', 'control_queue'] }));
    await poll(async () => (await status()).devices.some((device: any) => device.id === deviceId && device.connected));
    return { phone, deviceId, connectionId: (await status()).devices.find((device: any) => device.id === deviceId).connectionId };
  };
  const rpc = async (method: string, params = {}, routing = {}) => {
    const response = await fetch(`${url}/rpc`, { method: 'POST', headers, body: JSON.stringify({ method, params, ...routing }) });
    return { status: response.status, body: await response.json() };
  };
  return { url, headers, token, status, poll, connect, rpc };
}

test('actual socket close is recorded without its private reason and survives same-device reconnection', async t => {
  const f = await fixture(t), first = await f.connect();
  const closed = once(first.phone, 'close'); first.phone.close(1000, 'PRIVATE_CLOSE_REASON'); await closed;
  await f.poll(async () => !(await f.status()).devices[0].connected);
  const offline = await f.status(), previous = offline.devices[0];
  assert.equal(previous.lastDisconnectReason, 'SOCKET_CLOSED'); assert.ok(Number.isFinite(Date.parse(previous.lastDisconnectedAt)));
  assert.equal(offline.details.knownDevices[0].lastDisconnectedAt, previous.lastDisconnectedAt);
  assert.doesNotMatch(JSON.stringify(offline), /PRIVATE_CLOSE_REASON/); assert.equal(JSON.stringify(offline).includes(f.token), false);
  const second = await f.connect(first.deviceId), reconnected = (await f.status()).devices[0];
  assert.equal(reconnected.connected, true); assert.notEqual(second.connectionId, first.connectionId);
  assert.equal(reconnected.lastDisconnectedAt, previous.lastDisconnectedAt); assert.equal(reconnected.lastDisconnectReason, 'SOCKET_CLOSED');
  assert.ok(Date.parse(reconnected.lastSeenAt) >= Date.parse(previous.lastSeenAt));
});

test('a missing pong is identified as a real heartbeat timeout rather than a generic socket close', { timeout: 3000 }, async t => {
  const f = await fixture(t, { heartbeatIntervalMs: 100 }), phone = await f.connect(undefined, false);
  await once(phone.phone, 'close'); await f.poll(async () => !(await f.status()).devices[0].connected);
  assert.equal((await f.status()).devices[0].lastDisconnectReason, 'HEARTBEAT_TIMEOUT');
});

test('command timeout and invalid protocol disconnects retain their observed causes', async t => {
  const f = await fixture(t, { timeoutMs: 50 }), phone = await f.connect();
  let count = 0; phone.phone.on('message', () => { count++; });
  const timedOut = await f.rpc('tap', { x: 1, y: 2 }, { deviceId: phone.deviceId });
  assert.equal(timedOut.body.error.code, 'TIMEOUT'); assert.equal(count, 1);
  assert.equal(timedOut.body.error.details.knownDevices[0].lastDisconnectReason, 'COMMAND_TIMEOUT');
  await f.poll(async () => !(await f.status()).devices[0].connected);
  const reconnected = await f.connect(phone.deviceId); const closed = once(reconnected.phone, 'close');
  reconnected.phone.send('{PRIVATE_INVALID_FRAME'); await closed;
  await f.poll(async () => !(await f.status()).devices[0].connected);
  assert.equal((await f.status()).devices[0].lastDisconnectReason, 'PROTOCOL_ERROR');
  assert.doesNotMatch(JSON.stringify(await f.status()), /PRIVATE_INVALID_FRAME/);
});

test('rpc, control wait and file errors preserve native details and offline device diagnostics', async t => {
  const f = await fixture(t), phone = await f.connect();
  const details = { foregroundPackage: 'dev.example.app', obscuredBy: 'toast', windowType: 'application_overlay' };
  phone.phone.on('message', bytes => {
    const request = JSON.parse(bytes.toString());
    phone.phone.send(JSON.stringify({ id: request.id, error: { code: 'WINDOW_OBSCURED', message: 'Window is obscured.', details } }));
  });
  const rpc = await f.rpc('state', {}, { deviceId: phone.deviceId }); assert.deepEqual(rpc.body.error.details, details);
  const query = new URLSearchParams({ deviceId: phone.deviceId, connectionId: phone.connectionId, controlId: randomUUID(), waitMs: '0' });
  const wait = await (await fetch(`${f.url}/control-events?${query}`, { headers: f.headers })).json(); assert.deepEqual(wait.error.details, details);
  const fileHeaders = { ...f.headers, 'Content-Type': 'application/octet-stream', 'X-PhoneBridge-File': Buffer.from(JSON.stringify({ name: 'test.txt', size: 3, mimeType: 'text/plain' })).toString('base64url') };
  const file = await (await fetch(`${f.url}/files?deviceId=${phone.deviceId}`, { method: 'POST', headers: fileHeaders, body: 'abc' })).json(); assert.deepEqual(file.error.details, details);
  const closed = once(phone.phone, 'close'); phone.phone.close(); await closed;
  await f.poll(async () => !(await f.status()).devices[0].connected);
  for (const path of [`/control-events?${query}`, '/files']) {
    const response = await fetch(`${f.url}${path}`, { headers: path === '/files' ? fileHeaders : f.headers, ...(path === '/files' ? { method: 'POST', body: 'abc' } : {}) });
    const result = await response.json(); assert.equal(result.error.code, 'NO_DEVICE');
    assert.equal(result.error.details.publicEndpoint, f.url); assert.equal(result.error.details.knownDevices[0].lastDisconnectReason, 'SOCKET_CLOSED');
  }
});
