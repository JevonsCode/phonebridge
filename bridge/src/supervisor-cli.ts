import { readFileSync } from 'node:fs';
import { DesktopSupervisor, supervisorOptionsForPlatform } from './supervisor.js';
import { credentialPath, loadOrCreateSavedToken } from './credentials.js';
import { startPairingDisplay } from './pairing.js';
import { dirname, join } from 'node:path';

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    console.log('PhoneBridge desktop supervisor\n  npm run supervisor -- --allow-lan --remember-pairing [--pairing-qr]\nUses the same PHONEBRIDGE_HOST/PORT, TLS and per-user pairing identity as the Hub. Keeps the endpoint available, restarts a crashed Hub and accepts authenticated phone recovery.'); return;
  }
  if (args.some(arg => !['--allow-lan', '--remember-pairing', '--pairing-qr'].includes(arg))) throw new Error('Unknown argument. Use --help.');
  const configFile = process.env.PHONEBRIDGE_DESKTOP_CONFIG;
  let config: { hostAddress: string; port: number; credentialFile?: string } | undefined;
  let desktop: any, network: any, transactions: any;
  if (configFile) {
    if (process.platform !== 'win32') throw new Error('The managed supervisor configuration requires Windows.');
    // The task passes an owned configuration path, rather than a stale IP snapshot.
    desktop = await import(new URL('../../desktop/server.mjs', import.meta.url).href);
    network = await import(new URL('../../desktop/network.mjs', import.meta.url).href);
    transactions = await import(new URL('../../desktop/network-transaction.mjs', import.meta.url).href);
    config = await desktop.readOwnedConfig(configFile, network.windowsIdentity());
  }
  const token = args.includes('--remember-pairing')
    ? await loadOrCreateSavedToken(config?.credentialFile ?? credentialPath(), process.env.PHONEBRIDGE_TOKEN)
    : process.env.PHONEBRIDGE_TOKEN;
  if (!token) throw new Error('Use --remember-pairing or provide PHONEBRIDGE_TOKEN.');
  const port = Number(config?.port ?? process.env.PHONEBRIDGE_PORT ?? 8765);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port.');
  const cert = process.env.PHONEBRIDGE_TLS_CERT, key = process.env.PHONEBRIDGE_TLS_KEY;
  if (!!cert !== !!key) throw new Error('Provide both TLS certificate and key.');
  const sharedOptions = supervisorOptionsForPlatform({ token, allowLan: args.includes('--allow-lan'),
    logFile: process.env.PHONEBRIDGE_LOG_FILE ?? (config?.credentialFile ? join(dirname(config.credentialFile), 'operations.jsonl') : undefined),
    tls: cert && key ? { cert: readFileSync(cert), key: readFileSync(key) } : undefined });
  let supervisor: DesktopSupervisor;
  let recovery: any;
  let maintenance: any;
  let url: string;
  if (config && configFile) {
    const ownerSid = network.windowsIdentity();
    const maintenanceModule = await import(new URL('../../desktop/launcher-maintenance.mjs', import.meta.url).href);
    maintenance = maintenanceModule.startLauncherMaintenance(configFile, { readConfig: () => desktop.readOwnedConfig(configFile, ownerSid) });
    recovery = transactions.createNetworkRecovery({ config, networks: network.localNetworks,
      readConfig: () => desktop.readOwnedConfig(configFile, ownerSid),
      createCandidate: async (next: { hostAddress: string; port: number }) => {
        const candidate = new DesktopSupervisor({ ...sharedOptions, host: next.hostAddress, port: next.port });
        try { await candidate.start(); return candidate; }
        catch (error) { await candidate.close(); throw error; }
      },
      persist: (next: unknown, expected: unknown) => transactions.persistNetworkConfig(configFile, next, expected,
        { readConfig: () => desktop.readOwnedConfig(configFile, ownerSid) }),
      onError: () => console.error('PhoneBridge is waiting for an available private network; saved pairing is retained.'),
    });
    supervisor = await recovery.ensure();
    recovery.watch();
    url = supervisor.endpoint!;
  } else {
    supervisor = new DesktopSupervisor({ ...sharedOptions, host: process.env.PHONEBRIDGE_HOST, port });
    url = await supervisor.start();
  }
  let pairing: Awaited<ReturnType<typeof startPairingDisplay>> | undefined;
  try {
    if (args.includes('--pairing-qr')) pairing = await startPairingDisplay(process.env.PHONEBRIDGE_DEVICE_URL ?? `${url.replace(/^http/, 'ws')}/device`, token);
  } catch (error) { await maintenance?.close(); await (recovery?.close() ?? supervisor.close()); throw error; }
  console.log(`PhoneBridge desktop management listening at ${url}\nHub recovery enabled. Existing pairing is retained.`);
  if (pairing) console.log(`Private pairing page: ${pairing.url}`);
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    void Promise.all([recovery?.close() ?? supervisor.close(), pairing?.close(), maintenance?.close()]).then(() => { process.exitCode = 0; });
  };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
}
main().catch(error => { console.error(error instanceof Error ? error.message : 'Desktop startup failed.'); process.exitCode = 1; });
