import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AgentClient, AgentError, checkCondition, conditionSchema, observeCondition } from '../src/agent-client.js';

async function fixture(t: TestContext) {
  const requests: Record<string, any>[] = [];
  let connectionId = 'connection-1'; let connected = true; let expire = false;
  let devices = ['phone-a']; let observations = 0; let switchOnAcquire = false; let switchOnState = false; let fileError = 'CONTROL_EXPIRED';
  let queued = false; let waitingState = 'queued';
  let stateErrorCodes: string[] = []; let persistentStateError: string | undefined;
  let acquireDelay = 0; let receivedAcquire!: () => void;
  const acquireReceived = new Promise<void>(resolve => { receivedAcquire = resolve; });
  const service = http.createServer(async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.url === '/devices') {
      res.end(JSON.stringify({ devices: devices.map(id => ({ id, name: id, connectionId, connected, protocol: 2, capabilities: ['control_lease', 'element_actions', ...(queued ? ['control_queue'] : [])] })) })); return;
    }
    if (req.url?.startsWith('/control-events?')) {
      const query = new URL(req.url, 'http://localhost').searchParams;
      requests.push({ method: 'control_wait' });
      res.end(JSON.stringify({ deviceId: query.get('deviceId'), connectionId, controlId: query.get('controlId'), state: waitingState, ...(waitingState === 'queued' ? { position: 1, ownerName: 'Other computer' } : {}) })); return;
    }
    let raw = ''; for await (const chunk of req) raw += chunk;
    if (req.url?.startsWith('/files')) {
      requests.push({ method: 'file_upload' });
      res.statusCode = 409;
      res.end(JSON.stringify({ error: { code: fileError, message: 'File outcome unavailable' } })); return;
    }
    const command = JSON.parse(raw); requests.push(command);
    if (switchOnAcquire && command.method === 'acquire_control') connectionId = 'connection-2';
    if (command.connectionId && command.connectionId !== connectionId) { res.statusCode = 409; res.end(JSON.stringify({ error: { code: 'CONTROL_EXPIRED', message: 'Connection changed before dispatch' } })); return; }
    if (expire && command.controlId) { res.end(JSON.stringify({ error: { code: 'CONTROL_EXPIRED', message: 'Expired' } })); return; }
    if (command.method === 'acquire_control') { receivedAcquire(); if (acquireDelay) await new Promise(resolve => setTimeout(resolve, acquireDelay)); }
    if (queued && command.method === 'acquire_control') {
      res.end(JSON.stringify({ result: { state: 'queued', position: 1, ownerName: 'Other computer' } })); return;
    }
    if (command.method === 'state') {
      observations++;
      if (switchOnState && observations === 1) connectionId = 'connection-2';
      const code = stateErrorCodes.shift() ?? persistentStateError;
      if (code) { res.end(JSON.stringify({ error: { code, message: code === 'WINDOW_UNSAFE' ? 'Cannot verify the active window.' : 'No accessible window during the app transition.', details: { transition: 'app_launch', targetPackage: 'dev.example.app' } } })); return; }
      res.end(JSON.stringify({ result: { packageName: 'dev.example.app', snapshotId: `s-${observations}`, truncated: false,
        nodes: [{ id: `s-${observations}:1`, resourceId: 'app:id/send', text: observations >= 2 ? 'Ready' : 'Loading', description: 'Send' }] } })); return;
    }
    res.end(JSON.stringify({ result: { ok: true } }));
  });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  t.after(() => new Promise<void>(resolve => { service.closeAllConnections(); service.close(() => resolve()); }));
  const address = service.address(); assert(address && typeof address === 'object');
  const url = new URL(`http://127.0.0.1:${address.port}`);
  const client = new AgentClient(url, 'x'.repeat(32));
  return { client, url, requests, reconnect: () => { connectionId = 'connection-2'; }, offline: () => { connected = false; },
    reconnectDuringAcquire: () => { switchOnAcquire = true; }, reconnectDuringWait: () => { switchOnState = true; },
    fileError: (code: string) => { fileError = code; },
    stateErrors: (...codes: string[]) => { stateErrorCodes = [...codes]; }, stateError: (code: string) => { persistentStateError = code; },
    queue: () => { queued = true; }, grant: () => { waitingState = 'active'; },
    delayAcquire: (ms: number) => { acquireDelay = ms; }, acquireReceived,
    expire: () => { expire = true; }, multiple: () => { devices = ['phone-a', 'phone-b']; }, observations: () => observations };
}

test('explicit task handle stays bound to a phone and cannot be redirected by a caller', async t => {
  const f = await fixture(t);
  const task = await f.client.acquire('phone-a'); const taskHandle = task.taskHandle as string;
  await assert.rejects(f.client.command('tap', { x: 1, y: 2 }, { taskHandle, deviceId: 'phone-b' }), (e: AgentError) => e.code === 'TARGET_MISMATCH');
  assert.equal(f.requests.length, 1);
  await f.client.command('state', {}, { taskHandle });
  assert.equal(f.requests[1]!.deviceId, 'phone-a');
  assert.equal(f.requests[1]!.controlId, f.requests[0]!.params.controlId);
  await f.client.release(taskHandle);
  await assert.rejects(f.client.command('state', {}, { taskHandle }), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  assert.equal(f.requests.length, 3);
});

test('expired handles are terminal; actions and acquisitions are never automatically retried', async t => {
  const f = await fixture(t); const task = await f.client.acquire('phone-a'); f.expire();
  await assert.rejects(f.client.command('tap', { x: 1, y: 2 }, task), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  await assert.rejects(f.client.command('tap', { x: 1, y: 2 }, task), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  assert.equal(f.requests.filter(r => r.method === 'acquire_control').length, 1);
  assert.equal(f.requests.filter(r => r.method === 'tap').length, 1);
});

test('a reconnect with the same device ID does not revive a previous task', async t => {
  const f = await fixture(t); const task = await f.client.acquire('phone-a'); f.reconnect();
  await assert.rejects(f.client.command('state', {}, task), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  assert.equal(f.requests.length, 1);
});

test('one running client follows a changed desktop endpoint, expires the old connection handle and never replays its action', async t => {
  const a = await fixture(t), b = await fixture(t); b.reconnect();
  let endpoint = a.url;
  const client = new AgentClient(new URL(a.url), 'x'.repeat(32), async () => endpoint);
  const previous = await client.acquire('phone-a');
  endpoint = b.url;
  await assert.rejects(client.command('tap', { x: 1, y: 2 }, previous), (error: AgentError) => error.code === 'CONTROL_EXPIRED');
  assert.equal(a.requests.filter(item => item.method === 'tap').length, 0);
  assert.equal(b.requests.filter(item => item.method === 'tap').length, 0);
  const current = await client.acquire('phone-a'); await client.command('state', {}, current); await client.release(current.taskHandle as string);
  assert.deepEqual(b.requests.map(item => item.method), ['acquire_control', 'state', 'release_control']);
});

test('multiple phones require explicit selection; independent handles target each phone', async t => {
  const f = await fixture(t); f.multiple();
  await assert.rejects(f.client.acquire(), (e: AgentError) => e.code === 'DEVICE_REQUIRED');
  const a = await f.client.acquire('phone-a'); const b = await f.client.acquire('phone-b');
  await Promise.all([f.client.command('state', {}, a), f.client.command('state', {}, b)]);
  assert.deepEqual(f.requests.filter(r => r.method === 'state').map(r => r.deviceId).sort(), ['phone-a', 'phone-b']);
});

test('wait uses only observations, pins its target and returns matching fresh evidence', async t => {
  const f = await fixture(t);
  const result = await observeCondition(f.client, conditionSchema.parse({ text: 'Ready', resourceId: 'app:id/send' }), {}, 2000);
  assert.equal(result.matched, true); assert.equal(f.observations(), 2);
  assert(f.requests.every(r => r.method === 'state' && r.deviceId === 'phone-a'));
  assert.equal((result.evidence as any).nodeId, 's-2:1');
});

test('assert observes once and a bounded wait returns its last observed state', async t => {
  const f = await fixture(t); const condition = conditionSchema.parse({ text: 'Never' });
  const result = await observeCondition(f.client, condition, { deviceId: 'phone-a' }, 0);
  assert.equal(result.matched, false); assert.equal(result.code, 'ASSERTION_FAILED'); assert.equal(f.observations(), 1);
  const timed = await observeCondition(f.client, condition, { deviceId: 'phone-a' }, 80);
  assert.equal(timed.code, 'WAIT_TIMEOUT'); assert(timed.state);
  assert(f.requests.every(r => r.method === 'state'));
});

test('wait retries only read-only NO_WINDOW during an app transition and returns the later matching state', async t => {
  const f = await fixture(t); f.stateErrors('NO_WINDOW');
  const task = await f.client.acquire('phone-a');
  const result = await observeCondition(f.client, conditionSchema.parse({ packageName: 'dev.example.app' }), task, 1500);
  assert.equal(result.matched, true); assert.equal(f.observations(), 2);
  assert.deepEqual(f.requests.map(request => request.method), ['acquire_control', 'state', 'state']);
  assert(f.requests.every(request => request.deviceId === 'phone-a' && request.connectionId === 'connection-1'));
  assert(f.requests.slice(1).every(request => request.controlId === f.requests[0]!.params.controlId));
  await f.client.release(task.taskHandle as string);
});

test('assert returns the original NO_WINDOW immediately without retrying', async t => {
  const f = await fixture(t); f.stateErrors('NO_WINDOW');
  await assert.rejects(observeCondition(f.client, conditionSchema.parse({ packageName: 'dev.example.app' }), { deviceId: 'phone-a' }, 0),
    (error: AgentError) => error.code === 'NO_WINDOW' && error.message === 'No accessible window during the app transition.' && error.details?.transition === 'app_launch');
  assert.equal(f.observations(), 1); assert.deepEqual(f.requests.map(request => request.method), ['state']);
});

test('wait crosses an unmatched frame and WINDOW_UNSAFE transition without losing its workflow handle', async t => {
  const f = await fixture(t); f.stateErrors('', 'WINDOW_UNSAFE');
  const task = await f.client.acquire('phone-a');
  const result = await observeCondition(f.client, conditionSchema.parse({ text: 'Ready' }), task, 1500);
  assert.equal(result.matched, true); assert.equal(f.observations(), 3);
  assert.equal((result.state as any).snapshotId, 's-3');
  assert.deepEqual(f.requests.map(request => request.method), ['acquire_control', 'state', 'state', 'state']);
  assert(f.requests.slice(1).every(request => request.controlId === f.requests[0]!.params.controlId && request.deviceId === 'phone-a' && request.connectionId === 'connection-1'));
  await f.client.release(task.taskHandle as string);
});

test('assert returns WINDOW_UNSAFE immediately instead of waiting through it', async t => {
  const f = await fixture(t); f.stateErrors('WINDOW_UNSAFE');
  await assert.rejects(observeCondition(f.client, conditionSchema.parse({ packageName: 'dev.example.app' }), { deviceId: 'phone-a' }, 0),
    (error: AgentError) => error.code === 'WINDOW_UNSAFE' && error.message === 'Cannot verify the active window.');
  assert.equal(f.observations(), 1);
});

test('persistent WINDOW_UNSAFE times out with its actual last error code and diagnostics', async t => {
  const f = await fixture(t); f.stateError('WINDOW_UNSAFE');
  const result = await observeCondition(f.client, conditionSchema.parse({ packageName: 'dev.example.app' }), { deviceId: 'phone-a' }, 260);
  assert.equal(result.code, 'WAIT_TIMEOUT'); assert.equal(result.matched, false);
  assert.deepEqual(result.lastError, { code: 'WINDOW_UNSAFE', message: 'Cannot verify the active window.', outcome: 'device_reported_error', details: { transition: 'app_launch', targetPackage: 'dev.example.app' } });
  assert.match(result.message as string, /WINDOW_UNSAFE/); assert.doesNotMatch(result.message as string, /NO_WINDOW/);
  assert.equal(result.state, undefined); assert.equal(result.evidence, undefined);
  assert(f.requests.every(request => request.method === 'state'));
});

test('wait timeout retains the final NO_WINDOW diagnosis without reporting stale screen evidence', async t => {
  const f = await fixture(t); f.stateError('NO_WINDOW');
  const result = await observeCondition(f.client, conditionSchema.parse({ packageName: 'dev.example.app' }), { deviceId: 'phone-a' }, 260);
  assert.equal(result.matched, false); assert.equal(result.code, 'WAIT_TIMEOUT');
  assert.deepEqual(result.lastError, { code: 'NO_WINDOW', message: 'No accessible window during the app transition.', outcome: 'device_reported_error', details: { transition: 'app_launch', targetPackage: 'dev.example.app' } });
  assert.equal(result.state, undefined); assert.equal(result.evidence, undefined);
  assert.match(result.message as string, /NO_WINDOW/); assert(f.requests.every(request => request.method === 'state'));
});

test('a later real observation clears an earlier transitional NO_WINDOW diagnosis', async t => {
  const f = await fixture(t); f.stateErrors('NO_WINDOW');
  const result = await observeCondition(f.client, conditionSchema.parse({ text: 'Not present' }), { deviceId: 'phone-a' }, 260);
  assert.equal(result.code, 'WAIT_TIMEOUT'); assert.equal(result.lastError, undefined);
  assert.equal((result.state as any).packageName, 'dev.example.app');
});

for (const code of ['NO_DEVICE', 'CONTROL_EXPIRED', 'DEVICE_LOCKED', 'READ_ONLY', 'PACKAGE_BLOCKED', 'NOTIFICATIONS_DISABLED', 'OWNER_AUTHORIZATION', 'ACCESSIBILITY_DISABLED', 'WINDOW_OBSCURED']) {
  test(`wait does not retry non-transient ${code}`, async t => {
    const f = await fixture(t); f.stateErrors(code);
    await assert.rejects(observeCondition(f.client, conditionSchema.parse({ packageName: 'dev.example.app' }), { deviceId: 'phone-a' }, 1000), (error: AgentError) => error.code === code);
    assert.equal(f.observations(), 1); assert.deepEqual(f.requests.map(request => request.method), ['state']);
  });
}

test('literal conditions match the same node; truncated observations cannot prove absence', () => {
  const state = { packageName: 'p', truncated: false, nodes: [{ text: 'Ready', resourceId: 'first' }, { text: 'Other', resourceId: 'second' }] };
  assert.equal(checkCondition(state, conditionSchema.parse({ text: 'Ready', resourceId: 'second' })).matched, false);
  assert.equal(checkCondition(state, conditionSchema.parse({ packageName: 'p' })).matched, true);
  assert.equal(checkCondition(state, conditionSchema.parse({ text: 'Missing', absent: true })).matched, true);
  assert.equal(checkCondition({ ...state, truncated: true }, conditionSchema.parse({ text: 'Missing', absent: true })).matched, false);
  assert.throws(() => conditionSchema.parse({ absent: true }));
});

test('acquisition carries an atomic connection fence and does not create an orphan handle', async t => {
  const f = await fixture(t); f.reconnectDuringAcquire();
  await assert.rejects(f.client.acquire('phone-a'), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0]!.connectionId, 'connection-1');
});

test('wait does not follow a replacement connection in a legacy slot', async t => {
  const f = await fixture(t); f.reconnectDuringWait();
  await assert.rejects(observeCondition(f.client, conditionSchema.parse({ text: 'Ready' }), {}, 2000), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  assert.equal(f.observations(), 1);
});

test('expired file uploads terminate the handle and cannot upload again', async t => {
  const f = await fixture(t); const task = await f.client.acquire('phone-a');
  const directory = await mkdtemp(join(tmpdir(), 'phonebridge-agent-file-'));
  t.after(async () => { assert.equal(dirname(resolve(directory)), resolve(tmpdir())); assert(directory.includes('phonebridge-agent-file-')); await rm(directory, { recursive: true, force: true }); });
  const path = join(directory, 'selected.txt'); await writeFile(path, 'fixture');
  await assert.rejects(f.client.sendFile(path, task), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  await assert.rejects(f.client.sendFile(path, task), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
  assert.equal(f.requests.filter(r => r.method === 'file_upload').length, 1);
});

for (const code of ['LOG_WRITE_FAILED', 'SEND_FAILED', 'TIMEOUT', 'WINDOW_CHANGED']) {
  test(`file ${code} preserves unknown outcome after consuming an upload`, async t => {
    const f = await fixture(t); f.fileError(code);
    await assert.rejects(f.client.sendFile(fileURLToPath(new URL('../package.json', import.meta.url)), { deviceId: 'phone-a' }), (e: AgentError) => e.code === code && e.outcome === 'unknown');
    assert.equal(f.requests.length, 1);
  });
}

test('real MCP stdin EOF releases acquired control before process exits', async t => {
  const f = await fixture(t);
  const child = spawn(process.execPath, ['--import', 'tsx', 'src/mcp.ts'], {
    cwd: fileURLToPath(new URL('..', import.meta.url)),
    env: { ...process.env, PHONEBRIDGE_URL: f.url.href, PHONEBRIDGE_TOKEN: 'x'.repeat(32) }, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  t.after(() => { if (child.exitCode === null) child.kill(); });
  const pending = new Map<number, (value: any) => void>(); let buffer = '';
  child.stdout.setEncoding('utf8'); child.stdout.on('data', chunk => {
    buffer += chunk;
    let newline: number;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
      if (!line) continue; const message = JSON.parse(line); if (typeof message.id === 'number') pending.get(message.id)?.(message);
    }
  });
  let sequence = 0;
  const call = (method: string, params: unknown) => new Promise<any>((resolveReply, reject) => {
    const id = ++sequence; const timer = setTimeout(() => reject(new Error('MCP fixture request timed out')), 15000);
    pending.set(id, value => { clearTimeout(timer); pending.delete(id); resolveReply(value); });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  await call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'cleanup-fixture', version: '1' } });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const acquired = await call('tools/call', { name: 'phone_acquire_control', arguments: { deviceId: 'phone-a' } });
  assert.equal(acquired.result.isError, undefined);
  const exited = once(child, 'exit'); child.stdin.end();
  const timer = setTimeout(() => child.kill(), 10000);
  try { assert.equal((await exited)[0], 0); } finally { clearTimeout(timer); }
  assert.deepEqual(f.requests.map(r => r.method), ['acquire_control', 'release_control']);
});

test('queued handles cannot act until a phone grant notification, and cancellation works', async t => {
  const f = await fixture(t); f.queue();
  const task = await f.client.acquire('phone-a'); assert.equal(task.state, 'queued');
  assert.equal(f.requests[0]!.params.queue, true);
  await assert.rejects(f.client.command('tap', { x: 1, y: 2 }, task), (e: AgentError) => e.code === 'CONTROL_QUEUED');
  await assert.rejects(f.client.renew(task.taskHandle as string), (e: AgentError) => e.code === 'CONTROL_QUEUED');
  assert.equal(f.requests.length, 1);
  const waiting = await f.client.waitForControl(task.taskHandle as string, 0);
  assert.equal(waiting.state, 'queued'); assert.equal(waiting.position, 1);
  f.grant();
  assert.equal((await f.client.waitForControl(task.taskHandle as string, 1000)).state, 'active');
  await f.client.command('state', {}, task);
  await f.client.release(task.taskHandle as string);
  assert.deepEqual(f.requests.map(r => r.method), ['acquire_control', 'control_wait', 'control_wait', 'state', 'release_control']);
  const cancelled = await f.client.acquire('phone-a'); await f.client.release(cancelled.taskHandle as string);
  await assert.rejects(f.client.waitForControl(cancelled.taskHandle as string, 0), (e: AgentError) => e.code === 'CONTROL_EXPIRED');
});

test('shutdown cancels a queued acquisition whose reply arrives after closing starts', async t => {
  const f = await fixture(t); f.queue(); f.delayAcquire(100);
  const acquisition = f.client.acquire('phone-a');
  const rejected = assert.rejects(acquisition, (e: AgentError) => e.code === 'CLIENT_CLOSED');
  await f.acquireReceived;
  await f.client.close(); await rejected;
  assert.deepEqual(f.requests.map(r => r.method), ['acquire_control', 'release_control']);
  await assert.rejects(f.client.acquire('phone-a'), (e: AgentError) => e.code === 'CLIENT_CLOSED');
});
