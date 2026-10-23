import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { PhoneHub } from '../src/hub.js';
import { MemoryOperationJournal, type OperationJournal } from '../src/operation-journal.js';

async function setup(t: TestContext, journal: OperationJournal = new MemoryOperationJournal()) {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal, timeoutMs: 3000 }); const url = await hub.start();
  let closed = false; const close = async () => { if (!closed) { closed = true; await hub.close(); } }; t.after(close);
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const poll = async (check: () => Promise<boolean> | boolean) => {
    for (let n = 0; n < 200; n++) { if (await check()) return; await delay(5); }
    throw new Error('Expected control notification state did not arrive');
  };
  const devices = async () => (await (await fetch(`${url}/devices`, { headers })).json()).devices;
  const connect = async (deviceId = randomUUID(), protocol = 2, capabilities = ['control_lease', 'control_queue']) => {
    const phone = new WebSocket(url.replace('http', 'ws') + '/device', { headers }); await once(phone, 'open');
    phone.send(JSON.stringify(protocol === 1 ? { type: 'hello', protocol: 1 } : { type: 'hello', protocol: 2, deviceId, device: 'Queue test phone', readOnly: false, capabilities }));
    const id = protocol === 1 ? 'legacy' : deviceId;
    await poll(async () => (await devices()).some((d: any) => d.id === id && d.connected));
    const connectionId = (await devices()).find((d: any) => d.id === id).connectionId;
    return { phone, deviceId: id, connectionId };
  };
  const rpc = async (method: string, params: Record<string, unknown>, target: { deviceId: string; connectionId: string }) => {
    const response = await fetch(`${url}/rpc`, { method: 'POST', headers, body: JSON.stringify({ method, params, deviceId: target.deviceId, connectionId: target.connectionId }) });
    return { status: response.status, body: await response.json() };
  };
  const watch = async (target: { deviceId: string; connectionId: string }, controlId: string, waitMs = 1000, signal?: AbortSignal) => {
    const query = new URLSearchParams({ deviceId: target.deviceId, connectionId: target.connectionId, controlId, waitMs: String(waitMs) });
    const response = await fetch(`${url}/control-events?${query}`, { headers, signal });
    return { status: response.status, body: await response.json() };
  };
  const waiterCount = () => (hub as unknown as { controlWaiterCount: number }).controlWaiterCount;
  return { hub, url, headers, journal, close, poll, devices, connect, rpc, watch, waiterCount };
}
const reply = (phone: WebSocket, request: any, result: Record<string, unknown>) => phone.send(JSON.stringify({ id: request.id, result }));
const event = (phone: WebSocket, controlId: string, state: string, extra = {}) => phone.send(JSON.stringify({ type: 'control_event', controlId, state, ...extra }));

test('queued AI receives its grant after release without polling or blocking a screen command', async t => {
  const s = await setup(t); const phone = await s.connect(); const a = randomUUID(); const b = randomUUID();
  let owner = ''; let queued = ''; let statuses = 0; let screen: any;
  phone.phone.on('message', bytes => {
    const r = JSON.parse(bytes.toString());
    if (r.method === 'state') { screen = r; return; }
    if (r.method === 'acquire_control') {
      if (!owner) { owner = r.params.controlId; reply(phone.phone, r, { state: 'active' }); }
      else { queued = r.params.controlId; event(phone.phone, queued, 'queued', { position: 1, ownerName: 'PRIVATE_OWNER' }); reply(phone.phone, r, { state: 'queued', position: 1, ownerName: 'PRIVATE_OWNER' }); }
    } else if (r.method === 'control_status') { statuses++; reply(phone.phone, r, { state: 'queued', position: 1, ownerName: 'PRIVATE_OWNER' }); }
    else if (r.method === 'release_control') {
      event(phone.phone, owner, 'released'); owner = queued; reply(phone.phone, r, { released: true });
    }
  });
  assert.equal((await s.rpc('acquire_control', { controlId: a, queue: true }, phone)).body.result.state, 'active');
  const screenCall = s.rpc('state', {}, phone); await s.poll(() => !!screen);
  assert.equal((await s.rpc('acquire_control', { controlId: b, queue: true }, phone)).body.result.state, 'queued');
  const waiting = s.watch(phone, b); await s.poll(() => statuses === 1 && s.waiterCount() === 1);
  // Management remains available while the screen request is still pending.
  assert.equal((await s.rpc('release_control', { controlId: a }, phone)).status, 200);
  // The fake native executor grants only after its previous screen operation settles.
  reply(phone.phone, screen, { nodes: [] }); event(phone.phone, b, 'active');
  const granted = await waiting; assert.equal(granted.body.state, 'active');
  assert.equal(granted.body.controlId, b); assert.equal(granted.body.deviceId, phone.deviceId); assert.equal(granted.body.connectionId, phone.connectionId);
  assert.equal((await screenCall).status, 200);
  assert.equal(statuses, 1); assert.equal(s.waiterCount(), 0);
  const rows = (await s.journal.read()).operations.filter(r => r.recordKind === 'control_event');
  assert.ok(rows.some(r => r.controlId === b && r.controlEvent === 'active'));
  assert.ok(rows.some(r => r.controlId === a && r.controlEvent === 'released'));
  assert.ok(rows.every(r => r.deviceId === phone.deviceId && r.connectionId === phone.connectionId && r.outcome === 'device_reported_success'));
  assert.equal(JSON.stringify(rows).includes('PRIVATE_OWNER'), false);
});

test('grant arriving before the queued initial reply cannot be lost', async t => {
  const s = await setup(t); const phone = await s.connect(); const controlId = randomUUID();
  phone.phone.on('message', bytes => {
    const r = JSON.parse(bytes.toString()); assert.equal(r.method, 'control_status');
    event(phone.phone, controlId, 'active'); reply(phone.phone, r, { state: 'queued', position: 1 });
  });
  assert.equal((await s.watch(phone, controlId)).body.state, 'active'); assert.equal(s.waiterCount(), 0);
});

test('a received grant awaiting durable audit beats an older queued reply even for an immediate check', async t => {
  const memory = new MemoryOperationJournal();
  let markEvent!: () => void; let releaseEvent!: () => void;
  const eventStarted = new Promise<void>(resolve => { markEvent = resolve; });
  const permitEvent = new Promise<void>(resolve => { releaseEvent = resolve; });
  t.after(() => releaseEvent());
  const journal: OperationJournal = { read: query => memory.read(query), append: async row => {
    if (row.recordKind === 'control_event') { markEvent(); await permitEvent; }
    await memory.append(row);
  } };
  const s = await setup(t, journal); const phone = await s.connect(); const controlId = randomUUID();
  phone.phone.on('message', bytes => {
    const r = JSON.parse(bytes.toString()); event(phone.phone, controlId, 'active');
    reply(phone.phone, r, { state: 'queued', controlId, position: 1, expiresInMs: 120000 });
  });
  let settled = false;
  const waiting = s.watch(phone, controlId, 0).then(result => { settled = true; return result; });
  await eventStarted;
  await s.poll(async () => (await memory.read({ method: 'control_status' })).operations.some(row => row.status === 'completed'));
  assert.equal(settled, false); assert.equal(s.waiterCount(), 1);
  releaseEvent(); assert.equal((await waiting).body.state, 'active'); assert.equal(s.waiterCount(), 0);
});

test('active status returns immediately; queued timeout returns its last status and cleans up', async t => {
  const s = await setup(t); const phone = await s.connect(); let state = 'active'; let statuses = 0;
  phone.phone.on('message', bytes => {
    const r = JSON.parse(bytes.toString()); statuses++; reply(phone.phone, r, state === 'active' ? { state, controlId: r.params.controlId, expiresInMs: 60000 } : { state, position: 2, ownerName: 'Other computer', controlId: r.params.controlId, expiresInMs: 120000 });
  });
  assert.equal((await s.watch(phone, randomUUID(), 25000)).body.state, 'active');
  state = 'queued'; const queued = await s.watch(phone, randomUUID(), 30);
  assert.equal(queued.body.state, 'queued'); assert.equal(queued.body.position, 2);
  assert.equal((await s.watch(phone, randomUUID(), 0)).body.state, 'queued');
  assert.equal(statuses, 3); assert.equal(s.waiterCount(), 0);
});

test('an active status cannot bypass an earlier grant whose event audit is still pending', async t => {
  const memory = new MemoryOperationJournal(); let markEvent!: () => void; let releaseEvent!: () => void;
  const eventStarted = new Promise<void>(resolve => { markEvent = resolve; });
  const permitEvent = new Promise<void>(resolve => { releaseEvent = resolve; }); t.after(() => releaseEvent());
  const journal: OperationJournal = { read: query => memory.read(query), append: async row => {
    if (row.recordKind === 'control_event') { markEvent(); await permitEvent; }
    await memory.append(row);
  } };
  const s = await setup(t, journal); const a = await s.connect(); const controlId = randomUUID();
  event(a.phone, controlId, 'active'); await eventStarted;
  a.phone.on('message', bytes => reply(a.phone, JSON.parse(bytes.toString()), { state: 'active', controlId, expiresInMs: 60000 }));
  let settled = false; const waiting = s.watch(a, controlId).then(result => { settled = true; return result; });
  await s.poll(async () => (await memory.read({ method: 'control_status' })).operations.some(row => row.status === 'completed'));
  assert.equal(settled, false); releaseEvent(); assert.equal((await waiting).body.state, 'active');
});

test('HTTP cancellation removes only its waiter and never releases the queued task', async t => {
  const s = await setup(t); const phone = await s.connect(); let statuses = 0; let released = 0;
  phone.phone.on('message', bytes => {
    const r = JSON.parse(bytes.toString());
    if (r.method === 'control_status') { statuses++; reply(phone.phone, r, { state: 'queued', position: 1 }); }
    else { if (r.method === 'release_control') released++; reply(phone.phone, r, {}); }
  });
  const abort = new AbortController(); const waiting = s.watch(phone, randomUUID(), 25000, abort.signal);
  const rejected = assert.rejects(waiting, { name: 'AbortError' });
  await s.poll(() => statuses === 1 && s.waiterCount() === 1); abort.abort(); await rejected;
  await s.poll(() => s.waiterCount() === 0); assert.equal(released, 0);
  assert.equal((await s.rpc('state', {}, phone)).status, 200);
});

test('matching control IDs on another phone never wake this phone waiter', async t => {
  const s = await setup(t); const a = await s.connect(); const b = await s.connect(); const controlId = randomUUID();
  a.phone.on('message', bytes => reply(a.phone, JSON.parse(bytes.toString()), { state: 'queued', position: 1 }));
  let settled = false; const waiting = s.watch(a, controlId).then(result => { settled = true; return result; });
  await s.poll(() => s.waiterCount() === 1);
  event(b.phone, controlId, 'active');
  await s.poll(async () => (await s.journal.read()).operations.some(r => r.deviceId === b.deviceId && r.recordKind === 'control_event'));
  assert.equal(settled, false);
  event(a.phone, controlId, 'active'); assert.equal((await waiting).body.state, 'active');
});

test('disconnect rejects the wait and a replacement cannot accept an old generation', async t => {
  const s = await setup(t); const a = await s.connect();
  a.phone.on('message', bytes => reply(a.phone, JSON.parse(bytes.toString()), { state: 'queued', position: 1 }));
  const waiting = s.watch(a, randomUUID(), 25000); await s.poll(() => s.waiterCount() === 1);
  const closed = once(a.phone, 'close'); a.phone.close(); await closed;
  assert.equal((await waiting).body.error.code, 'DISCONNECTED'); assert.equal(s.waiterCount(), 0);
  const replacement = await s.connect(a.deviceId); let dispatched = 0; replacement.phone.on('message', () => dispatched++);
  assert.equal((await s.watch(a, randomUUID())).body.error.code, 'CONTROL_EXPIRED'); assert.equal(dispatched, 0);
});

test('Hub shutdown resolves every open waiter with shutdown and clears capacity', async t => {
  const s = await setup(t); const a = await s.connect();
  a.phone.on('message', bytes => reply(a.phone, JSON.parse(bytes.toString()), { state: 'queued', position: 1 }));
  const waiting = s.watch(a, randomUUID(), 25000); await s.poll(() => s.waiterCount() === 1);
  const result = waiting;
  await s.close(); assert.equal(s.waiterCount(), 0);
  assert.equal((await result).body.error.code, 'SHUTDOWN');
});

test('legacy and phones without control_queue refuse waits and queued acquire without dispatch', async t => {
  const s = await setup(t); const a = await s.connect(randomUUID(), 1); let dispatched = 0;
  a.phone.on('message', () => dispatched++);
  assert.equal((await s.watch(a, randomUUID())).body.error.code, 'UNSUPPORTED');
  assert.equal((await s.rpc('control_status', { controlId: randomUUID() }, a)).body.error.code, 'UNSUPPORTED');
  const b = await s.connect(randomUUID(), 2, ['control_lease']); b.phone.on('message', () => dispatched++);
  assert.equal((await s.rpc('acquire_control', { controlId: randomUUID(), queue: true }, b)).body.error.code, 'UNSUPPORTED');
  assert.equal(dispatched, 0); assert.equal(s.waiterCount(), 0);
});

test('wait endpoint is authenticated, strictly validated and bounded to 64 waiters', async t => {
  const s = await setup(t); const a = await s.connect(); let statuses = 0;
  a.phone.on('message', bytes => { statuses++; reply(a.phone, JSON.parse(bytes.toString()), { state: 'queued', position: 1 }); });
  assert.equal((await fetch(`${s.url}/control-events`)).status, 401);
  const query = new URLSearchParams({ deviceId: a.deviceId, connectionId: a.connectionId, controlId: randomUUID(), waitMs: '0' });
  for (const suffix of ['&waitMs=0', '&unexpected=x']) assert.equal((await fetch(`${s.url}/control-events?${query}${suffix}`, { headers: s.headers })).status, 400);
  for (const value of ['-1', '25001', '1.1', 'NaN', '']) {
    query.set('waitMs', value); assert.equal((await fetch(`${s.url}/control-events?${query}`, { headers: s.headers })).status, 400);
  }
  const aborts = Array.from({ length: 64 }, () => new AbortController());
  const waits = aborts.map(abort => s.watch(a, randomUUID(), 25000, abort.signal).catch(() => undefined));
  await s.poll(() => s.waiterCount() === 64 && statuses === 64);
  const excess = await s.watch(a, randomUUID(), 0); assert.equal(excess.status, 429); assert.equal(excess.body.error.code, 'WAIT_LIMIT');
  for (const abort of aborts) abort.abort(); await Promise.all(waits); await s.poll(() => s.waiterCount() === 0);
});

test('status carries waitingCount and terminal push events preserve sanitized event attribution', async t => {
  const s = await setup(t); const a = await s.connect(); const controlId = randomUUID();
  a.phone.on('message', bytes => reply(a.phone, JSON.parse(bytes.toString()), { state: 'queued', position: 1 }));
  a.phone.send(JSON.stringify({ type: 'status', readOnly: true, controlling: false, controlOwnerName: 'Other computer', waitingCount: 3 }));
  await s.poll(async () => (await s.devices())[0].waitingCount === 3);
  for (const state of ['cancelled', 'expired']) {
    const waiting = s.watch(a, controlId); await s.poll(() => s.waiterCount() === 1);
    event(a.phone, controlId, state); assert.equal((await waiting).body.state, state);
  }
  const rows = (await s.journal.read()).operations.filter(r => r.recordKind === 'control_event');
  assert.deepEqual(rows.map(r => r.controlEvent), ['expired', 'cancelled']);
  assert.ok(rows.every(r => r.controlId === controlId && r.deviceId === a.deviceId && r.connectionId === a.connectionId && Object.keys(r.params).length === 0));
});

test('failed event audit never reports a grant and closes only its phone', async t => {
  const memory = new MemoryOperationJournal();
  const journal: OperationJournal = { read: query => memory.read(query), append: async row => {
    if (row.recordKind === 'control_event') throw new Error('PRIVATE_DISK_ERROR');
    await memory.append(row);
  } };
  const s = await setup(t, journal); const a = await s.connect(); const b = await s.connect(); const controlId = randomUUID();
  a.phone.on('message', bytes => reply(a.phone, JSON.parse(bytes.toString()), { state: 'queued', position: 1 }));
  b.phone.on('message', bytes => reply(b.phone, JSON.parse(bytes.toString()), { nodes: [] }));
  const waiting = s.watch(a, controlId); await s.poll(() => s.waiterCount() === 1);
  const closed = once(a.phone, 'close'); event(a.phone, controlId, 'active');
  const result = await waiting; assert.equal(result.body.error.code, 'LOG_WRITE_FAILED');
  assert.equal(JSON.stringify(result).includes('PRIVATE_DISK_ERROR'), false);
  assert.equal((await closed)[0], 1011); assert.equal(s.waiterCount(), 0);
  assert.equal((await s.rpc('state', {}, b)).status, 200);
});

test('strict unsolicited events reject extra content and never persist it', async t => {
  const s = await setup(t); const a = await s.connect(); const controlId = randomUUID();
  const closed = once(a.phone, 'close');
  event(a.phone, controlId, 'active', { text: 'PRIVATE_SCREEN_TEXT' });
  assert.equal((await closed)[0], 1008);
  assert.equal(JSON.stringify(await s.journal.read()).includes('PRIVATE_SCREEN_TEXT'), false);
});
