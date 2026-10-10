import { PhoneHub } from './hub.js';

const hub = new PhoneHub({ token: process.env.PHONEBRIDGE_TOKEN ?? '', host: '127.0.0.1', port: 0 });
let stopping = false;
const stop = () => {
  if (stopping) return;
  stopping = true;
  void hub.close().catch(() => undefined).finally(() => process.exit(0));
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
// A forced parent termination also closes its private IPC channel.
process.on('disconnect', stop);
hub.start().then(url => {
  if (!process.connected || stopping) { stop(); return; }
  process.send?.({ type: 'ready', url }, error => { if (error) stop(); });
}).catch(() => process.exit(1));
