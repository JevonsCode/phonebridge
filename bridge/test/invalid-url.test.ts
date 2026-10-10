import test from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import net from 'node:net';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

function rawRequest(url: string, token: string, target: string): Promise<string> {
  const endpoint = new URL(url);
  return new Promise((resolve, reject) => {
    const socket = net.connect(Number(endpoint.port), endpoint.hostname);
    const chunks: Buffer[] = [];
    socket.setTimeout(3000, () => socket.destroy(new Error('Raw request timed out.')));
    socket.on('error', reject);
    socket.on('data', data => chunks.push(data));
    socket.on('close', () => resolve(Buffer.concat(chunks).toString('utf8')));
    socket.once('connect', () => socket.write(`GET ${target} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${token}\r\nConnection: close\r\n\r\n`));
  });
}

for (const service of ['hub', 'supervisor']) {
  test(`${service} rejects malformed authenticated URL without crashing its process`, async t => {
    const token = randomBytes(32).toString('base64url');
    const child = fork(fileURLToPath(new URL('./fixtures/invalid-url-service.mjs', import.meta.url)), [], {
      env: { ...process.env, PHONEBRIDGE_TOKEN: token, TEST_SERVICE: service },
      execArgv: ['--import', 'tsx'], stdio: ['ignore', 'ignore', 'ignore', 'ipc'], windowsHide: true,
    });
    t.after(async () => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      const exit = once(child, 'exit');
      if (child.connected) child.disconnect(); else child.kill();
      await Promise.race([exit, delay(2000).then(() => child.kill())]);
    });
    const ready = await Promise.race([once(child, 'message'), delay(5000).then(() => { throw new Error('URL regression child startup timed out.'); })]);
    const url = (ready[0] as { url: string }).url;
    for (const target of ['http://[', 'http://[::1']) {
      const response = await rawRequest(url, token, target);
      assert.match(response, /^HTTP\/1\.1 400 /);
      assert.match(response, /INVALID_URL/);
      assert.equal(child.exitCode, null);
      const health = await fetch(`${url}/health`);
      assert.equal(health.status, 200);
      assert.deepEqual(await health.json(), { ok: true, protocol: 1 });
    }
  });
}
