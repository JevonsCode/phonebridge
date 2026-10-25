import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createNetworkRecovery, recoveryAddress, persistNetworkConfig } from '../network-transaction.mjs';
import { authenticatedStatus } from '../server.mjs';
import { publishWindowsConfiguration, withConfigurationLock } from '../configuration-lock.mjs';

const adapter = address => ({ name: 'Ethernet', address, physical: true, active: true });
const fixtureConfig = () => ({ schema: 'phonebridge-desktop-v1', ownerSid: 'test-owner', hostAddress: '192.168.1.153', port: 8767,
  credentialFile: '/private/existing-pairing.json', deviceName: 'Existing name', unknownSetting: { keep: true } });

test('a stale computer address never receives an authenticated status probe or pairing token', async () => {
  let requests = 0;
  await assert.rejects(authenticatedStatus(fixtureConfig(), 'never-send-this-token', {
    interfaces: { Ethernet: [{ address: '192.168.1.159' }] }, fetchImpl: async () => { requests++; },
  }), /no longer local/);
  assert.equal(requests, 0);
});

test('automatic recovery preserves an active selected address and never chooses VPN for a stale address', () => {
  const adapters = [adapter('192.168.1.159'), adapter('192.168.1.153')];
  assert.equal(recoveryAddress('192.168.1.153', adapters), '192.168.1.153');
  assert.equal(recoveryAddress('192.168.9.2', adapters), '192.168.1.159');
  assert.throws(() => recoveryAddress('192.168.9.2', [{ ...adapter('10.0.0.2'), name: 'Tailscale', physical: false }]), /private Wi-Fi/);
  assert.throws(() => recoveryAddress('192.168.9.2', [adapter('8.8.8.8')]), /private Wi-Fi/);
});

test('startup with a stale IP listens first and durably changes only the address, retaining pairing and port', async t => {
  const config = fixtureConfig(), order = [], candidate = { close: async () => order.push('close'), ensureRunning: async () => {} };
  const controller = createNetworkRecovery({ config, networks: () => [adapter('192.168.1.159')],
    createCandidate: async next => { order.push('listen'); assert.equal(next.hostAddress, '192.168.1.159'); return candidate; },
    persist: async (next, expected) => { order.push('persist'); assert.deepEqual(expected, fixtureConfig()); assert.deepEqual(next, { ...fixtureConfig(), hostAddress: '192.168.1.159' }); },
  });
  t.after(() => controller.close());
  assert.equal(await controller.ensure(), candidate);
  assert.deepEqual(order, ['listen', 'persist']);
  assert.deepEqual(config, { ...fixtureConfig(), hostAddress: '192.168.1.159' });
});

test('running DHCP recovery commits the new listener before closing the old listener', async t => {
  const config = fixtureConfig(), order = []; let address = config.hostAddress, count = 0;
  const controller = createNetworkRecovery({ config, networks: () => [adapter(address)], intervalMs: 5,
    createCandidate: async () => { const id = ++count; order.push(`listen:${id}`); return { ensureRunning: async () => {}, close: async () => order.push(`close:${id}`) }; },
    persist: async () => order.push('persist'),
  });
  t.after(() => controller.close());
  await controller.ensure(); controller.watch(); address = '192.168.1.159';
  for (let attempt = 0; attempt < 100 && config.hostAddress !== address; attempt++) await delay(5);
  assert.equal(config.hostAddress, address);
  assert.deepEqual(order, ['listen:1', 'listen:2', 'persist', 'close:1']);
  const countBefore = count; await delay(20); assert.equal(count, countBefore, 'Polling reuses the valid listener');
});

test('a newer owned valid address wins over automatic adapter ranking, and an upgraded service is never taken over', async t => {
  const config = fixtureConfig(), addresses = []; let saved = { ...config, hostAddress: '192.168.1.159' };
  const controller = createNetworkRecovery({ config, networks: () => [adapter('192.168.1.160'), adapter('192.168.1.159')],
    readConfig: async () => saved,
    createCandidate: async next => { addresses.push(next.hostAddress); return { close: async () => {}, ensureRunning: async () => {} }; },
    persist: async () => { throw new Error('A still-valid saved address must not be overwritten'); },
  });
  t.after(() => controller.close());
  await controller.ensure(); assert.deepEqual(addresses, ['192.168.1.159']);
  saved = { ...saved, projectRoot: '/upgraded/App' };
  const other = createNetworkRecovery({ config: fixtureConfig(), networks: () => [adapter('192.168.1.159')], readConfig: async () => saved,
    createCandidate: async () => { throw new Error('Should not replace upgraded service'); }, persist: async () => {},
  });
  await assert.rejects(other.ensure(), /newer configuration was preserved/); await other.close();
});

test('a failed new bind or config publication preserves the previous listener, configuration and credentials', async t => {
  for (const failure of ['bind', 'persist']) {
    const config = fixtureConfig(), original = structuredClone(config), closed = []; let count = 0, address = config.hostAddress;
    const controller = createNetworkRecovery({ config, networks: () => [adapter(address)],
      createCandidate: async () => { const id = ++count; if (id === 2 && failure === 'bind') throw new Error('occupied'); return { ensureRunning: async () => {}, close: async () => closed.push(id) }; },
      persist: async () => { throw new Error('disk full'); },
    });
    t.after(() => controller.close());
    const previous = await controller.ensure(); address = '192.168.1.159';
    await assert.rejects(controller.ensure(), failure === 'bind' ? /occupied/ : /disk full/);
    assert.equal(controller.supervisor, previous); assert.deepEqual(config, original);
    assert.deepEqual(closed, failure === 'bind' ? [] : [2]);
  }
});

test('concurrent recovery requests share one candidate and close cancels an uncommitted migration', async () => {
  const config = fixtureConfig(); let finish, created = 0, closed = 0, writes = 0;
  const controller = createNetworkRecovery({ config, networks: () => [adapter('192.168.1.159')],
    createCandidate: async () => { created++; await new Promise(resolve => { finish = resolve; }); return { close: async () => { closed++; } }; },
    persist: async () => { writes++; },
  });
  const first = controller.ensure(), second = controller.ensure(); assert.equal(first, second);
  while (!finish) await delay(1);
  const closing = controller.close(); finish();
  await assert.rejects(first, /stopping/); await closing;
  assert.equal(created, 1); assert.equal(closed, 1); assert.equal(writes, 0); assert.deepEqual(config, fixtureConfig());
});

test('atomic endpoint persistence preserves every other field and refuses a changed owned configuration', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'phonebridge-network-recovery-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'desktop.json'), config = fixtureConfig(), next = { ...config, hostAddress: '192.168.1.159' };
  await writeFile(path, JSON.stringify(config));
  await persistNetworkConfig(path, next, config);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), next);
  const backup = (await readdir(directory)).find(name => name.includes('.network-backup-'));
  assert.deepEqual(JSON.parse(await readFile(join(directory, backup), 'utf8')), config);
  await assert.rejects(persistNetworkConfig(path, { ...next, hostAddress: '192.168.2.1' }, config), /changed/);
  await assert.rejects(persistNetworkConfig(path, { ...next, credentialFile: 'new-pairing' }, next), /only update/);
  let reads = 0;
  await assert.rejects(persistNetworkConfig(path, { ...next, hostAddress: '192.168.2.1' }, next, {
    readConfig: async () => ++reads === 1 ? next : { ...next, hostAddress: '192.168.9.9' },
  }), /changed/);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), next);
  assert.equal((await readdir(directory)).some(name => name.includes('.tmp-')), false);
});

test('a new runtime published after the second read wins over the stale network writer', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'phonebridge-config-publish-race-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'desktop.json'), old = fixtureConfig();
  const upgraded = { ...old, projectRoot: '/new/App', runtimeRevision: 'new-runtime', credentialFile: '/private/new-pairing.json' };
  await writeFile(path, JSON.stringify(old));
  let reads = 0;
  await assert.rejects(persistNetworkConfig(path, { ...old, hostAddress: '192.168.1.159' }, old, {
    readConfig: async () => {
      const observed = JSON.parse(await readFile(path, 'utf8'));
      if (++reads === 2) {
        // The stale writer has already read its expected snapshot. A second
        // writer now commits the upgrade before the stale writer can publish.
        const temporary = join(directory, 'upgrade.tmp'); await writeFile(temporary, JSON.stringify(upgraded));
        if (process.platform === 'win32') await publishWindowsConfiguration(path, temporary, old);
        else await withConfigurationLock(path, async () => { const { rename } = await import('node:fs/promises'); await rename(temporary, path); });
      }
      return observed;
    },
  }), /configuration changed/);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), upgraded);
  assert.equal((await readdir(directory)).some(name => name.includes('.tmp-') || name.includes('.expected-')), false);
});
