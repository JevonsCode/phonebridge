import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, readdir, stat, writeFile, link, symlink, chmod } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync, spawnSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { PhoneHub } from '../src/hub.js';
import { FileOperationJournal, MemoryOperationJournal, operationLogPath, operationParams, type OperationJournal, type OperationRecord } from '../src/operation-journal.js';

async function temporary(t: TestContext) {
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-operation-log-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return { dir, path: join(dir, 'operations.jsonl') };
}
const record = (overrides: Partial<OperationRecord> = {}): OperationRecord => ({ version: 1, requestId: randomUUID(), time: new Date().toISOString(), method: 'tap', params: { x: 1, y: 2 }, status: 'started', outcome: 'unknown', ...overrides });
async function hubSetup(t: TestContext, journal: OperationJournal, timeoutMs = 1000) {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, timeoutMs, journal });
  const url = await hub.start();
  t.after(() => hub.close());
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const rpc = (method: string, params = {}) => fetch(`${url}/rpc`, { method: 'POST', headers, body: JSON.stringify({ method, params }) });
  const connect = async () => {
    const phone = new WebSocket(url.replace('http', 'ws') + '/device', { headers });
    await once(phone, 'open');
    phone.send(JSON.stringify({ type: 'hello', protocol: 1 }));
    for (let n = 0; n < 100; n++) {
      if ((await (await fetch(`${url}/status`, { headers })).json()).connected) return phone;
      await delay(5);
    }
    throw new Error('Phone did not become ready');
  };
  return { hub, url, headers, rpc, connect, token };
}

test('file journal persists across a new process and excludes sensitive payloads', async t => {
  const { path } = await temporary(t);
  const journal = new FileOperationJournal({ path });
  const start = record({ method: 'commit_text', params: { packageName: 'com.example.app', text: 'PRIVATE_TEXT', token: 'PRIVATE_TOKEN', data: 'PRIVATE_IMAGE' } });
  await journal.append(start);
  await journal.append({ ...start, status: 'completed', outcome: 'device_reported_success', durationMs: 25 });
  const disk = await readFile(path, 'utf8');
  for (const secret of ['PRIVATE_TEXT', 'PRIVATE_TOKEN', 'PRIVATE_IMAGE', 'nodeId']) assert.equal(disk.includes(secret), false);
  assert.match(disk, /"textLength":12/);
  const code = `import {FileOperationJournal} from ${JSON.stringify(new URL('../src/operation-journal.ts', import.meta.url).href)}; console.log(JSON.stringify(await new FileOperationJournal({path:process.env.TEST_LOG_PATH}).read()));`;
  const child = spawnSync(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', code], { env: { ...process.env, TEST_LOG_PATH: path }, encoding: 'utf8', timeout: 20000, windowsHide: true });
  assert.equal(child.status, 0, child.stderr);
  const history = JSON.parse(child.stdout);
  assert.equal(history.operations.length, 1);
  assert.equal(history.operations[0].status, 'completed');
  assert.deepEqual(history.operations[0].params, { packageName: 'com.example.app', textLength: 12 });
  assert.equal(history.operations[0].durationMs, 25);
});

test('allowlist retains gesture/action/package metadata and counts Unicode without input text', () => {
  assert.deepEqual(operationParams('set_text', { text: '你好🌍', nodeId: 'screen-private', title: 'SECRET' }), { textLength: 3 });
  assert.deepEqual(operationParams('long_press', { x: 3, y: 4, durationMs: 400, text: 'SECRET' }), { x: 3, y: 4, durationMs: 400 });
  assert.deepEqual(operationParams('swipe', { x1: 1, y1: 2, x2: 3, y2: 4, durationMs: 200 }), { x1: 1, y1: 2, x2: 3, y2: 4, durationMs: 200 });
  assert.deepEqual(operationParams('global_action', { action: 'back', text: 'SECRET' }), { action: 'back' });
  assert.deepEqual(operationParams('state', { screenText: 'SECRET', nodes: [{ text: 'SECRET' }] }), {});
  assert.deepEqual(operationParams('screenshot', { data: 'SECRET' }), {});
});

test('rotation is bounded, serialized across instances, and history filters latest operations', async t => {
  const { path, dir } = await temporary(t);
  const journal = new FileOperationJournal({ path, maxBytes: 1024, backups: 2 });
  const second = new FileOperationJournal({ path, maxBytes: 1024, backups: 2 });
  const rows = Array.from({ length: 20 }, (_, n) => record({ method: n % 2 ? 'tap' : 'state', params: n % 2 ? { x: n, y: 0 } : {} }));
  await Promise.all(rows.map((r, n) => (n % 2 ? journal : second).append(r)));
  const files = await readdir(dir);
  assert.equal(files.length, 3);
  for (const name of files) assert.ok((await stat(join(dir, name))).size <= 1024);
  const history = await new FileOperationJournal({ path, maxBytes: 1024, backups: 2 }).read({ limit: 2, method: 'tap' });
  assert.deepEqual(history.operations.map(r => r.requestId), [rows[19]!.requestId, rows[17]!.requestId]);
  await assert.rejects(journal.read({ limit: 201 }));
  await assert.rejects(journal.read({ limit: 0 }));
});

test('crash trailing fragment retains the prior started event as unknown', async t => {
  const { path } = await temporary(t);
  const journal = new FileOperationJournal({ path });
  const start = record(); await journal.append(start);
  await writeFile(path, '{"version":', { flag: 'a' });
  const history = await new FileOperationJournal({ path }).read();
  assert.equal(history.operations[0]!.requestId, start.requestId);
  assert.equal(history.operations[0]!.status, 'started');
  assert.equal(history.operations[0]!.outcome, 'unknown');
  assert.match(history.warning, /unknown/);
  const next = record(); await new FileOperationJournal({ path }).append(next);
  const repaired = await new FileOperationJournal({ path }).read();
  assert.equal(repaired.operations.length, 2);
  assert.equal(repaired.operations[0]!.requestId, next.requestId);
});

test('journal refuses hardlinks, malformed interior records, and non-private POSIX files', async t => {
  const { dir, path } = await temporary(t);
  const journal = new FileOperationJournal({ path }); await journal.append(record());
  const alias = join(dir, 'alias'); await link(path, alias);
  await assert.rejects(journal.append(record()), /Unsafe journal/);
  await rm(alias);
  await writeFile(path, '{bad}\n' + JSON.stringify(record()) + '\n');
  await assert.rejects(journal.read(), /corrupt/);
  if (process.platform !== 'win32') {
    await chmod(path, 0o644);
    await assert.rejects(journal.read(), /Unsafe journal/);
  }
});

test('journal refuses symlink targets and symlink directories', { skip: process.platform === 'win32' }, async t => {
  const { path, dir } = await temporary(t);
  const target = join(dir, 'target'); await writeFile(target, 'ORIGINAL', { mode: 0o600 });
  await symlink(target, path);
  await assert.rejects(new FileOperationJournal({ path }).append(record()), /Unsafe journal/);
  assert.equal(await readFile(target, 'utf8'), 'ORIGINAL');
  await rm(path); await symlink(dir, join(dir, 'alias-dir'));
  await assert.rejects(new FileOperationJournal({ path: join(dir, 'alias-dir', 'other.jsonl') }).append(record()), /Unsafe journal/);
});

test('Windows journal rejects shared ACLs and junction directory components', { skip: process.platform !== 'win32' }, async t => {
  const { dir, path } = await temporary(t);
  await new FileOperationJournal({ path }).append(record());
  execFileSync('icacls.exe', [path, '/grant', '*S-1-5-32-545:(R)'], { windowsHide: true, stdio: 'pipe' });
  await assert.rejects(new FileOperationJournal({ path }).read(), /Journal is shared/);
  const junction = join(dir, 'junction'); await symlink(dir, junction, 'junction');
  await assert.rejects(new FileOperationJournal({ path: join(junction, 'other.jsonl') }).append(record()), /Unsafe journal directory/);
  await rm(junction);
});

test('default journal follows credential-file directory; explicit log path wins', async t => {
  const { path, dir } = await temporary(t);
  const code = `import {operationLogPath} from ${JSON.stringify(new URL('../src/operation-journal.ts', import.meta.url).href)}; console.log(operationLogPath());`;
  const env = { ...process.env, PHONEBRIDGE_CREDENTIAL_FILE: join(dir, 'pairing.json') }; delete env.PHONEBRIDGE_LOG_FILE;
  let child = spawnSync(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', code], { env, encoding: 'utf8', windowsHide: true });
  assert.equal(child.status, 0); assert.equal(child.stdout.trim(), path);
  child = spawnSync(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', code], { env: { ...env, PHONEBRIDGE_LOG_FILE: join(dir, 'override.jsonl') }, encoding: 'utf8', windowsHide: true });
  assert.equal(child.status, 0); assert.equal(child.stdout.trim(), join(dir, 'override.jsonl'));
});

test('RPC history is authenticated, bounded and records actual errors without reply contents', async t => {
  const { path } = await temporary(t);
  const journal = new FileOperationJournal({ path });
  const { url, rpc, connect, headers, token } = await hubSetup(t, journal);
  assert.equal((await fetch(`${url}/operations`)).status, 401);
  assert.equal((await fetch(`${url}/operations`, { headers: { ...headers, Origin: 'https://evil.example' } })).status, 403);
  for (const query of ['limit=201', 'limit=0', 'limit=1&limit=2', 'text=SECRET', 'method=shell', 'status=success', '__proto__=anything']) assert.equal((await fetch(`${url}/operations?${query}`, { headers })).status, 400);
  await rpc('tap', { x: 0, y: 1 });
  let history = await journal.read();
  assert.equal(history.operations[0]!.outcome, 'not_dispatched');
  assert.equal(history.operations[0]!.errorCode, 'NO_DEVICE');
  const phone = await connect();
  phone.on('message', bytes => {
    const request = JSON.parse(bytes.toString());
    phone.send(JSON.stringify(request.method === 'set_text' ? { id: request.id, error: { code: 'READ_ONLY', message: 'SECRET_ERROR' } } : { id: request.id, result: { nodes: [{ text: 'SECRET_SCREEN' }], data: 'SECRET_IMAGE' } }));
  });
  assert.equal((await rpc('set_text', { nodeId: 'SECRET_NODE', text: 'SECRET_INPUT' })).status, 200);
  assert.equal((await rpc('state')).status, 200);
  history = await (await fetch(`${url}/operations?limit=1&status=failed`, { headers })).json();
  assert.equal(history.operations[0]!.errorCode, 'READ_ONLY');
  assert.equal(history.operations[0]!.outcome, 'device_reported_error');
  const disk = await readFile(path, 'utf8');
  for (const secret of ['SECRET_ERROR', 'SECRET_INPUT', 'SECRET_NODE', 'SECRET_SCREEN', 'SECRET_IMAGE', token]) assert.equal(disk.includes(secret), false);
});

test('busy admission, timeout and disconnect report uncertainty without retry', async t => {
  const journal = new MemoryOperationJournal();
  const { rpc, connect } = await hubSetup(t, journal, 100);
  const phone = await connect(); let count = 0;
  phone.on('message', () => count++);
  const incoming = once(phone, 'message'); const first = rpc('tap', { x: 1, y: 2 }); await incoming;
  assert.equal((await rpc('state')).status, 409);
  assert.equal((await first).status, 504);
  const rows = (await journal.read()).operations;
  const busy = rows.find(r => r.method === 'state')!;
  assert.equal(busy.errorCode, 'BUSY'); assert.equal(busy.outcome, 'not_dispatched');
  const timed = rows.find(r => r.method === 'tap')!;
  assert.equal(timed.status, 'uncertain'); assert.equal(timed.outcome, 'unknown'); assert.equal(count, 1);
  const next = await connect(); next.on('message', () => next.close());
  assert.equal((await rpc('global_action', { action: 'back' })).status, 503);
  const disconnected = (await journal.read()).operations[0]!;
  assert.equal(disconnected.errorCode, 'DISCONNECTED'); assert.equal(disconnected.status, 'uncertain');
});

test('failed start logging blocks dispatch; failed final logging never returns fake success', async t => {
  for (const failAt of [1, 2]) {
    const memory = new MemoryOperationJournal(); let writes = 0;
    const journal: OperationJournal = { read: q => memory.read(q), append: async r => { if (++writes === failAt) throw new Error('disk full'); await memory.append(r); } };
    const { rpc, connect } = await hubSetup(t, journal);
    const phone = await connect(); let dispatched = 0;
    phone.on('message', bytes => { dispatched++; const r = JSON.parse(bytes.toString()); phone.send(JSON.stringify({ id: r.id, result: {} })); });
    const response = await rpc('tap', { x: 0, y: 0 });
    assert.equal(response.status, 503);
    assert.equal((await response.json()).error.code, failAt === 1 ? 'LOG_UNAVAILABLE' : 'LOG_WRITE_FAILED');
    assert.equal(dispatched, failAt === 1 ? 0 : 1);
    const history = await memory.read();
    assert.equal(history.operations.length, failAt === 1 ? 0 : 1);
    if (failAt === 2) assert.equal(history.operations[0]!.outcome, 'unknown');
  }
});

test('disk read failure and unknown device error codes do not expose arbitrary content', async t => {
  const memory = new MemoryOperationJournal();
  const journal: OperationJournal = { append: r => memory.append(r), read: async () => { throw new Error('PRIVATE_PATH_SECRET'); } };
  const { url, headers, rpc, connect } = await hubSetup(t, journal);
  const response = await fetch(`${url}/operations`, { headers });
  assert.equal(response.status, 503); assert.equal(JSON.stringify(await response.json()).includes('PRIVATE_PATH_SECRET'), false);
  const phone = await connect(); phone.on('message', bytes => { const r = JSON.parse(bytes.toString()); phone.send(JSON.stringify({ id: r.id, error: { code: 'PRIVATE_ERROR_SECRET', message: 'PRIVATE_TEXT_SECRET' } })); });
  await rpc('state');
  const history = await memory.read();
  assert.equal(history.operations[0]!.errorCode, 'DEVICE_ERROR');
  assert.equal(JSON.stringify(history).includes('PRIVATE_ERROR_SECRET'), false);
});

test('empty and arbitrary device error codes persist as failed errors rather than completed success', async t => {
  const { path } = await temporary(t);
  const journal = new FileOperationJournal({ path });
  const { rpc, connect } = await hubSetup(t, journal);
  const codes = ['', ' ', 'PRIVATE_ERROR_SECRET', 'private screen text in error code'];
  let codeIndex = 0;
  const phone = await connect();
  phone.on('message', bytes => {
    const request = JSON.parse(bytes.toString());
    phone.send(JSON.stringify({ id: request.id, error: { code: codes[codeIndex++], message: 'PRIVATE_ERROR_MESSAGE' } }));
  });
  for (const code of codes) {
    const response = await rpc('state');
    assert.equal(response.status, 200);
    assert.equal((await response.json()).error.code, code);
    const latest = (await journal.read({ limit: 1 })).operations[0]!;
    assert.equal(latest.status, 'failed');
    assert.equal(latest.outcome, 'device_reported_error');
    assert.equal(latest.errorCode, 'DEVICE_ERROR');
  }
  const persisted = await new FileOperationJournal({ path }).read();
  assert.equal(persisted.operations.length, codes.length);
  assert.ok(persisted.operations.every(row => row.status === 'failed' && row.errorCode === 'DEVICE_ERROR'));
  const disk = await readFile(path, 'utf8');
  assert.equal(disk.includes('PRIVATE_ERROR'), false);
  assert.equal(disk.includes('private screen text'), false);
});
