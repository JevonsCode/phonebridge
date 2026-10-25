import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { PhoneHub } from '../src/hub.js';
import { MemoryOperationJournal } from '../src/operation-journal.js';

test('new MCP tools traverse a real Hub and simulated phone with one lease, unchanged selectors and native error details', async t => {
  const token = 'x'.repeat(32), deviceId = randomUUID(), journal = new MemoryOperationJournal();
  const hub = new PhoneHub({ token, port: 0, journal }); const url = await hub.start();
  const phone = new WebSocket(url.replace('http', 'ws') + '/device', { headers: { Authorization: `Bearer ${token}` } });
  let client: Client | undefined;
  t.after(async () => { await client?.close(); phone.close(); await hub.close(); });
  await once(phone, 'open');
  phone.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId, device: 'feature-fixture', readOnly: false, capabilities: ['control_lease', 'element_actions', 'clipboard', 'selectors', 'image_coordinates', 'text_actions', 'control_renew'] }));
  let connected = false;
  for (let attempt = 0; attempt < 200; attempt++) {
    if ((await (await fetch(`${url}/devices`, { headers: { Authorization: `Bearer ${token}` } })).json()).devices.some((device: any) => device.id === deviceId && device.connected)) { connected = true; break; }
    await new Promise(done => setTimeout(done, 5));
  }
  assert.equal(connected, true);
  const commands: Array<Record<string, any>> = [], clipboardText = '文'.repeat(5000);
  phone.on('message', bytes => {
    const request = JSON.parse(bytes.toString()); commands.push(request);
    if (request.method === 'node_action' && request.params.selector?.text === 'ambiguous') {
      phone.send(JSON.stringify({ id: request.id, error: { code: 'AMBIGUOUS_SELECTOR', message: 'Several nodes match.', details: { matchCount: 2, foregroundPackage: 'dev.example.app', windowType: 'application' } } })); return;
    }
    const result = request.method === 'get_clipboard' ? { text: clipboardText, hasText: true, truncated: false, totalLength: clipboardText.length }
      : request.method === 'acquire_control' || request.method === 'renew_control' ? { state: 'active', expiresInMs: 60000 } : { completed: true };
    phone.send(JSON.stringify({ id: request.id, result }));
  });
  const env = Object.fromEntries(Object.entries(process.env).filter((item): item is [string, string] => item[1] !== undefined));
  const transport = new StdioClientTransport({ command: process.execPath, args: ['--import', 'tsx', fileURLToPath(new URL('../src/mcp.ts', import.meta.url))], env: { ...env, PHONEBRIDGE_URL: url, PHONEBRIDGE_TOKEN: token, PHONEBRIDGE_DESKTOP_CONFIG: '' }, stderr: 'pipe' });
  client = new Client({ name: 'feature-integration', version: '1' }); await client.connect(transport);
  const call = (name: string, args: Record<string, unknown>) => client!.callTool({ name, arguments: args });
  const data = (value: Awaited<ReturnType<typeof call>>) => JSON.parse((value.content as Array<{ text: string }>)[0]!.text);
  const acquired = data(await call('phone_acquire_control', { deviceId })), taskHandle = acquired.taskHandle;
  try {
    const clipboard = data(await call('phone_get_clipboard', { taskHandle }));
    assert.equal(clipboard.text, clipboardText); assert.equal(clipboard.truncated, false); assert.equal(clipboard.totalLength, 5000);
    assert.equal((await call('phone_set_clipboard', { taskHandle, text: clipboardText })).isError, undefined);
    assert.equal((await call('phone_node_action', { taskHandle, selector: { resourceId: 'app:id/input' }, action: 'paste' })).isError, undefined);
    assert.equal((await call('phone_tap', { taskHandle, selector: { text: 'Publish', index: 0 } })).isError, undefined);
    assert.equal(data(await call('phone_renew_control', { taskHandle })).state, 'active');
    const ambiguous = await call('phone_node_action', { taskHandle, selector: { text: 'ambiguous' }, action: 'click' });
    assert.equal(ambiguous.isError, true); assert.equal(data(ambiguous).code, 'AMBIGUOUS_SELECTOR');
    assert.deepEqual(data(ambiguous).details, { matchCount: 2, foregroundPackage: 'dev.example.app', windowType: 'application' });
  } finally { await call('phone_release_control', { taskHandle }); }
  assert.equal(commands.filter(command => command.method === 'acquire_control').length, 1);
  const controlId = commands[0]!.params.controlId;
  for (const command of commands.slice(1)) assert.equal(command.controlId ?? command.params.controlId, controlId);
  assert.deepEqual(commands.find(command => command.method === 'tap')!.params, { selector: { text: 'Publish', index: 0 } });
  assert.equal(commands.find(command => command.method === 'set_clipboard')!.params.text, clipboardText);
  assert.doesNotMatch(JSON.stringify(await journal.read()), /文|app:id\/input|ambiguous/);
});
