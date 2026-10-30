import { readMacConfig, macNetworks } from './lifecycle.mjs';
import { createNetworkRecovery, persistNetworkConfig } from '../network-transaction.mjs';
import { loadSavedToken, credentialPath } from '../../bridge/dist/credentials.js';
import { DesktopSupervisor } from '../../bridge/dist/supervisor.js';
import { dirname, join } from 'node:path';

async function main() {
  const path = process.argv[process.argv.indexOf('--config') + 1];
  if (!process.argv.includes('--config') || !path) throw new Error('Missing desktop configuration.');
  const config = await readMacConfig(path);
  const savedCredentialFile = config.credentialFile ?? credentialPath();
  const token = await loadSavedToken(savedCredentialFile);
  if (!token) throw new Error('Open PhoneBridge once to create the remembered pairing.');
  const recovery = createNetworkRecovery({ config, networks: macNetworks,
    readConfig: () => readMacConfig(path),
    createCandidate: async next => {
      const supervisor = new DesktopSupervisor({ token, phoneDirectoryPath: join(dirname(savedCredentialFile), 'phones.json'), host: next.hostAddress, port: next.port, allowLan: true,
        logFile: process.env.PHONEBRIDGE_LOG_FILE ?? join(dirname(savedCredentialFile), 'operations.jsonl') });
      try { await supervisor.start(); return supervisor; }
      catch (error) { await supervisor.close(); throw error; }
    },
    persist: (next, expected) => persistNetworkConfig(path, next, expected, {
      readConfig: () => readMacConfig(path),
    }),
    onError: () => console.error('PhoneBridge is waiting for an available private network; saved pairing is retained.'),
  });
  await recovery.ensure();
  recovery.watch();
  console.log(JSON.stringify({ service: 'phonebridge', ready: true }));
  let stopping = false;
  const stop = async () => { if (stopping) return; stopping = true; await recovery.close(); };
  process.on('SIGINT', () => void stop()); process.on('SIGTERM', () => void stop());
}
main().catch(() => { console.error('PhoneBridge service unavailable. Open the App to check the network and restart.'); process.exitCode = 1; });
