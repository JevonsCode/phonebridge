import test from 'node:test';
import assert from 'node:assert/strict';
import { createSocket, type Socket } from 'node:dgram';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { DesktopSupervisor, supervisorOptionsForPlatform } from '../dist/supervisor.js';
import { discoveryIdentity, discoveryProof, trustedDiscoveryResponse, TrustedDiscoveryResponder } from '../dist/discovery.js';

const token = 'a'.repeat(32);
const nonce = '00112233445566778899aabbccddeeff';
const endpoint = 'ws://192.168.1.159:8767/device';
const identity = '2b73005894ab0b082c4d5e4c3c1ea783b154e94dcab3d34739c039bd1dee9cdd';
const proof = 'c94775d725763a9532b403de1b1713f2fb9bc6e21c055439bcb6665471c0d146';
const challenge = { type: 'phonebridge_discover', version: 1, identity, nonce };

test('discovery matches the shared Android HMAC vector and binds the nonce and exact endpoint', () => {
  assert.equal(discoveryIdentity(token), identity);
  assert.equal(discoveryProof(token, identity, nonce, endpoint), proof);
  assert.deepEqual(trustedDiscoveryResponse(token, challenge, endpoint), { type: 'phonebridge_found', version: 1, identity, nonce, endpoint, proof });
  assert.notEqual(discoveryProof(token, identity, '0'.repeat(32), endpoint), proof);
  assert.notEqual(discoveryProof(token, identity, nonce, endpoint.replace('.159:', '.153:')), proof);
  assert.notEqual(discoveryIdentity('b'.repeat(32)), identity);
  assert.ok(trustedDiscoveryResponse(token, challenge, 'ws://192.168.1.159:80/device'));
  assert.ok(trustedDiscoveryResponse(token, challenge, 'wss://192.168.1.159:443/device'));
});

test('discovery has no response for a foreign identity, malformed challenge or unsafe endpoint', () => {
  for (const request of [undefined, null, [], 'value', { ...challenge, identity: '0'.repeat(64) },
    { ...challenge, identity: identity.toUpperCase() }, { ...challenge, nonce: '' }, { ...challenge, nonce: 'f'.repeat(33) },
    { ...challenge, version: 2 }, { ...challenge, type: 'phonebridge_found' }]) {
    assert.equal(trustedDiscoveryResponse(token, request, endpoint), undefined);
  }
  for (const address of [undefined, 'ws://0.0.0.0:8767/device', 'ws://8.8.8.8:8767/device', 'ws://127.0.0.1:8767/device',
    'ws://192.168.1.2/device', 'ws://192.168.1.2:8767/device?token=secret', 'http://192.168.1.2:8767/device',
    'ws://secret@192.168.1.2:8767/device', 'ws://192.168.1.2:8767/other']) {
    assert.equal(trustedDiscoveryResponse(token, challenge, address), undefined);
  }
});

async function client(): Promise<Socket> {
  const socket = createSocket('udp4');
  socket.bind(0, '127.0.0.1'); await once(socket, 'listening');
  return socket;
}
async function receive(socket: Socket, timeout = 1000): Promise<Buffer | undefined> {
  return new Promise((resolve, reject) => {
    const cleanup = () => { clearTimeout(timer); socket.off('message', message); socket.off('error', error); };
    const message = (bytes: Buffer) => { cleanup(); resolve(bytes); };
    const error = (failure: Error) => { cleanup(); reject(failure); };
    const timer = setTimeout(() => { cleanup(); resolve(undefined); }, timeout);
    socket.once('message', message); socket.once('error', error);
  });
}

test('real UDP socket replies only to a matching paired identity and may advertise another local interface', async t => {
  const responder = new TrustedDiscoveryResponder({ token, endpoint: () => endpoint, host: '127.0.0.1', port: 0, allowLoopback: true });
  await responder.start(); t.after(() => responder.close());
  const socket = await client(); t.after(() => socket.close());
  for (const packet of [JSON.stringify({ ...challenge, identity: 'f'.repeat(64) }), '{invalid', 'x'.repeat(1025)]) {
    const response = receive(socket, 80); socket.send(packet, responder.port!, '127.0.0.1');
    assert.equal(await response, undefined, 'Unpaired or malformed input must remain silent');
  }
  const response = receive(socket); socket.send(JSON.stringify(challenge), responder.port!, '127.0.0.1');
  const bytes = await response; assert.ok(bytes);
  assert.deepEqual(JSON.parse(bytes.toString()), { type: 'phonebridge_found', version: 1, identity, nonce, endpoint, proof });
  assert.equal(bytes.toString().includes(token), false, 'The pairing credential never crosses discovery');
  const port = responder.port!; await responder.close();
  const replacement = createSocket('udp4'); t.after(() => replacement.close());
  replacement.bind(port, '127.0.0.1'); await once(replacement, 'listening');
});

test('Supervisor advertises its actual listening port over UDP and TCP even with the Hub stopped', async t => {
  const supervisor = new DesktopSupervisor({ token, port: 0, autoStart: false,
    discovery: { host: '127.0.0.1', port: 0, allowLoopback: true } });
  const url = await supervisor.start(); t.after(() => supervisor.close());
  assert.equal(supervisor.managedProcessId, undefined);
  assert.equal(supervisor.endpoint, url);
  assert.equal(supervisor.discoveryStatus.listening, true);
  const socket = await client(); t.after(() => socket.close());
  const response = receive(socket); socket.send(JSON.stringify(challenge), supervisor.discoveryStatus.port!, '127.0.0.1');
  const udp = JSON.parse((await response)!.toString());
  assert.equal(udp.endpoint, `${url.replace(/^http/, 'ws')}/device`);
  const query = new URLSearchParams({ identity, nonce });
  const tcp = await fetch(`${url}/discovery?${query}`);
  assert.equal(tcp.status, 200); assert.deepEqual(await tcp.json(), udp);
  assert.equal(supervisor.serviceRunning, false);
  for (const invalid of [new URLSearchParams({ identity: 'b'.repeat(64), nonce }), `${query}&nonce=${nonce}`, `${query}&extra=1`,
    new URLSearchParams({ identity, nonce: 'f'.repeat(300) }), new URLSearchParams({ identity })]) {
    assert.equal((await fetch(`${url}/discovery?${invalid}`)).status, 404);
  }
  assert.equal((await fetch(`${url}/discovery?${query}`, { method: 'POST' })).status, 404);
  assert.equal((await fetch(`${url}/discovery?${query}`, { headers: { Origin: 'https://other.example' } })).status, 403);
  assert.equal((await fetch(`${url}/status`)).status, 401);
  await supervisor.close(); assert.equal(supervisor.discoveryStatus.listening, false);
});

test('a failed public bind never starts a discovery responder or Hub', async t => {
  const listener = createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
  t.after(() => new Promise<void>(resolve => listener.close(() => resolve())));
  const address = listener.address(); assert.ok(address && typeof address !== 'string');
  const supervisor = new DesktopSupervisor({ token, port: address.port, discovery: { port: 0, allowLoopback: true } });
  await assert.rejects(supervisor.start(), /EADDRINUSE/);
  assert.equal(supervisor.discoveryStatus.listening, false); assert.equal(supervisor.managedProcessId, undefined);
  await supervisor.close(); await delay(5);
});

test('ordinary loopback supervisors leave production UDP discovery disabled', async t => {
  const supervisor = new DesktopSupervisor({ token, port: 0, autoStart: false });
  await supervisor.start(); t.after(() => supervisor.close());
  assert.deepEqual(supervisor.discoveryStatus, { listening: false });
});

test('Windows entry options disable UDP while retaining the signed HTTP challenge and Mac UDP options', async t => {
  const base = { token, port: 0, autoStart: false, discovery: { host: '127.0.0.1', port: 0, allowLoopback: true } };
  const options = supervisorOptionsForPlatform(base, 'win32');
  assert.equal(options.discovery, false);
  assert.deepEqual(supervisorOptionsForPlatform(base, 'darwin'), base);
  const supervisor = new DesktopSupervisor(options);
  const url = await supervisor.start(); t.after(() => supervisor.close());
  assert.deepEqual(supervisor.discoveryStatus, { listening: false });
  const response = await fetch(`${url}/discovery?${new URLSearchParams({ identity, nonce })}`);
  assert.equal(response.status, 200);
  const found = await response.json();
  assert.equal(found.endpoint, `${url.replace(/^http/, 'ws')}/device`);
  assert.equal(found.proof, discoveryProof(token, identity, nonce, found.endpoint));
  assert.equal(supervisor.managedProcessId, undefined);
  assert.equal((await fetch(`${url}/discovery?${new URLSearchParams({ identity: 'f'.repeat(64), nonce })}`)).status, 404);
});
