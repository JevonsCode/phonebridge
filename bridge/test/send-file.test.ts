import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { sendLocalFile } from '../src/send-file.js';
import { BridgeError } from '../src/protocol.js';

test('file messages distinguish automatic/manual queues, receiving and confirmed receipt using actual transfer state', async t => {
  const root = await mkdtemp(join(tmpdir(), 'phonebridge-send-')); t.after(() => rm(root, { recursive: true, force: true }));
  const file = join(root, 'file.txt'); await writeFile(file, 'file bytes');
  let reply: Record<string, unknown> = {}, status = 201;
  const service = http.createServer(async (request, response) => {
    for await (const _ of request) { /* Consume the real upload. */ }
    response.statusCode = status; response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(reply));
  });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  t.after(() => new Promise<void>(done => { service.closeAllConnections(); service.close(() => done()); }));
  const address = service.address(); assert.ok(address && typeof address === 'object');
  const url = new URL(`http://127.0.0.1:${address.port}`);
  for (const [state, autoReceiveEnabled, phoneState, expected] of [
    ['pending', true, 'pending', /File queued for the phone/],
    ['pending', false, 'pending', /Automatic receipt is disabled/],
    ['pending', true, 'receiving', /phone is receiving.*not confirmed/],
    ['receiving', true, 'receiving', /phone is receiving.*not confirmed/],
    ['received', true, 'received', /phone confirmed file receipt/],
    ['failed', true, 'failed', /Receipt is not confirmed/],
  ] as const) {
    reply = { transfer: { id: 'transfer', state }, autoReceiveEnabled, phoneState };
    const result = await sendLocalFile(url, 'x'.repeat(32), file) as any;
    assert.deepEqual(result.transfer, reply.transfer); assert.equal(result.autoReceiveEnabled, autoReceiveEnabled);
    assert.match(result.message, expected); assert.doesNotMatch(result.message, /sent to a contact|message has been sent/);
    if (autoReceiveEnabled && (state === 'pending' || state === 'receiving')) {
      assert.match(result.instruction, /no owner confirmation is required/); assert.match(result.instruction, /phone_list_devices.*same device and transfer.id.*received/); assert.match(result.instruction, /Do not resend/);
    } else assert.equal(result.instruction, undefined);
  }
  const details = { publicEndpoint: 'http://192.168.1.1:8767', connectionState: 'phone_offline' };
  status = 409; reply = { error: { code: 'NO_DEVICE', message: 'Phone offline.', details } };
  await assert.rejects(sendLocalFile(url, 'x'.repeat(32), file), (error: BridgeError) => error.code === 'NO_DEVICE' && error.details?.publicEndpoint === details.publicEndpoint);
});
