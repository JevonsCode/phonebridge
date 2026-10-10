import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { DesktopSupervisor } from '../dist/supervisor.js';

async function until(check: () => boolean | Promise<boolean>, message: string) {
  for (let n = 0; n < 200; n++) { if (await check()) return; await delay(25); }
  throw new Error(message);
}
async function setup(t: TestContext, autoStart = false) {
  const token = randomBytes(32).toString('base64url');
  const supervisor = new DesktopSupervisor({ token, port: 0, autoStart, restartDelayMs: 50 });
  const url = await supervisor.start();
  t.after(() => supervisor.close());
  const headers = { Authorization: `Bearer ${token}` };
  const start = () => fetch(`${url}/service/start`, { method: 'POST', headers });
  return { supervisor, url, headers, start };
}

test('management stays available while Hub is stopped, and refuses untrusted requests', async t => {
  const { supervisor, url, headers } = await setup(t);
  assert.equal(supervisor.serviceRunning, false);
  assert.deepEqual(await (await fetch(`${url}/health`)).json(), { ok: true, protocol: 1 });
  assert.equal((await fetch(`${url}/service/start`, { method: 'POST' })).status, 401);
  assert.equal((await fetch(`${url}/service/start`, { method: 'POST', headers: { ...headers, Origin: 'https://evil.example' } })).status, 403);
  assert.equal((await fetch(`${url}/service/start`, { headers })).status, 405);
  assert.equal((await fetch(`${url}/service/start`, { method: 'POST', headers, body: '{"command":"shell"}' })).status, 400);
  assert.equal((await fetch(`${url}/service/start?command=shell`, { method: 'POST', headers })).status, 404);
  assert.equal(supervisor.managedProcessId, undefined);
});

test('concurrent authenticated start requests share one ready Hub and retain the endpoint', async t => {
  const { supervisor, url, headers, start } = await setup(t);
  const responses = await Promise.all(Array.from({ length: 6 }, start));
  for (const response of responses) {
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { serviceRunning: true });
  }
  const firstPid = supervisor.managedProcessId;
  assert.ok(firstPid);
  await start(); assert.equal(supervisor.managedProcessId, firstPid);
  assert.deepEqual(await (await fetch(`${url}/status`, { headers })).json(), { connected: false, busy: false, protocol: 1 });
});

test('WebSocket and RPC pass through the original port without replaying a failed operation', async t => {
  const { supervisor, url, headers } = await setup(t, true);
  const phone = new WebSocket(`${url.replace('http', 'ws')}/device`, { headers });
  t.after(() => phone.terminate());
  await once(phone, 'open');
  phone.send(JSON.stringify({ type: 'hello', protocol: 1, readOnly: false }));
  await until(async () => (await (await fetch(`${url}/status`, { headers })).json()).connected, 'Phone handshake failed');
  let received = 0;
  phone.on('message', bytes => {
    received++;
    const command = JSON.parse(bytes.toString());
    if (command.method === 'state') phone.send(JSON.stringify({ id: command.id, result: { packageName: 'allowed.example' } }));
    else process.kill(supervisor.managedProcessId!);
  });
  const rpc = (method: string, params = {}) => fetch(`${url}/rpc`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ method, params }) });
  const state = await rpc('state');
  assert.equal(state.status, 200);
  assert.equal((await state.json()).result.packageName, 'allowed.example');
  const oldPid = supervisor.managedProcessId;
  const action = await rpc('global_action', { action: 'back' });
  assert.equal(action.status, 503);
  await until(() => supervisor.serviceRunning && supervisor.managedProcessId !== oldPid, 'Hub was not restarted');
  assert.equal(received, 2, 'Failed action must not be replayed');
  assert.equal((await (await fetch(`${url}/status`, { headers })).json()).connected, false);
});

test('supervisor shutdown removes its managed child and does not restart it', async () => {
  const supervisor = new DesktopSupervisor({ token: 'x'.repeat(32), port: 0, restartDelayMs: 25 });
  await supervisor.start();
  const pid = supervisor.managedProcessId!;
  await supervisor.close();
  assert.throws(() => process.kill(pid, 0));
  await delay(80);
  assert.equal(supervisor.managedProcessId, undefined);
});

test('repeated polling tracks each reused socket only once', async t => {
  const { supervisor, url, headers } = await setup(t, true);
  for (let n = 0; n < 30; n++) {
    assert.equal((await (await fetch(`${url}/status`, { headers })).json()).connected, false);
  }
  const streams = (supervisor as unknown as { streams: Set<import('node:net').Socket> }).streams;
  for (const socket of streams) {
    assert.ok(socket.listenerCount('error') < 10);
    assert.ok(socket.listenerCount('close') < 10);
  }
});

test('worker launch errors schedule recovery after the executable becomes available', async t => {
  const { supervisor } = await setup(t);
  const executable = process.execPath;
  try {
    process.execPath = `${executable}.missing`;
    await assert.rejects(supervisor.ensureRunning(), /startup failed/);
  } finally { process.execPath = executable; }
  await until(() => supervisor.serviceRunning, 'Launch failure was not retried');
  assert.ok(supervisor.managedProcessId);
});

test('forced parent termination closes the orphan worker via IPC disconnect', async t => {
  const parent = fork(fileURLToPath(new URL('./fixtures/supervisor-parent.mjs', import.meta.url)), [], {
    env: { ...process.env, PHONEBRIDGE_TOKEN: 'x'.repeat(32) }, execArgv: [],
    stdio: ['ignore', 'ignore', 'ignore', 'ipc'], windowsHide: true,
  });
  t.after(() => { if (parent.exitCode === null && parent.signalCode === null) parent.kill(); });
  const ready = await Promise.race([once(parent, 'message'), delay(7000).then(() => { throw new Error('Parent startup timed out'); })]);
  const { pid } = ready[0] as { pid: number };
  const exit = once(parent, 'exit');
  parent.kill('SIGKILL'); await exit;
  await until(() => { try { process.kill(pid, 0); return false; } catch { return true; } }, 'Orphan worker survived');
  const replacement = new DesktopSupervisor({ token: 'x'.repeat(32), port: 0 });
  await replacement.start();
  assert.equal(replacement.serviceRunning, true);
  await replacement.close();
});
