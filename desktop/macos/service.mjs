import { readMacConfig, macNetworks } from './lifecycle.mjs';
import { loadSavedToken, credentialPath } from '../../bridge/dist/credentials.js';
import { DesktopSupervisor } from '../../bridge/dist/supervisor.js';
import { dirname, join } from 'node:path';

async function main() {
  const path = process.argv[process.argv.indexOf('--config') + 1];
  if (!process.argv.includes('--config') || !path) throw new Error('Missing desktop configuration.');
  const config = await readMacConfig(path);
  if (!macNetworks().some(net => net.address === config.hostAddress)) throw new Error('The saved network is unavailable. Open PhoneBridge and select the current network.');
  const savedCredentialFile = config.credentialFile ?? credentialPath();
  const token = await loadSavedToken(savedCredentialFile);
  if (!token) throw new Error('Open PhoneBridge once to create the remembered pairing.');
  const supervisor = new DesktopSupervisor({ token, host: config.hostAddress, port: config.port, allowLan: true,
    logFile: process.env.PHONEBRIDGE_LOG_FILE ?? join(dirname(savedCredentialFile), 'operations.jsonl') });
  await supervisor.start();
  if (!supervisor.serviceRunning) { await supervisor.close(); throw new Error('The phone connection service could not start.'); }
  console.log(JSON.stringify({ service: 'phonebridge', ready: true }));
  let stopping = false;
  const stop = async () => { if (stopping) return; stopping = true; await supervisor.close(); };
  process.on('SIGINT', () => void stop()); process.on('SIGTERM', () => void stop());
}
main().catch(() => { console.error('PhoneBridge service unavailable. Open the App to check the network and restart.'); process.exitCode = 1; });
