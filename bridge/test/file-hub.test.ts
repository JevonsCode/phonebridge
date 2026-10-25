import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import WebSocket from 'ws';
import { PhoneHub } from '../src/hub.js';
import { MemoryOperationJournal } from '../src/operation-journal.js';
import { sendLocalFile } from '../src/send-file.js';
import { BridgeError } from '../src/protocol.js';

test('authenticated file handoff requires phone, offers metadata only, verifies download and releases after receipt', async t => {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal: new MemoryOperationJournal() });
  const url = await hub.start(); t.after(() => hub.close());
  const headers = { Authorization: `Bearer ${token}` };
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-file-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, '图片.png'); const data = Buffer.from('test file bytes'); await writeFile(path, data);
  assert.equal((await fetch(`${url}/files`, { method: 'POST' })).status, 401);
  await assert.rejects(sendLocalFile(new URL(url), token, path), (error: BridgeError) => error.code === 'NO_DEVICE');
  const ws = new WebSocket(url.replace('http', 'ws') + '/device', { headers }); await once(ws, 'open');
  ws.send(JSON.stringify({ type: 'hello', protocol: 1 }));
  while (!(await (await fetch(`${url}/status`, { headers })).json()).connected) await new Promise(r => setTimeout(r, 5));
  let offer: any;
  ws.on('message', bytes => { const request = JSON.parse(bytes.toString()); assert.equal(request.method, 'file_offer'); offer = request.params; ws.send(JSON.stringify({ id: request.id, result: { queued: true } })); });
  const result: any = await sendLocalFile(new URL(url), token, path);
  assert.equal(result.transfer.state, 'pending'); assert.equal(offer.name, '图片.png'); assert.equal(offer.path, undefined);
  assert.equal(offer.expiresAt, result.transfer.expiresAt); assert.ok(offer.expiresAt > Date.now()); assert.ok(offer.expiresAt <= Date.now() + 10 * 60 * 1000);
  assert.equal(offer.sha256, createHash('sha256').update(data).digest('hex'));
  assert.equal((await fetch(`${url}/files/${offer.id}`)).status, 401);
  assert.equal((await fetch(`${url}/files/${offer.id}`, { headers: { ...headers, Origin: 'https://example.org' } })).status, 403);
  await assert.rejects(sendLocalFile(new URL(url), token, path), /awaiting/);
  assert.deepEqual(Buffer.from(await (await fetch(`${url}/files/${offer.id}`, { headers })).arrayBuffer()), data);
  assert.equal((await fetch(`${url}/files/${offer.id}/received`, { method: 'POST', headers })).status, 200);
  assert.equal((await fetch(`${url}/files/${offer.id}/received`, { method: 'POST', headers })).status, 200);
  const received = await (await fetch(`${url}/status`, { headers })).json();
  assert.equal(received.transfer.state, 'received'); assert.equal(received.transfer.expiresAt, undefined);
  assert.equal((await fetch(`${url}/files/${offer.id}`, { headers })).status, 409);
  await sendLocalFile(new URL(url), token, path, { deviceId: 'legacy' }); const oldId = offer.id;
  ws.close(); await once(ws, 'close');
  assert.equal((await fetch(`${url}/files/${oldId}`, { headers })).status, 409);
  await assert.rejects(sendLocalFile(new URL(url), token, dir), /regular file/);
  await assert.rejects(sendLocalFile(new URL(url), token, 'relative.png'), /absolute/);
  try {
    await symlink(path, join(dir, 'link.png'));
  } catch (error) {
    // Windows grants symlink creation only to elevated or Developer Mode sessions.
    if ((error as NodeJS.ErrnoException).code !== 'EPERM') throw error;
    t.diagnostic('symlink rejection not exercised: this session cannot create symlinks');
    return;
  }
  await assert.rejects(sendLocalFile(new URL(url), token, join(dir, 'link.png')), /cannot be opened/);
});
