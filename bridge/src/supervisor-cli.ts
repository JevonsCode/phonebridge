import { readFileSync } from 'node:fs';
import { DesktopSupervisor } from './supervisor.js';
import { credentialPath, loadOrCreateSavedToken } from './credentials.js';
import { startPairingDisplay } from './pairing.js';

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    console.log('PhoneBridge desktop supervisor\n  npm run supervisor -- --allow-lan --remember-pairing [--pairing-qr]\nUses the same PHONEBRIDGE_HOST/PORT, TLS and per-user pairing identity as the Hub. Keeps the endpoint available, restarts a crashed Hub and accepts authenticated phone recovery.'); return;
  }
  if (args.some(arg => !['--allow-lan', '--remember-pairing', '--pairing-qr'].includes(arg))) throw new Error('Unknown argument. Use --help.');
  const token = args.includes('--remember-pairing')
    ? await loadOrCreateSavedToken(credentialPath(), process.env.PHONEBRIDGE_TOKEN)
    : process.env.PHONEBRIDGE_TOKEN;
  if (!token) throw new Error('Use --remember-pairing or provide PHONEBRIDGE_TOKEN.');
  const port = Number(process.env.PHONEBRIDGE_PORT ?? 8765);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port.');
  const cert = process.env.PHONEBRIDGE_TLS_CERT, key = process.env.PHONEBRIDGE_TLS_KEY;
  if (!!cert !== !!key) throw new Error('Provide both TLS certificate and key.');
  const supervisor = new DesktopSupervisor({ token, host: process.env.PHONEBRIDGE_HOST, port, allowLan: args.includes('--allow-lan'),
    tls: cert && key ? { cert: readFileSync(cert), key: readFileSync(key) } : undefined });
  const url = await supervisor.start();
  let pairing: Awaited<ReturnType<typeof startPairingDisplay>> | undefined;
  try {
    if (args.includes('--pairing-qr')) pairing = await startPairingDisplay(process.env.PHONEBRIDGE_DEVICE_URL ?? `${url.replace(/^http/, 'ws')}/device`, token);
  } catch (error) { await supervisor.close(); throw error; }
  console.log(`PhoneBridge desktop management listening at ${url}\nHub recovery enabled. Existing pairing is retained.`);
  if (pairing) console.log(`Private pairing page: ${pairing.url}`);
  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    void Promise.all([supervisor.close(), pairing?.close()]).then(() => { process.exitCode = 0; });
  };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
}
main().catch(error => { console.error(error instanceof Error ? error.message : 'Desktop startup failed.'); process.exitCode = 1; });
