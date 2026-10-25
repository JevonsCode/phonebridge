import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm, writeFile, rename } from 'node:fs/promises';
import { tmpdir, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { desktopEndpointSource } from '../src/desktop-endpoint.js';

async function fixture(t: TestContext) {
  const root = await mkdtemp(join(tmpdir(), 'phonebridge-endpoint-')); t.after(() => rm(root, { recursive: true, force: true }));
  const host = Object.values(networkInterfaces()).flat().find(item => item?.family === 'IPv4' && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(item.address))?.address;
  if (!host) { t.skip('No local private IPv4 interface'); return; }
  const windows = process.platform === 'win32';
  const configFile = join(root, windows ? 'desktop.json' : 'desktop-macos.json'), credentialFile = join(root, 'pairing.json');
  const owner = windows ? spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'], { encoding: 'utf8', windowsHide: true }).stdout.trim() : process.getuid?.();
  const config = { schema: windows ? 'phonebridge-desktop-v1' : 'phonebridge-macos-desktop-v1', ...(windows ? { ownerSid: owner } : { ownerUid: owner }), hostAddress: host, port: 8767, credentialFile };
  const save = async (value: unknown) => { const temporary = configFile + '.new'; await writeFile(temporary, JSON.stringify(value), { mode: 0o600 }); await rename(temporary, configFile); };
  await save(config);
  return { root, host, windows, configFile, credentialFile, config, save };
}

test('owned endpoint metadata follows atomic host/port updates and rejects foreign identity or credentials', async t => {
  const f = await fixture(t); if (!f) return;
  const source = desktopEndpointSource(new URL('http://127.0.0.1:8765'), { configFile: f.configFile, credentialFile: f.credentialFile });
  assert.equal((await source())?.href, `http://${f.host}:8767/`);
  await f.save({ ...f.config, port: 9876 }); assert.equal((await source())?.href, `http://${f.host}:9876/`);
  await f.save({ ...f.config, ...(f.windows ? { ownerSid: 'S-1-0-0' } : { ownerUid: -1 }) }); assert.equal(await source(), undefined);
  await f.save({ ...f.config, credentialFile: join(f.root, 'foreign-pairing.json') }); assert.equal(await source(), undefined);
  await f.save({ ...f.config, hostAddress: '8.8.8.8' }); assert.equal(await source(), undefined);
});

test('legacy private endpoint with matching credential follows its install; standalone loopback never adopts it', async t => {
  const f = await fixture(t); if (!f) return;
  const options = { configFile: '', credentialFile: f.credentialFile, stateDirectory: f.root };
  const legacy = desktopEndpointSource(new URL(`http://${f.host}:8000`), options);
  assert.equal((await legacy())?.href, `http://${f.host}:8767/`);
  await f.save({ ...f.config, port: 9876 }); assert.equal((await legacy())?.href, `http://${f.host}:9876/`);
  assert.equal(await desktopEndpointSource(new URL('http://127.0.0.1:8765'), options)(), undefined);
});
