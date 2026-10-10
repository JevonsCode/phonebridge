import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { networkInterfaces, tmpdir } from 'node:os';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { loadOrCreateSavedToken } from '../src/credentials.js';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import WebSocket from 'ws';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { PhoneHub } from '../src/hub.js';
import { parseCommand } from '../src/protocol.js';
import { encode } from 'jpeg-js';
import { validateScreenshot } from '../src/screenshot.js';
import { MemoryOperationJournal } from '../src/operation-journal.js';

const validScreenshot = { mimeType: 'image/jpeg', data: encode({ data: Buffer.from([255, 0, 0, 255]), width: 1, height: 1 }, 65).data.toString('base64'), width: 1, height: 1, screenWidth: 100, screenHeight: 220, cropLeft: 0, cropTop: 20, cropWidth: 100, cropHeight: 200 };

async function setup(t: TestContext, timeoutMs = 1000, host = '127.0.0.1') {
  const token = randomBytes(32).toString('base64url');
  const journal = new MemoryOperationJournal();
  const hub = new PhoneHub({ token, port: 0, timeoutMs, host, allowLan: host !== '127.0.0.1', journal });
  const url = await hub.start();
  t.after(() => hub.close());
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const rpc = (method: string, params = {}) => fetch(`${url}/rpc`, { method: 'POST', headers, body: JSON.stringify({ method, params }) });
  const connect = async () => {
    const ws = new WebSocket(url.replace('http', 'ws') + '/device', { headers });
    await once(ws, 'open');
    ws.send(JSON.stringify({ type: 'hello', protocol: 1, device: 'simulated', readOnly: true }));
    for (let i = 0; i < 100; i++) {
      if ((await (await fetch(`${url}/status`, { headers })).json()).connected) return ws;
      await delay(5);
    }
    throw new Error('Phone did not become ready');
  };
  return { token, hub, url, headers, rpc, connect, journal };
}

test('health reveals no token or device information; commands require authentication', async t => {
  const { url } = await setup(t);
  assert.deepEqual(await (await fetch(`${url}/health`)).json(), { ok: true, protocol: 1 });
  assert.equal((await fetch(`${url}/status`)).status, 401);
  assert.equal((await fetch(`${url}/rpc`, { method: 'POST' })).status, 401);
  assert.equal((await fetch(`${url}/health`, { headers: { Origin: 'https://untrusted.example' } })).status, 403);
});

test('rejects weak credentials and accidental LAN bind', () => {
  assert.throws(() => new PhoneHub({ token: 'weak' }), /32/);
  assert.throws(() => new PhoneHub({ token: 'a'.repeat(32), host: '0.0.0.0' }), /allow-lan/);
});

test('rejects unauthenticated WebSocket and browser origins', async t => {
  const { url, headers } = await setup(t);
  for (const options of [{}, { headers: { ...headers, Origin: 'https://untrusted.example' } }]) {
    const ws = new WebSocket(url.replace('http', 'ws') + '/device', options);
    const [error] = await once(ws, 'error');
    assert.match(error.message, /401/);
  }
});

test('refuses commands without an authenticated ready phone', async t => {
  const { rpc } = await setup(t);
  const response = await rpc('state');
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'NO_DEVICE');
});

test('validates parameters and never forwards arbitrary commands', async t => {
  const { rpc } = await setup(t);
  for (const [method, params] of [['shell', {}], ['tap', { x: -1, y: 0 }], ['swipe', { x1: 1, y1: 1, x2: 2, y2: 2, durationMs: 99999 }], ['state', { extra: true }], ['set_text', { nodeId: 'n', text: 'x'.repeat(4001) }]] as const) {
    assert.equal((await rpc(method, params)).status, 400);
  }
  assert.throws(() => parseCommand({ method: '__proto__', params: {} }));
  for (const params of [{ text: 'hello' }, { packageName: 'com.tencent.mm', text: '' },
    { packageName: 'com.tencent.mm', text: 'x'.repeat(4001) }, { packageName: 'invalid', text: 'hello' }]) {
    assert.equal((await rpc('commit_text', params)).status, 400);
  }
});

test('round-trips Unicode text and preserves device READ_ONLY errors', async t => {
  const { rpc, connect } = await setup(t);
  const phone = await connect();
  phone.on('message', bytes => {
    const request = JSON.parse(bytes.toString());
    assert.equal(request.params.text, '你好，世界 🌍');
    phone.send(JSON.stringify({ id: request.id, error: { code: 'READ_ONLY', message: 'Enable actions on phone.' } }));
  });
  const result = await (await rpc('set_text', { nodeId: 'epoch:1', text: '你好，世界 🌍' })).json();
  assert.equal(result.error.code, 'READ_ONLY');
  const focused = await (await rpc('commit_text', { packageName: 'com.example.test', text: '你好，世界 🌍' })).json();
  assert.equal(focused.error.code, 'READ_ONLY');
});

test('single-flight rejects concurrent commands and ignores unrelated replies', async t => {
  const { rpc, connect } = await setup(t);
  const phone = await connect();
  const incoming = once(phone, 'message');
  const first = rpc('state');
  const [bytes] = await incoming;
  const request = JSON.parse(bytes.toString());
  phone.send(JSON.stringify({ id: 'unrelated', result: {} }));
  const second = await rpc('screenshot');
  assert.equal(second.status, 409);
  phone.send(JSON.stringify({ id: request.id, result: { nodes: [] } }));
  assert.deepEqual((await (await first).json()).result, { nodes: [] });
});

test('a second phone cannot replace an active phone', async t => {
  const { url, headers, connect } = await setup(t);
  await connect();
  const second = new WebSocket(url.replace('http', 'ws') + '/device', { headers });
  const [error] = await once(second, 'error');
  assert.match(error.message, /409/);
});

test('timeout disconnects and never retries an action', async t => {
  const { rpc, connect } = await setup(t, 75);
  const phone = await connect(); let count = 0;
  phone.on('message', () => count++);
  const result = await rpc('tap', { x: 10, y: 20 });
  assert.equal(result.status, 504);
  assert.equal((await result.json()).error.code, 'TIMEOUT');
  assert.equal(count, 1);
  assert.equal((await rpc('state')).status, 503);
});

test('disconnect rejects pending command instead of reporting success', async t => {
  const { rpc, connect } = await setup(t);
  const phone = await connect();
  phone.on('message', () => phone.close());
  const response = await rpc('tap', { x: 0, y: 0 });
  assert.equal((await response.json()).error.code, 'DISCONNECTED');
});

test('malformed device replies fail closed', async t => {
  const { rpc, connect } = await setup(t);
  const phone = await connect();
  phone.on('message', () => phone.send('{broken'));
  const response = await rpc('state');
  assert.equal((await response.json()).error.code, 'DISCONNECTED');
});

test('request size and JSON content type are bounded', async t => {
  const { url, headers } = await setup(t);
  const oversized = await fetch(`${url}/rpc`, { method: 'POST', headers, body: JSON.stringify({ junk: 'x'.repeat(40000) }) });
  assert.equal(oversized.status, 413);
  const wrongType = await fetch(`${url}/rpc`, { method: 'POST', headers: { Authorization: headers.Authorization }, body: '{}' });
  assert.equal(wrongType.status, 415);
});

const localLanAddress = Object.values(networkInterfaces()).flat().find(item => item && item.family === 'IPv4' && !item.internal)?.address;
for (const host of ['127.0.0.1', ...(localLanAddress ? [localLanAddress] : [])]) {
test(`MCP stdio discovers tools and returns state/image/error through real hub (${host === '127.0.0.1' ? 'loopback' : 'local LAN interface'})`, async t => {
  const { token, url, connect } = await setup(t, 1000, host);
  const phone = await connect();
  phone.on('message', bytes => {
    const request = JSON.parse(bytes.toString());
    const result = request.method === 'screenshot' ? validScreenshot : { packageName: 'dev.phonebridge.phonebridge', nodes: [{ id: '1', text: '你好' }] };
    phone.send(JSON.stringify(request.method === 'tap' ? { id: request.id, error: { code: 'READ_ONLY', message: 'Owner consent required.' } } : { id: request.id, result }));
  });
  const env = Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined));
  const clientEnv = { ...env, PHONEBRIDGE_URL: url, PHONEBRIDGE_TOKEN: token } as Record<string, string>;
  if (host !== '127.0.0.1') {
    const credentialsDir = await mkdtemp(join(tmpdir(), 'phonebridge-mcp-'));
    t.after(() => rm(credentialsDir, { recursive: true, force: true }));
    clientEnv.PHONEBRIDGE_CREDENTIAL_FILE = join(credentialsDir, 'pairing.json');
    await loadOrCreateSavedToken(clientEnv.PHONEBRIDGE_CREDENTIAL_FILE, token);
    delete clientEnv.PHONEBRIDGE_TOKEN;
  }
  const transport = new StdioClientTransport({ command: process.execPath, args: ['--import', 'tsx', fileURLToPath(new URL('../src/mcp.ts', import.meta.url))], env: clientEnv, stderr: 'pipe' });
  const client = new Client({ name: 'test', version: '1' });
  await client.connect(transport); t.after(() => client.close());
  const list = await client.listTools(); assert.equal(list.tools.length, 10);
  assert.equal(list.tools.find(x => x.name === 'phone_state')?.annotations?.readOnlyHint, true);
  const historyTool = list.tools.find(x => x.name === 'phone_operation_history');
  assert.equal(historyTool?.annotations?.readOnlyHint, true);
  assert.equal(historyTool?.annotations?.destructiveHint, false);
  assert.equal(historyTool?.annotations?.openWorldHint, false);
  const state = await client.callTool({ name: 'phone_state', arguments: {} });
  assert.match(JSON.stringify(state.content), /你好/);
  const screenshot = await client.callTool({ name: 'phone_screenshot', arguments: {} });
  assert.equal((screenshot.content as { type: string }[])[0]?.type, 'image');
  assert.match(JSON.stringify(screenshot.content), /cropTop/);
  const denied = await client.callTool({ name: 'phone_tap', arguments: { x: 1, y: 2 } });
  assert.equal(denied.isError, true);
  const history = await client.callTool({ name: 'phone_operation_history', arguments: { limit: 1, method: 'tap' } });
  assert.equal(history.isError, undefined);
  const data = JSON.parse((history.content as { text: string }[])[0]!.text);
  assert.equal(data.operations.length, 1);
  assert.equal(data.operations[0].method, 'tap');
  assert.equal(data.operations[0].errorCode, 'READ_ONLY');
  assert.equal(data.operations[0].outcome, 'device_reported_error');
  assert.equal(JSON.stringify(data).includes('你好'), false);
  const invalidHistory = await client.callTool({ name: 'phone_operation_history', arguments: { limit: 201 } });
  assert.equal(invalidHistory.isError, true);
});
}

test('screenshots validate real JPEG data, dimensions, decoded byte limit, and crop bounds', () => {
  assert.equal(validateScreenshot(validScreenshot).width, 1);
  for (const overrides of [
    { data: '' }, { data: '/9j/2Q==' }, { width: 0 }, { height: -1 },
    { cropLeft: 101 }, { cropTop: 30 }, { cropWidth: undefined },
    { width: 1281 }, { width: 2 }, { data: Buffer.alloc(2 * 1024 * 1024 + 1).toString('base64') },
  ]) assert.throws(() => validateScreenshot({ ...validScreenshot, ...overrides }));
});
