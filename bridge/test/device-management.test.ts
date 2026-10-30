import test from 'node:test';
import assert from 'node:assert/strict';
import { request as httpRequest } from 'node:http';
import { once } from 'node:events';
import { randomBytes, randomUUID } from 'node:crypto';
import WebSocket from 'ws';
import { PhoneHub } from '../src/hub.js';
import { PhoneDirectory } from '../src/phone-directory.js';
import { MemoryOperationJournal } from '../src/operation-journal.js';

test('owner management renames, pauses, resumes and removes exactly one phone', async t => {
  const token = randomBytes(32).toString('base64url');
  const hub = new PhoneHub({ token, port: 0, journal: new MemoryOperationJournal(), phoneDirectory: new PhoneDirectory() });
  const url = await hub.start(); t.after(() => hub.close()); const headers = { Authorization: `Bearer ${token}` };
  const ids = [randomUUID(), randomUUID()], registrations = [randomUUID(), randomUUID()];
  async function connect(i: number, registrationId = registrations[i]!) {
    const ws = new WebSocket(url.replace('http', 'ws') + '/device', { headers }); t.after(() => ws.terminate()); await once(ws, 'open');
    ws.send(JSON.stringify({ type: 'hello', protocol: 2, deviceId: ids[i], device: `Model ${i}`, registrationId, readOnly: true, capabilities: [] })); return ws;
  }
  const status = async () => (await (await fetch(`${url}/devices`, { headers })).json()).devices;
  async function waitFor(predicate: (devices: any[]) => boolean) {
    const deadline = Date.now() + 3000; while (!predicate(await status())) { assert.ok(Date.now() < deadline); await new Promise(r => setTimeout(r, 10)); }
  }
  const manage = (action: string, name?: string) => fetch(`${url}/device-management`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: ids[0], action, ...(name ? { name } : {}) }) });
  let a = await connect(0); await connect(1); await waitFor(ds => ds.filter(d => d.connected).length === 2);
  assert.equal((await manage('rename', 'Work phone')).status, 200); assert.equal((await status()).find((d: any) => d.id === ids[0]).name, 'Work phone');
  const unicodeBody = Buffer.from(JSON.stringify({ id: ids[0], action: 'rename', name: '工作手机' }));
  await new Promise<void>((resolve, reject) => {
    const request = httpRequest(`${url}/device-management`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json', 'Content-Length': unicodeBody.length } }, response => {
      response.resume(); response.on('end', () => { try { assert.equal(response.statusCode, 200); resolve(); } catch (e) { reject(e); } });
    }); request.on('error', reject);
    void (async () => { for (const byte of unicodeBody) { request.write(Buffer.from([byte])); await new Promise(r => setTimeout(r, 1)); } request.end(); })().catch(reject);
  });
  assert.equal((await status()).find((d: any) => d.id === ids[0]).name, '工作手机');
  let closed = once(a, 'close'); assert.equal((await manage('disconnect')).status, 200); assert.equal((await closed)[0], 4003);
  await waitFor(ds => ds.find(d => d.id === ids[0])?.paused && ds.find(d => d.id === ids[1])?.connected);
  a = await connect(0); assert.equal((await once(a, 'close'))[0], 4003);
  assert.equal((await manage('resume')).status, 200); a = await connect(0); await waitFor(ds => ds.filter(d => d.connected).length === 2);
  closed = once(a, 'close'); assert.equal((await manage('delete')).status, 200); assert.equal((await closed)[0], 4004);
  assert.equal((await status()).some((d: any) => d.id === ids[0]), false);
  a = await connect(0); assert.equal((await once(a, 'close'))[0], 4004);
  await connect(0, randomUUID()); await waitFor(ds => ds.filter(d => d.connected).length === 2);
  assert.equal((await status()).find((d: any) => d.id === ids[0]).name, 'Model 0');
});
