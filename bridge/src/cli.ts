import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { PhoneHub } from './hub.js';

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.includes('--help')) {
    console.log('PhoneBridge hub\n  npm start -- [--allow-lan] [--show-pairing]\nEnvironment: PHONEBRIDGE_TOKEN, PHONEBRIDGE_HOST, PHONEBRIDGE_PORT, PHONEBRIDGE_TLS_CERT, PHONEBRIDGE_TLS_KEY\nDefault: loopback:8765. --show-pairing explicitly displays a session secret; do not capture/share its output.'); return;
  }
  if (args.some(a => !['--allow-lan', '--show-pairing'].includes(a))) throw new Error('Unknown argument. Use --help.');
  const show = args.includes('--show-pairing');
  const token = process.env.PHONEBRIDGE_TOKEN ?? (show ? randomBytes(32).toString('base64url') : '');
  if (!token) throw new Error('Set PHONEBRIDGE_TOKEN or explicitly use --show-pairing to generate and display a session token.');
  const cert = process.env.PHONEBRIDGE_TLS_CERT, key = process.env.PHONEBRIDGE_TLS_KEY;
  if (!!cert !== !!key) throw new Error('Provide both TLS certificate and key paths.');
  const port = Number(process.env.PHONEBRIDGE_PORT ?? 8765);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port.');
  const hub = new PhoneHub({ token, host: process.env.PHONEBRIDGE_HOST, port, allowLan: args.includes('--allow-lan'), tls: cert && key ? { cert: readFileSync(cert), key: readFileSync(key) } : undefined });
  const url = await hub.start();
  console.log(`PhoneBridge listening at ${url}\nDevice endpoint: ${url.replace(/^http/, 'ws')}/device\nNo screen contents or commands are logged. Ctrl+C stops the hub.`);
  if (show) console.log(`PAIRING SECRET (keep private): ${token}`);
  let stopping = false;
  const stop = () => { if (stopping) return; stopping = true; void hub.close().then(() => { process.exitCode = 0; }); };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
}
main().catch(error => { console.error(error instanceof Error ? error.message : 'Startup failed.'); process.exitCode = 1; });
