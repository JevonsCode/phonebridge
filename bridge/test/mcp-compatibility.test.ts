import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import { encode } from 'jpeg-js';

async function mcp(t: TestContext, url = 'http://127.0.0.1:8765') {
  const child = spawn(process.execPath, ['--import', 'tsx', 'src/mcp.ts'], {
    cwd: fileURLToPath(new URL('..', import.meta.url)),
    env: { ...process.env, PHONEBRIDGE_TOKEN: 'x'.repeat(32), PHONEBRIDGE_URL: url, PHONEBRIDGE_DESKTOP_CONFIG: '' },
    stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true,
  });
  let stderr = '', buffer = '', sequence = 0;
  child.stderr.on('data', chunk => { stderr += chunk; });
  const pending = new Map<number, (message: any) => void>();
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    buffer += chunk;
    let end: number;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line) continue;
      const message = JSON.parse(line); pending.get(message.id)?.(message);
    }
  });
  t.after(async () => {
    const exited = once(child, 'exit'); child.stdin.end();
    const timer = setTimeout(() => child.kill(), 5000);
    try { assert.equal((await exited)[0], 0, stderr); } finally { clearTimeout(timer); }
    assert.equal(stderr, '');
  });
  const request = (method: string, params: unknown) => new Promise<any>((done, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`MCP request timed out: ${stderr}`)); }, 10000);
    pending.set(id, result => { clearTimeout(timer); pending.delete(id); done(result); });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  const initialized = await request('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'compatibility-test', version: '1' } });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  return { request, initialized };
}

test('real stdio initialize reports the repository App version', async t => {
  const client = await mcp(t);
  const pubspec = await readFile(new URL('../../mobile/pubspec.yaml', import.meta.url), 'utf8');
  assert.equal(client.initialized.result.serverInfo.version, /^version:\s*([^\s+]+)/m.exec(pubspec)?.[1]);
});

test('real stdio tools/list uses inline object schemas compatible with Claude', async t => {
  const client = await mcp(t);
  const response = await client.request('tools/list', {});
  assert.ok(response.result.tools.length > 10);
  for (const tool of response.result.tools) {
    const schema = tool.inputSchema;
    assert.equal(schema.type, 'object', tool.name);
    for (const key of ['anyOf', 'oneOf', 'allOf']) assert.equal(key in schema, false, `${tool.name}: root ${key}`);
    assert.doesNotMatch(JSON.stringify(schema), /"\$ref"\s*:/, `${tool.name}: no references`);
  }
  for (const name of ['phone_tap', 'phone_long_press', 'phone_swipe']) {
    const schema = response.result.tools.find((tool: any) => tool.name === name).inputSchema;
    for (const field of name === 'phone_swipe' ? ['x1', 'y1', 'x2', 'y2'] : ['x', 'y']) {
      assert.deepEqual(schema.properties[field], { type: 'integer', minimum: 0, maximum: 16384 });
      if (name !== 'phone_tap') assert.ok(schema.required.includes(field));
    }
  }
});

test('real stdio routes clipboard, selector/image taps and renewals through one workflow handle and retains native errors', async t => {
  const commands: Array<Record<string, any>> = [];
  const screenshot = { screenshotId: 'image-1', mimeType: 'image/jpeg', data: encode({ data: Buffer.from([255, 0, 0, 255]), width: 1, height: 1 }, 65).data.toString('base64'), width: 1, height: 1, screenWidth: 100, screenHeight: 200, cropLeft: 0, cropTop: 0, cropWidth: 100, cropHeight: 200 };
  const service = http.createServer(async (request, response) => {
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/devices') { response.end(JSON.stringify({ devices: [{ id: 'phone-a', connected: true, connectionId: 'generation-1', protocol: 2, capabilities: ['control_lease', 'clipboard', 'selectors', 'image_coordinates', 'text_actions', 'control_renew'] }] })); return; }
    let raw = ''; for await (const chunk of request) raw += chunk;
    const command = JSON.parse(raw); commands.push(command);
    if (command.method === 'node_action' && command.params.selector?.text === 'ambiguous') {
      response.end(JSON.stringify({ error: { code: 'AMBIGUOUS_SELECTOR', message: 'Several controls match; refine the selector or choose an index.', details: { matchCount: 2, foregroundPackage: 'dev.example.app' } } })); return;
    }
    const result = command.method === 'get_clipboard' ? { text: 'https://example.org/shared', hasText: true }
      : command.method === 'screenshot' ? screenshot
        : command.method === 'renew_control' ? { state: 'active', expiresInMs: 60000 }
          : command.method === 'acquire_control' ? { state: 'active' } : { ok: true };
    response.end(JSON.stringify({ result }));
  });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  t.after(() => new Promise<void>(done => { service.closeAllConnections(); service.close(() => done()); }));
  const address = service.address(); assert.ok(address && typeof address === 'object');
  const client = await mcp(t, `http://127.0.0.1:${address.port}`);
  const tool = async (name: string, args: Record<string, unknown>) => (await client.request('tools/call', { name, arguments: args })).result;
  const acquired = JSON.parse((await tool('phone_acquire_control', { deviceId: 'phone-a' })).content[0].text);
  const taskHandle = acquired.taskHandle;
  try {
    const list = await client.request('tools/list', {});
    for (const name of ['phone_get_clipboard', 'phone_set_clipboard', 'phone_renew_control']) assert.ok(list.result.tools.some((entry: any) => entry.name === name), name);
    const clipboard = JSON.parse((await tool('phone_get_clipboard', { taskHandle })).content[0].text); assert.equal(clipboard.text, 'https://example.org/shared');
    assert.equal((await tool('phone_set_clipboard', { taskHandle, text: '你好 🌍' })).isError, undefined);
    assert.equal((await tool('phone_node_action', { taskHandle, selector: { resourceId: 'app:id/input' }, action: 'paste' })).isError, undefined);
    assert.equal((await tool('phone_tap', { taskHandle, selector: { text: 'Publish', index: 0 } })).isError, undefined);
    const image = await tool('phone_screenshot', { taskHandle }); assert.equal(image.isError, undefined); assert.equal(JSON.parse(image.content[1].text).screenshotId, 'image-1');
    assert.equal((await tool('phone_tap', { taskHandle, imageX: 0, imageY: 0, screenshotId: 'image-1' })).isError, undefined);
    const renewed = JSON.parse((await tool('phone_renew_control', { taskHandle })).content[0].text); assert.equal(renewed.state, 'active'); assert.equal(renewed.taskHandle, taskHandle);
    const ambiguous = await tool('phone_node_action', { taskHandle, selector: { text: 'ambiguous' }, action: 'click' });
    assert.equal(ambiguous.isError, true); assert.equal(JSON.parse(ambiguous.content[0].text).code, 'AMBIGUOUS_SELECTOR'); assert.deepEqual(JSON.parse(ambiguous.content[0].text).details, { matchCount: 2, foregroundPackage: 'dev.example.app' });
    const count = commands.length;
    const invalid = await tool('phone_tap', { taskHandle, x: 1, y: 2, selector: { text: 'Publish' } });
    assert.equal(invalid.isError, true); assert.equal(JSON.parse(invalid.content[0].text).code, 'INVALID_PARAMS'); assert.equal(commands.length, count);
  } finally { await tool('phone_release_control', { taskHandle }); }
  assert.equal(commands.filter(command => command.method === 'acquire_control').length, 1);
  const controlId = commands[0]!.params.controlId;
  for (const command of commands.slice(1)) { assert.equal(command.controlId ?? command.params.controlId, controlId); assert.equal(command.connectionId, 'generation-1'); }
  assert.equal(commands.find(command => command.method === 'renew_control')!.params.controlId, controlId);
  assert.equal(commands.find(command => command.method === 'set_clipboard')!.params.text, '你好 🌍');
});

test('real stdio offline acquire retains the service endpoint and known-device diagnostics', async t => {
  const details = { publicEndpoint: 'http://192.168.1.9:8767', connectionState: 'phone_offline', knownDevices: [{ id: 'phone-a', connected: false, lastSeenAt: 123, lastComputerEndpoint: 'http://192.168.1.8:8767' }], nextSteps: ['Open the paired phone and wait for reconnection.'] };
  const service = http.createServer((request, response) => {
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/devices') response.end(JSON.stringify({ devices: [{ id: 'phone-a', connected: false }], details }));
    else { response.statusCode = 409; response.end(JSON.stringify({ error: { code: 'NO_DEVICE', message: 'Phone is offline.', details } })); }
  });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  t.after(() => new Promise<void>(done => { service.closeAllConnections(); service.close(() => done()); }));
  const address = service.address(); assert.ok(address && typeof address === 'object');
  const client = await mcp(t, `http://127.0.0.1:${address.port}`);
  for (const name of ['phone_acquire_control', 'phone_state']) {
    const result = await client.request('tools/call', { name, arguments: { deviceId: 'phone-a' } });
    assert.equal(result.result.isError, true);
    const error = JSON.parse(result.result.content[0].text);
    assert.equal(error.code, 'NO_DEVICE'); assert.deepEqual(error.details, details);
  }
});
