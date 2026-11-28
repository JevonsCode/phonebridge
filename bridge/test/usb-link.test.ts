import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import WebSocket from 'ws';
import { DesktopSupervisor } from '../dist/supervisor.js';
import { UsbLinkWatcher, adbCandidates, linkScript, pairScript, parseAdbDevices, parseBroadcastReply, usbTokenDigest } from '../dist/usb-link.js';

test('token digest matches the Android definition', () => {
  assert.equal(usbTokenDigest('a'.repeat(43)), '7b3c0197e8f675e53e14ac4248bd8fe02a0982ba394c72b3f469da602805c616');
});

test('adb device list parsing keeps authorization state and ignores noise', () => {
  const devices = parseAdbDevices([
    '* daemon not running; starting now at tcp:5037', 'List of devices attached',
    '0123abcd               device usb:1-1 product:tokay model:Pixel_9 device:tokay transport_id:8',
    'R5CX unauthorized usb:1-1 transport_id:9', 'emulator-5554 offline', 'bad;serial device', '',
  ].join('\n'));
  assert.deepEqual(devices, [
    { serial: '0123abcd', state: 'device', model: 'Pixel 9', product: 'tokay', device: 'tokay' },
    { serial: 'R5CX', state: 'unauthorized' },
    { serial: 'emulator-5554', state: 'offline' },
  ]);
});

test('broadcast replies distinguish old apps from current ones', () => {
  assert.deepEqual(parseBroadcastReply('Broadcasting: Intent { act=x }\nBroadcast completed: result=-1, data="{\\"protocol\\":1,\\"state\\":\\"connected_usb\\",\\"versionName\\":\\"0.9.0\\",\\"versionCode\\":4033}"'),
    { state: 'connected_usb', versionName: '0.9.0', versionCode: 4033 });
  // Real Android 16 output: the JSON is printed without escaping.
  assert.deepEqual(parseBroadcastReply('Broadcasting: Intent { act=dev.phonebridge.phonebridge.USB_LINK flg=0x400020 cmp=dev.phonebridge.phonebridge/.UsbLinkReceiver (has extras) }\nBroadcast completed: result=-1, data="{"protocol":1,"state":"unknown","versionName":"0.9.0","versionCode":4033}"\n'),
    { state: 'unknown', versionName: '0.9.0', versionCode: 4033 });
  assert.deepEqual(parseBroadcastReply('Broadcast completed: result=0'), { state: 'app_outdated' });
  assert.deepEqual(parseBroadcastReply('error: closed'), { state: 'unreachable' });
  assert.deepEqual(parseBroadcastReply('Broadcast completed: result=-1, data="{\\"state\\":\\"$(rm)\\"}"'), { state: 'unreachable' });
});

test('shell scripts only contain validated values and travel over stdin', () => {
  const token = 'b'.repeat(43);
  assert.match(linkScript(usbTokenDigest(token), 8767), /^am broadcast -a dev\.phonebridge\.phonebridge\.USB_LINK -n dev\.phonebridge\.phonebridge\/\.UsbLinkReceiver --include-stopped-packages --es computer [a-f0-9]{64} --ei port 8767\nexit\n$/);
  const script = pairScript(token, 8767, 'ws://192.168.1.20:8767/device', "Jev's Mac; rm -rf /");
  assert.ok(script.includes(`--es token ${token}`));
  assert.ok(script.includes("--es name 'Jevs Mac rm -rf '"));
  assert.throws(() => pairScript('short', 8767, undefined, 'x'));
  assert.throws(() => pairScript(token, 80, undefined, 'x'));
  assert.throws(() => pairScript(token, 8767, 'ws://evil.example:8767/device', 'x'));
  assert.throws(() => linkScript('zz', 8767));
});

test('adb lookup covers PATH, SDK variables and platform defaults', () => {
  const mac = adbCandidates('darwin', { PATH: '/usr/bin:/opt/tools', ANDROID_HOME: '/sdk' }, '/Users/me');
  assert.deepEqual(mac.slice(0, 3), ['/sdk/platform-tools/adb', '/usr/bin/adb', '/opt/tools/adb']);
  assert.ok(mac.includes('/Users/me/Library/Android/sdk/platform-tools/adb'));
  assert.ok(adbCandidates('win32', { PATH: '', LOCALAPPDATA: 'C:\\Users\\me\\AppData\\Local' }, 'C:\\Users\\me').some(path => path.endsWith('adb.exe')));
});

function fakeAdb(replies: { devices: string; link: string; installed?: boolean }) {
  const calls: { args: string[]; input?: string }[] = [];
  const runner = async (args: string[], input?: string) => {
    calls.push({ args, input });
    if (args[0] === 'devices') return { code: 0, stdout: replies.devices };
    if (args.includes('reverse')) return { code: 0, stdout: '8767\n' };
    if (args.includes('pm')) return { code: 0, stdout: replies.installed === false ? '' : 'package:/data/app/base.apk' };
    if (input?.startsWith('am broadcast')) return { code: 0, stdout: replies.link };
    if (input?.startsWith('am start')) return { code: 0, stdout: 'Starting: Intent\nStatus: ok\nComplete\n' };
    return { code: 1, stdout: '' };
  };
  return { calls, runner };
}

test('a new phone gets one pairing prompt per plug-in; known phones only get a route', async () => {
  const token = randomBytes(32).toString('base64url');
  const devices = 'List of devices attached\nSER1 device model:Pixel_9\n';
  const unknown = fakeAdb({ devices, link: 'Broadcast completed: result=-1, data="{\\"state\\":\\"unknown\\",\\"versionName\\":\\"0.9.0\\"}"' });
  let now = 0;
  const watcher = new UsbLinkWatcher({ token, phonePort: 8767, loopbackPort: () => 50000, endpoint: () => 'ws://192.168.1.5:8767/device', runner: unknown.runner, now: () => now, computerName: 'Desk' });
  await watcher.scan();
  assert.equal(watcher.status().phones[0]?.state, 'pairing_requested');
  assert.equal(watcher.status().phones[0]?.model, 'Pixel 9');
  assert.deepEqual(unknown.calls[1]?.args, ['-s', 'SER1', 'reverse', 'tcp:8767', 'tcp:50000']);
  const starts = () => unknown.calls.filter(call => call.input?.startsWith('am start')).length;
  assert.equal(starts(), 1);
  assert.ok(!unknown.calls.some(call => call.args.some(arg => arg.includes(token))), 'token never appears in adb arguments');
  now = 60000; await watcher.scan();
  assert.equal(starts(), 1, 'no repeated prompt while still plugged in');
  const known = fakeAdb({ devices, link: 'Broadcast completed: result=-1, data="{\\"state\\":\\"connected_usb\\"}"' });
  const second = new UsbLinkWatcher({ token, phonePort: 8767, loopbackPort: () => 50000, endpoint: () => undefined, runner: known.runner });
  await second.scan();
  assert.equal(second.status().phones[0]?.state, 'connected_usb');
  assert.equal(known.calls.filter(call => call.input?.startsWith('am start')).length, 0);
  await watcher.close(); await second.close();
  assert.ok(!known.calls.some(call => call.args.includes('--remove')), 'a replacement supervisor keeps its tunnel');
});

test('missing apps, unauthorized phones and absent adb are reported, not guessed', async () => {
  const token = randomBytes(32).toString('base64url');
  const missing = fakeAdb({ devices: 'A device\nB unauthorized\n', link: 'Broadcast completed: result=0', installed: false });
  const watcher = new UsbLinkWatcher({ token, phonePort: 8767, loopbackPort: () => 50000, endpoint: () => undefined, runner: missing.runner });
  await watcher.scan();
  assert.deepEqual(watcher.status().phones.map(phone => [phone.serial, phone.state]), [['A', 'app_missing'], ['B', 'unauthorized']]);
  const none = new UsbLinkWatcher({ token, phonePort: 8767, loopbackPort: () => 50000, endpoint: () => undefined, adbPath: null });
  assert.deepEqual(none.status(), { available: false, adbFound: false, loopbackPort: 50000, phonePort: 8767, phones: [] });
});

test('supervisor serves the phone over its USB loopback listener and exposes USB status', async t => {
  const token = randomBytes(32).toString('base64url');
  const fake = fakeAdb({ devices: 'List of devices attached\n', link: '' });
  const supervisor = new DesktopSupervisor({ token, port: 0, autoStart: false, usbLink: { loopbackPort: 0, runner: fake.runner, intervalMs: 60000 } });
  const url = await supervisor.start();
  t.after(() => supervisor.close());
  const headers = { Authorization: `Bearer ${token}` };
  assert.equal((await fetch(`${url}/usb`)).status, 401);
  const status = await (await fetch(`${url}/usb`, { headers })).json();
  assert.equal(status.available, true);
  assert.ok(Number.isInteger(status.loopbackPort) && status.loopbackPort !== Number(new URL(url).port));
  const loopback = `http://127.0.0.1:${status.loopbackPort}`;
  assert.deepEqual(await (await fetch(`${loopback}/health`)).json(), { ok: true, protocol: 1 });
  assert.equal((await fetch(`${loopback}/usb`)).status, 401);
  assert.equal((await fetch(`${url}/usb/pair`, { method: 'POST', headers, body: '{"serial":"none"}' })).status, 409);
  assert.equal((await fetch(`${url}/usb/pair`, { method: 'POST', headers, body: 'x' })).status, 400);
  // Unauthenticated WebSocket upgrades are refused on the loopback listener too.
  const socket = new WebSocket(`ws://127.0.0.1:${status.loopbackPort}/device`);
  const code = await new Promise(resolve => { socket.once('unexpected-response', (_req, res) => resolve(res.statusCode)); socket.once('error', () => resolve('error')); });
  assert.equal(code, 401);
});
