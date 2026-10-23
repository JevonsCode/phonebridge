import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { PhoneHub } from '../src/hub.js';
import { MemoryOperationJournal, type OperationJournal } from '../src/operation-journal.js';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BridgeError } from '../src/protocol.js';
import { sendLocalFile } from '../src/send-file.js';

async function setup(t: TestContext, timeoutMs = 1000, journal: OperationJournal = new MemoryOperationJournal()) {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, timeoutMs, journal });
  const url = await hub.start(); t.after(() => hub.close());
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const devices = async () => (await (await fetch(`${url}/devices`, { headers })).json()).devices;
  const poll = async (check: () => Promise<boolean>) => {
    for (let n = 0; n < 100; n++) { if (await check()) return; await delay(5); }
    throw new Error('Expected device state did not arrive');
  };
  const connect = async (id = randomUUID(), protocol = 2, capabilities = ['control_lease', 'element_actions']) => {
    const phone = new WebSocket(url.replace('http', 'ws') + '/device', { headers });
    const upgrade = once(phone, 'upgrade'); await once(phone, 'open');
    assert.equal((await upgrade)[0].headers['x-phonebridge-protocol'], '2');
    phone.send(JSON.stringify(protocol === 1 ? { type: 'hello', protocol: 1, device: 'Old phone' } : { type: 'hello', protocol: 2, deviceId: id, device: `Phone ${id}`, readOnly: false, capabilities }));
    await poll(async () => (await devices()).some((d: any) => d.id === (protocol === 1 ? 'legacy' : id) && d.connected));
    return { phone, id: protocol === 1 ? 'legacy' : id };
  };
  const rpc = async (method: string, params = {}, routing = {}) => {
    const response = await fetch(`${url}/rpc`, { method: 'POST', headers, body: JSON.stringify({ method, params, ...routing }) });
    return { status: response.status, body: await response.json() };
  };
  return { hub, url, headers, devices, poll, connect, rpc, journal };
}
const answer = (phone: WebSocket, label: string) => phone.on('message', bytes => {
  const r = JSON.parse(bytes.toString()); phone.send(JSON.stringify({ id: r.id, result: { phone: label } }));
});

test('two phones run concurrently; target is explicit and attribution stays separate', async t => {
  const s = await setup(t); const a = await s.connect(); const b = await s.connect();
  assert.equal((await fetch(`${s.url}/devices`)).status, 401);
  assert.equal((await s.rpc('state')).body.error.code, 'DEVICE_REQUIRED');
  const controlId = randomUUID();
  const connectionId = (await s.devices()).find((d: any) => d.id === a.id).connectionId;
  const incomingA = once(a.phone, 'message'); const incomingB = once(b.phone, 'message');
  const first = s.rpc('state', {}, { deviceId: a.id, controlId, connectionId });
  const second = s.rpc('state', {}, { deviceId: b.id });
  const [ra, rb] = await Promise.all([incomingA, incomingB]);
  const ca = JSON.parse(ra[0].toString()); const cb = JSON.parse(rb[0].toString());
  assert.equal(ca.controlId, controlId); assert.equal('deviceId' in ca, false); assert.deepEqual(ca.params, {});
  assert.equal('connectionId' in ca, false);
  assert.equal(cb.controlId, undefined);
  const busy = await s.devices(); assert.equal(busy.filter((d: any) => d.busy).length, 2);
  assert.equal((await s.rpc('state', {}, { deviceId: a.id })).body.error.code, 'BUSY');
  a.phone.send(JSON.stringify({ id: ca.id, result: { phone: 'A' } }));
  b.phone.send(JSON.stringify({ id: cb.id, result: { phone: 'B' } }));
  assert.deepEqual((await first).body.result, { phone: 'A' }); assert.deepEqual((await second).body.result, { phone: 'B' });
  const history = await s.journal.read({ deviceId: a.id });
  assert.equal(history.operations.find(r => r.status === 'completed')!.controlId, controlId);
  assert.ok(history.operations.every(r => r.deviceId === a.id));
  const filtered = await (await fetch(`${s.url}/operations?deviceId=${a.id}`, { headers: s.headers })).json();
  assert.ok(filtered.operations.every((r: any) => r.deviceId === a.id));
});

test('offline targets never fall back and duplicate live IDs cannot replace a phone', async t => {
  const s = await setup(t); const a = await s.connect(); const b = await s.connect(); answer(b.phone, 'B');
  const duplicate = new WebSocket(s.url.replace('http', 'ws') + '/device', { headers: s.headers });
  await once(duplicate, 'open'); const closed = once(duplicate, 'close');
  duplicate.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId: a.id, device: 'Impostor', readOnly: true, capabilities: [] }));
  assert.equal((await closed)[0], 1008);
  assert.equal((await s.devices()).find((d: any) => d.id === a.id).readOnly, false);
  const disconnected = once(a.phone, 'close'); a.phone.close(); await disconnected;
  await s.poll(async () => !(await s.devices()).find((d: any) => d.id === a.id).connected);
  assert.equal((await s.rpc('tap', { x: 1, y: 2 }, { deviceId: a.id })).body.error.code, 'NO_DEVICE');
  assert.equal((await s.rpc('state', {}, { deviceId: randomUUID() })).body.error.code, 'NO_DEVICE');
  assert.deepEqual((await s.rpc('state')).body.result, { phone: 'B' });
  assert.equal((await s.devices()).length, 2);
});

test('one timeout closes only its phone and never replays a command', async t => {
  const s = await setup(t, 1000); const a = await s.connect(); const b = await s.connect(); answer(b.phone, 'B');
  let count = 0; a.phone.on('message', () => count++);
  const timeout = await s.rpc('tap', { x: 1, y: 2 }, { deviceId: a.id });
  assert.equal(timeout.body.error.code, 'TIMEOUT');
  assert.deepEqual((await s.rpc('state', {}, { deviceId: b.id })).body.result, { phone: 'B' });
  assert.equal(count, 1);
  assert.equal((await s.devices()).find((d: any) => d.id === b.id).connected, true);
  const row = (await s.journal.read({ deviceId: a.id })).operations[0]!;
  assert.equal(row.outcome, 'unknown'); assert.equal(row.status, 'uncertain');
});

test('legacy wire stays unchanged and unsupported capabilities send nothing', async t => {
  const s = await setup(t); const a = await s.connect(randomUUID(), 1); let count = 0;
  a.phone.on('message', bytes => {
    count++; const r = JSON.parse(bytes.toString());
    assert.deepEqual(Object.keys(r).sort(), ['id', 'method', 'params']);
    a.phone.send(JSON.stringify({ id: r.id, result: { legacy: true } }));
  });
  assert.deepEqual((await s.rpc('state')).body.result, { legacy: true });
  assert.equal((await s.rpc('acquire_control', { controlId: randomUUID() })).body.error.code, 'UNSUPPORTED');
  assert.equal((await s.rpc('node_action', { nodeId: 'snapshot-node', action: 'click' })).body.error.code, 'UNSUPPORTED');
  assert.equal(count, 1);
  const b = await s.connect(randomUUID(), 2, []); answer(b.phone, 'B');
  assert.equal((await s.rpc('acquire_control', { controlId: randomUUID() }, { deviceId: b.id })).body.error.code, 'UNSUPPORTED');
});

test('file offers and downloads use independent phone slots', async t => {
  const s = await setup(t); const a = await s.connect(); const b = await s.connect();
  answer(a.phone, 'A'); answer(b.phone, 'B');
  const upload = async (deviceId: string, bytes: string) => {
    const response = await fetch(`${s.url}/files?deviceId=${deviceId}&controlId=${randomUUID()}`, { method: 'POST', headers: { ...s.headers, 'Content-Type': 'application/octet-stream', 'X-PhoneBridge-File': Buffer.from(JSON.stringify({ name: 'test.txt', mimeType: 'text/plain', size: bytes.length })).toString('base64url') }, body: bytes });
    assert.equal(response.status, 201); return (await response.json()).transfer.id;
  };
  const [fa, fb] = await Promise.all([upload(a.id, 'AAA'), upload(b.id, 'BBB')]);
  assert.notEqual(fa, fb);
  const transfers = async () => (await (await fetch(`${s.url}/status`, { headers: s.headers })).json()).devices;
  let states = await transfers();
  assert.deepEqual(states.map((d: any) => [d.id, d.transfer.id, d.transfer.state]), [[a.id, fa, 'pending'], [b.id, fb, 'pending']]);
  assert.equal(await (await fetch(`${s.url}/files/${fa}`, { headers: s.headers })).text(), 'AAA');
  assert.equal((await fetch(`${s.url}/files/${fa}/received`, { method: 'POST', headers: s.headers })).status, 200);
  states = await transfers();
  assert.equal(states.find((d: any) => d.id === a.id).transfer.state, 'received');
  assert.equal(states.find((d: any) => d.id === b.id).transfer.state, 'pending');
  assert.equal(await (await fetch(`${s.url}/files/${fb}`, { headers: s.headers })).text(), 'BBB');
  assert.equal((await fetch(`${s.url}/files/${fb}/received`, { method: 'POST', headers: s.headers })).status, 200);
  states = await transfers();
  assert.equal(states.find((d: any) => d.id === a.id).transfer.state, 'received');
  assert.equal(states.find((d: any) => d.id === b.id).transfer.state, 'received');
  assert.ok((await s.devices()).every((d: any) => d.transfer.state === 'received'));
  const ambiguous = await fetch(`${s.url}/files`, { method: 'POST', headers: s.headers, body: '' });
  assert.equal((await ambiguous.json()).error.code, 'DEVICE_REQUIRED');
});

test('disconnect during journal append cannot dispatch onto a replacement connection', async t => {
  const memory = new MemoryOperationJournal();
  let markStarted!: () => void; let releaseStart!: () => void;
  const started = new Promise<void>(resolve => { markStarted = resolve; });
  const release = new Promise<void>(resolve => { releaseStart = resolve; });
  let fenced = true;
  const journal: OperationJournal = { read: q => memory.read(q), append: async row => {
    if (fenced && row.status === 'started') { fenced = false; markStarted(); await release; }
    await memory.append(row);
  } };
  const s = await setup(t, 1000, journal); const a = await s.connect(); const b = await s.connect(); answer(b.phone, 'B');
  const oldConnectionId = (await s.devices()).find((d: any) => d.id === a.id).connectionId;
  const first = s.rpc('tap', { x: 1, y: 2 }, { deviceId: a.id }); await started;
  const closed = once(a.phone, 'close'); a.phone.close(); await closed;
  await s.poll(async () => !(await s.devices()).find((d: any) => d.id === a.id).connected);
  const replacement = new WebSocket(s.url.replace('http', 'ws') + '/device', { headers: s.headers });
  await once(replacement, 'open'); const rejected = once(replacement, 'close');
  replacement.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId: a.id, device: 'Replacement', readOnly: false, capabilities: ['control_lease'] }));
  assert.equal((await rejected)[0], 1008);
  assert.deepEqual((await s.rpc('state', {}, { deviceId: b.id })).body.result, { phone: 'B' });
  releaseStart(); assert.equal((await first).body.error.code, 'NO_DEVICE');
  const again = await s.connect(a.id); answer(again.phone, 'A2');
  assert.notEqual((await s.devices()).find((d: any) => d.id === a.id).connectionId, oldConnectionId);
  assert.deepEqual((await s.rpc('state', {}, { deviceId: a.id })).body.result, { phone: 'A2' });
  assert.equal((await memory.read({ method: 'tap' })).operations[0]!.outcome, 'not_dispatched');
});

test('revoked control retains attribution and an uncertain mutation outcome', async t => {
  const s = await setup(t); const a = await s.connect(); const controlId = randomUUID();
  a.phone.on('message', bytes => {
    const r = JSON.parse(bytes.toString());
    a.phone.send(JSON.stringify({ id: r.id, error: { code: 'CONTROL_EXPIRED', message: 'Control revoked during operation.' } }));
  });
  assert.equal((await s.rpc('tap', { x: 1, y: 2 }, { deviceId: a.id, controlId })).body.error.code, 'CONTROL_EXPIRED');
  const row = (await s.journal.read()).operations[0]!;
  assert.equal(row.errorCode, 'CONTROL_EXPIRED'); assert.equal(row.controlId, controlId); assert.equal(row.deviceId, a.id);
  assert.equal(row.outcome, 'unknown'); assert.equal(row.status, 'uncertain');
});

test('a legacy replacement rejects commands and uploads pinned to its prior generation', async t => {
  const s = await setup(t); const a = await s.connect(randomUUID(), 1);
  const connectionId = (await s.devices())[0].connectionId;
  const closed = once(a.phone, 'close'); a.phone.close(); await closed;
  await s.poll(async () => !(await s.devices())[0].connected);
  const b = await s.connect(randomUUID(), 1); let dispatched = 0;
  b.phone.on('message', () => dispatched++);
  const stale = await s.rpc('state', {}, { deviceId: 'legacy', connectionId });
  assert.equal(stale.body.error.code, 'CONTROL_EXPIRED');
  const unqualified = await s.rpc('state', {}, { connectionId });
  assert.equal(unqualified.body.error.code, 'CONTROL_EXPIRED');
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-generation-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'fixture.txt'); await writeFile(path, 'abc');
  await assert.rejects(sendLocalFile(new URL(s.url), s.headers.Authorization.slice(7), path, { deviceId: 'legacy', connectionId }), (error: unknown) => error instanceof BridgeError && error.code === 'CONTROL_EXPIRED' && error.status === 409);
  assert.equal(dispatched, 0);
  assert.equal((await s.devices())[0].transfer, undefined);
  assert.ok((await s.journal.read()).operations.every(r => r.outcome === 'not_dispatched'));
});

test('control acquisition pinned to an old generation is rejected before dispatch', async t => {
  const s = await setup(t); const a = await s.connect();
  const connectionId = (await s.devices())[0].connectionId;
  const closed = once(a.phone, 'close'); a.phone.close(); await closed;
  await s.poll(async () => !(await s.devices())[0].connected);
  const b = await s.connect(a.id); let dispatched = 0;
  b.phone.on('message', () => dispatched++);
  const controlId = randomUUID();
  const reply = await s.rpc('acquire_control', { controlId }, { deviceId: a.id, connectionId });
  assert.equal(reply.body.error.code, 'CONTROL_EXPIRED'); assert.equal(dispatched, 0);
  const row = (await s.journal.read()).operations[0]!;
  assert.equal(row.outcome, 'not_dispatched'); assert.equal(row.controlId, controlId);
  assert.equal(row.errorCode, 'CONTROL_EXPIRED');
});

test('v2 status updates consent and control ownership while preserving a pending command', async t => {
  const s = await setup(t); const a = await s.connect();
  const incoming = once(a.phone, 'message'); const pending = s.rpc('state', {}, { deviceId: a.id });
  const request = JSON.parse((await incoming)[0].toString());
  a.phone.send(JSON.stringify({ type: 'status', readOnly: true, controlling: true, controlOwnerName: 'Owner computer' }));
  await s.poll(async () => (await s.devices())[0].readOnly === true);
  let device = (await s.devices())[0];
  assert.equal(device.connected, true); assert.equal(device.busy, true);
  assert.equal(device.controlling, true); assert.equal(device.controlOwnerName, 'Owner computer');
  a.phone.send(JSON.stringify({ id: request.id, result: { updated: true } }));
  assert.deepEqual((await pending).body.result, { updated: true });
  a.phone.send(JSON.stringify({ type: 'status', readOnly: false, controlling: false, controlOwnerName: '' }));
  await s.poll(async () => (await s.devices())[0].readOnly === false);
  device = (await s.devices())[0]; assert.equal(device.controlling, false); assert.equal(device.controlOwnerName, '');
});

test('legacy connections reject unsolicited v2 status messages', async t => {
  const s = await setup(t); const a = await s.connect(randomUUID(), 1);
  const closed = once(a.phone, 'close');
  a.phone.send(JSON.stringify({ type: 'status', readOnly: true, controlling: false, controlOwnerName: '' }));
  assert.equal((await closed)[0], 1008);
});
