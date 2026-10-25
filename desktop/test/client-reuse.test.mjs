import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, writeFile, copyFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { windowsIdentity } from '../network.mjs';
import { dashboardIdentity, dashboardStatePath, reusableDashboardUrl } from '../server.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const close = server => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
const exited = child => child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : new Promise(resolve => child.once('exit', resolve));

test('dashboard namespace changes for bundle, runtime, and in-place code updates', () => {
  const options = { projectRoot: '/bundles/v1', nodePath: '/runtime/node', source: 'version-one', platform: 'win32' };
  const identity = dashboardIdentity(options);
  assert.equal(dashboardIdentity({ ...options, projectRoot: '/BUNDLES/V1' }), identity);
  for (const difference of [{ projectRoot: '/bundles/v2' }, { nodePath: '/runtime/new-node' }, { source: 'version-two' }]) {
    const changed = dashboardIdentity({ ...options, ...difference });
    assert.notEqual(changed, identity);
    assert.notEqual(dashboardStatePath('/settings/desktop.json', changed), dashboardStatePath('/settings/desktop.json', identity));
  }
  assert.throws(() => dashboardStatePath('/settings/desktop.json', '../bad'));
});

test('reuse requires the same identity in both record and live ping, with exact PID', async () => {
  const identity = 'b'.repeat(64);
  const url = `http://127.0.0.1:12345/session/${'c'.repeat(32)}`;
  const record = { ownerSid: 'same-owner', clientIdentity: identity, pid: 123, url };
  let calls = 0;
  let ping = { client: 'phonebridge-desktop', clientIdentity: identity, pid: 123 };
  const options = { ownerSid: 'same-owner', clientIdentity: identity, fetchImpl: async (requestUrl, init) => {
    calls++; assert.equal(requestUrl, url + '/ping'); assert.equal(init.redirect, 'error');
    return { ok: true, json: async () => ping };
  } };
  assert.equal(await reusableDashboardUrl(record, options), url);
  assert.equal(await reusableDashboardUrl({ ...record, clientIdentity: undefined }, options), null);
  assert.equal(await reusableDashboardUrl({ ...record, clientIdentity: 'd'.repeat(64) }, options), null);
  assert.equal(await reusableDashboardUrl(record, { ...options, expectedPid: 999 }), null);
  assert.equal(calls, 1, 'legacy and other-version records are rejected without probing');
  for (const mismatch of [{ clientIdentity: undefined }, { clientIdentity: 'd'.repeat(64) }, { pid: 999 }, { client: 'foreign' }]) {
    ping = { client: 'phonebridge-desktop', clientIdentity: identity, pid: 123, ...mismatch };
    assert.equal(await reusableDashboardUrl(record, options), null);
  }
  await assert.rejects(reusableDashboardUrl({ ...record, ownerSid: 'foreign-owner' }, options), /Untrusted/);
  for (const bad of [url + '?x=1', url + '\n', url.replace('127.0.0.1', 'localhost'), url.replace(':12345', ':012345'), url.replace(':12345', ':65536')]) {
    await assert.rejects(reusableDashboardUrl({ ...record, url: bad }, options), /Untrusted/);
  }
});

async function fixtureBundle(base, name) {
  const bundle = join(base, name);
  await mkdir(join(bundle, 'desktop'), { recursive: true });
  await mkdir(join(bundle, 'bridge', 'dist'), { recursive: true });
  await mkdir(join(bundle, 'bridge', 'node_modules', 'qrcode', 'lib'), { recursive: true });
  for (const file of ['server.mjs', 'network.mjs', 'network-transaction.mjs', 'configuration-lock.mjs', 'launcher-maintenance.mjs', 'recover-client-claim.ps1']) await copyFile(join(root, 'desktop', file), join(bundle, 'desktop', file));
  await writeFile(join(bundle, 'bridge', 'package.json'), '{"type":"module"}');
  await writeFile(join(bundle, 'bridge', 'dist', 'credentials.js'), 'export const credentialPath=()=>process.env.PHONEBRIDGE_CREDENTIAL_FILE; export const loadOrCreateSavedToken=async()=>"isolated-test-token";');
  await writeFile(join(bundle, 'bridge', 'dist', 'pairing.js'), 'export const pairingUri=()=>"test-pairing";');
  await writeFile(join(bundle, 'bridge', 'node_modules', 'qrcode', 'lib', 'index.js'), 'export default {toDataURL:async()=>"data:image/png;base64,TEST"};');
  return bundle;
}

function launch(bundle, env, children) {
  const child = spawn(process.execPath, [join(bundle, 'desktop', 'server.mjs'), '--native-window'], { env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  children.add(child);
  const ready = new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error('Isolated dashboard startup timed out')), 30000);
    child.stderr.resume();
    child.stdout.on('data', chunk => {
      output += chunk;
      if (output.includes('\n')) { clearTimeout(timer); try { resolve(JSON.parse(output.split('\n')[0])); } catch { reject(new Error('Invalid isolated ready message')); } }
    });
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', () => { if (!output) { clearTimeout(timer); reject(new Error('Isolated dashboard exited before readiness')); } });
  });
  return { child, ready };
}

test('new bundles ignore a live legacy dashboard and claim; reuse only their own dashboard', { skip: process.platform !== 'win32', timeout: 90000 }, async () => {
  const temp = await mkdtemp(join(tmpdir(), 'phonebridge-client-reuse-'));
  const children = new Set();
  let hubRequests = 0;
  const hub = createServer((req, res) => { assert.equal(req.headers.authorization, 'Bearer isolated-test-token'); hubRequests++; res.end('{"connected":true}'); });
  const legacy = createServer((req, res) => { res.end(JSON.stringify(req.url.endsWith('/ping') ? { client: 'phonebridge-desktop', pid: process.pid } : { connected: true, mcpConfiguration: { mcpServers: { phonebridge: { command: 'old-version-node.exe' } } } })); });
  await listen(hub); await listen(legacy);
  try {
    const bundleA = await fixtureBundle(temp, 'version-a');
    const bundleB = await fixtureBundle(temp, 'version-b');
    const configFile = join(temp, 'desktop.json');
    const credential = join(temp, 'pairing.json');
    const sid = windowsIdentity();
    const configBytes = JSON.stringify({ schema: 'phonebridge-desktop-v1', ownerSid: sid, projectRoot: bundleB, nodePath: process.execPath, hostAddress: '127.0.0.1', port: hub.address().port, credentialFile: credential, launcherPath: join(bundleB, 'run.ps1'), powershellPath: process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' });
    await writeFile(configFile, configBytes); await writeFile(credential, 'preserve-existing-pairing');
    const legacyUrl = `http://127.0.0.1:${legacy.address().port}/session/${'a'.repeat(32)}`;
    const legacyFile = join(temp, `client-${createHash('sha256').update(configFile.toLowerCase()).digest('hex').slice(0, 12)}.json`);
    const legacyBytes = JSON.stringify({ ownerSid: sid, pid: process.pid, url: legacyUrl });
    await writeFile(legacyFile, legacyBytes); await writeFile(legacyFile + '.lock', String(process.pid));
    const env = { ...process.env, PHONEBRIDGE_DESKTOP_TEST: '1', PHONEBRIDGE_DESKTOP_CONFIG: configFile, PHONEBRIDGE_CREDENTIAL_FILE: credential, PHONEBRIDGE_TOKEN: undefined };
    const first = launch(bundleA, env, children); const a = await first.ready;
    assert.notEqual(a.dashboardUrl, legacyUrl, 'new frontend must not reuse the old dashboard capability');
    assert.equal(a.reusedClient, undefined);
    const racers = [launch(bundleB, env, children), launch(bundleB, env, children)];
    const starts = await Promise.all(racers.map(item => item.ready));
    assert.equal(starts.filter(item => item.reusedClient).length, 1, 'same-bundle concurrent launches must share one dashboard');
    assert.equal(starts[0].dashboardUrl, starts[1].dashboardUrl);
    const ownerIndex = starts.findIndex(item => !item.reusedClient);
    const second = racers[ownerIndex], b = starts[ownerIndex];
    await exited(racers[1 - ownerIndex].child);
    assert.notEqual(b.dashboardUrl, a.dashboardUrl, 'different bundle roots must have independent dashboard claims');
    assert.equal(b.reusedClient, undefined);
    const same = launch(bundleB, env, children); const reused = await same.ready;
    assert.equal(reused.reusedClient, true); assert.equal(reused.dashboardUrl, b.dashboardUrl); await exited(same.child);
    const current = await (await fetch(b.dashboardUrl + '/status')).json();
    assert.equal(current.connected, true); assert.equal(current.mcpConfiguration.mcpServers.phonebridge.command, process.execPath);
    assert.equal(hubRequests > 0, true);
    assert.equal((await fetch(legacyUrl + '/ping')).status, 200, 'legacy process must remain untouched because it may own a supervisor');
    assert.equal(await readFile(legacyFile, 'utf8'), legacyBytes); assert.equal(await readFile(legacyFile + '.lock', 'utf8'), String(process.pid));
    assert.equal(await readFile(configFile, 'utf8'), configBytes); assert.equal(await readFile(credential, 'utf8'), 'preserve-existing-pairing');
    const states = (await readdir(temp)).filter(name => /^client-.*\.json$/.test(name));
    assert.equal(states.length, 3);
    for (const session of [a, b]) {
      const url = new URL(session.dashboardUrl);
      const result = await fetch(url + '/shutdown', { method: 'POST', headers: { Origin: url.origin, 'X-PhoneBridge-CSRF': url.pathname.split('/').pop() } }); assert.equal(result.status, 200);
    }
    await exited(first.child); await exited(second.child);
    assert.equal(hub.listening, true, 'dashboard cleanup must not stop the independent hub');
  } finally {
    for (const child of children) { if (child.exitCode === null && child.signalCode === null) child.kill(); await exited(child); }
    await close(hub); await close(legacy); await rm(temp, { recursive: true, force: true });
  }
});
