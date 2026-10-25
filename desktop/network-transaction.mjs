import { readFile, writeFile, rename, unlink } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { privateIPv4 } from './network.mjs';
import { withConfigurationLock, publishWindowsConfiguration } from './configuration-lock.mjs';

// One network change owns the configuration file and supervisor until it commits or fails.
export function serializeNetworkChange(change) {
  let pending = false;
  return async address => {
    if (pending) throw new Error('A network change is already in progress.');
    pending = true;
    try { return await change(address); } finally { pending = false; }
  };
}

export function recoveryAddress(configured, networks) {
  // A still-local address is an explicit choice, even if another adapter ranks higher.
  if (networks.some(network => network.address === configured)) return configured;
  const physical = networks.find(network => network.physical === true && network.active !== false &&
    !network.internal && privateIPv4(network.address) && !/vpn|tailscale|wireguard|tap|tun|virtual|vethernet|docker|hyper-v/i.test(network.name ?? ''));
  if (!physical) throw new Error('Connect this computer to a private Wi-Fi or Ethernet network.');
  return physical.address;
}

/** Validate ownership again before replacing only the endpoint of the observed configuration. */
export async function persistNetworkConfig(path, next, expected, { readConfig } = {}) {
  if (!privateIPv4(next.hostAddress)) throw new Error('Network recovery requires a private LAN address.');
  const current = readConfig ? await readConfig() : JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, ''));
  if (!isDeepStrictEqual(current, expected)) throw new Error('Desktop configuration changed. The newer configuration was preserved.');
  if (Object.keys(next).some(key => key !== 'hostAddress' && !isDeepStrictEqual(next[key], current[key])) ||
    Object.keys(current).some(key => key !== 'hostAddress' && !(key in next))) throw new Error('Network recovery may only update the saved address.');
  const backup = `${path}.network-backup-${randomBytes(8).toString('hex')}`;
  const temporary = `${path}.tmp-${randomBytes(8).toString('hex')}`;
  let published = false;
  try {
    await writeFile(backup, JSON.stringify(current), { flag: 'wx', mode: 0o600 });
    await writeFile(temporary, JSON.stringify(next), { flag: 'wx', mode: 0o600 });
    // Recheck after the temporary write so another desktop's active choice wins.
    const latest = readConfig ? await readConfig() : JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, ''));
    if (!isDeepStrictEqual(latest, expected)) throw new Error('Desktop configuration changed. The newer configuration was preserved.');
    if (process.platform === 'win32') await publishWindowsConfiguration(path, temporary, expected);
    else await withConfigurationLock(path, async () => {
      const locked = readConfig ? await readConfig() : JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, ''));
      if (!isDeepStrictEqual(locked, expected)) throw new Error('Desktop configuration changed. The newer configuration was preserved.');
      await rename(temporary, path);
    });
    published = true;
  } finally {
    await unlink(temporary).catch(() => {});
    // Repeated retries on a locked/full disk must not accumulate recovery copies.
    if (!published) await unlink(backup).catch(() => {});
  }
}

/** Owns only supervisors it created; the working listener survives failed migration. */
export function createNetworkRecovery({ config, networks, createCandidate, persist, readConfig, intervalMs = 4000, onError = () => {}, onReady = () => {} }) {
  let supervisor, boundAddress, pending, timer, stopping = false;
  const serviceIdentity = value => Object.fromEntries(['schema', 'ownerSid', 'ownerUid', 'projectRoot', 'nodePath', 'port', 'credentialFile', 'launcherPath', 'powershellPath', 'runtimeRevision'].map(key => [key, value[key]]));
  const initialIdentity = serviceIdentity(config);
  const update = async address => {
    if (stopping) throw new Error('Desktop service is stopping.');
    const available = await networks();
    const boundIsLocal = supervisor && available.some(network => network.address === boundAddress);
    if (!boundIsLocal && readConfig) {
      const saved = await readConfig();
      if (!isDeepStrictEqual(serviceIdentity(saved), initialIdentity)) throw new Error('Desktop service configuration changed. The newer configuration was preserved.');
      for (const key of Object.keys(config)) if (!(key in saved)) delete config[key];
      Object.assign(config, saved);
    }
    const selected = address ?? (boundIsLocal ? boundAddress : recoveryAddress(config.hostAddress, available));
    if (address && !available.some(network => network.address === address)) throw new Error('Select an active private network.');
    if (supervisor && selected === boundAddress) { await supervisor.ensureRunning(); return supervisor; }
    const previous = supervisor, expected = { ...config }, next = { ...config, hostAddress: selected };
    const candidate = await createCandidate(next);
    try {
      if (stopping) throw new Error('Desktop service is stopping.');
      if (selected !== config.hostAddress) await persist(next, expected);
    } catch (error) { await candidate.close().catch(() => {}); throw error; }
    supervisor = candidate; boundAddress = selected;
    Object.assign(config, next);
    await previous?.close();
    return candidate;
  };
  const ensure = () => {
    if (!pending) pending = update().then(result => { onReady(result); return result; }).finally(() => { pending = undefined; });
    return pending;
  };
  return {
    get supervisor() { return supervisor; },
    ensure,
    async change(address) {
      if (pending) await pending;
      pending = update(address).then(result => { onReady(result); return result; }).finally(() => { pending = undefined; });
      return pending;
    },
    watch() {
      if (!timer && !stopping) { timer = setInterval(() => { void ensure().catch(onError); }, intervalMs); timer.unref?.(); }
    },
    async close() {
      stopping = true; clearInterval(timer);
      await pending?.catch(() => {});
      await supervisor?.close();
    },
  };
}
