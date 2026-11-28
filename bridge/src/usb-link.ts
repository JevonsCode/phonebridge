import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { accessSync, constants } from 'node:fs';
import { homedir, hostname } from 'node:os';
import { delimiter, join } from 'node:path';

/**
 * USB quick connect. The owner enables USB debugging and authorizes this computer in the
 * Android system dialog; PhoneBridge then uses adb only for `reverse` (a loopback tunnel)
 * and for two DUMP-protected intents. It never injects input or installs packages.
 */
export const androidPackage = 'dev.phonebridge.phonebridge';
const linkAction = `${androidPackage}.USB_LINK`;
const pairAction = `${androidPackage}.USB_PAIR`;

export function usbTokenDigest(token: string): string {
  return createHash('sha256').update(`phonebridge-usb-v1:${token}`).digest('hex');
}

export type AdbDevice = { serial: string; state: string; model?: string; product?: string; device?: string };

/** Parses `adb devices -l`. Unknown or malformed lines are ignored. */
export function parseAdbDevices(output: string): AdbDevice[] {
  const devices: AdbDevice[] = [];
  for (const line of output.split(/\r?\n/)) {
    const match = /^(\S+)\s+(device|unauthorized|offline|authorizing|no permissions|recovery|sideload|bootloader)\b(.*)$/.exec(line.trim());
    if (!match || line.startsWith('List of devices') || line.startsWith('*')) continue;
    const serial = match[1]!, state = match[2]!, rest = match[3] ?? '';
    if (!/^[A-Za-z0-9._:-]{1,128}$/.test(serial)) continue;
    const fields: Record<string, string> = {};
    for (const part of rest.trim().split(/\s+/)) {
      const index = part.indexOf(':');
      if (index > 0) fields[part.slice(0, index)] = part.slice(index + 1);
    }
    devices.push({ serial, state, ...(fields.model ? { model: fields.model.replace(/_/g, ' ') } : {}),
      ...(fields.product ? { product: fields.product } : {}), ...(fields.device ? { device: fields.device } : {}) });
  }
  return devices;
}

/** Parses the reply of `am broadcast` from UsbLinkReceiver. */
export function parseBroadcastReply(output: string): { state: string; versionName?: string; versionCode?: number } {
  // `am` prints the reply verbatim (unescaped) inside data="…" up to the end of the line.
  const match = /Broadcast completed: result=(-?\d+)(?:, data="(.*)")?\s*$/m.exec(output);
  if (!match) return { state: 'unreachable' };
  if (match[1] !== '-1' || match[2] === undefined) return { state: 'app_outdated' };
  try {
    const raw = match[2];
    let value;
    try { value = JSON.parse(raw); } catch { value = JSON.parse(raw.replace(/\\"/g, '"').replace(/\\\\/g, '\\')); }
    const state = typeof value.state === 'string' && /^[a-z_]{1,40}$/.test(value.state) ? value.state : 'unreachable';
    return { state, ...(typeof value.versionName === 'string' && value.versionName.length <= 40 ? { versionName: value.versionName } : {}),
      ...(Number.isSafeInteger(value.versionCode) ? { versionCode: value.versionCode } : {}) };
  } catch { return { state: 'unreachable' }; }
}

const shellSafe = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;

/** Shell script lines sent over stdin so the pairing key never appears in a process listing. */
export function linkScript(digest: string, port: number): string {
  if (!/^[a-f0-9]{64}$/.test(digest) || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid USB link.');
  return `am broadcast -a ${linkAction} -n ${androidPackage}/.UsbLinkReceiver --include-stopped-packages --es computer ${digest} --ei port ${port}\nexit\n`;
}

export function pairScript(token: string, port: number, endpoint: string | undefined, name: string): string {
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(token) || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid USB pairing.');
  if (endpoint !== undefined && !/^wss?:\/\/[0-9.]{7,15}:[1-9][0-9]{0,4}\/device$/.test(endpoint)) throw new Error('Invalid pairing endpoint.');
  const label = name.replace(/[^A-Za-z0-9 ._-]/g, '').slice(0, 64) || 'Computer';
  return `am start -W -a ${pairAction} -n ${androidPackage}/.UsbPairingActivity --es token ${token} --ei port ${port}` +
    `${endpoint ? ` --es endpoint ${endpoint}` : ''} --es name ${shellSafe(label)}\nexit\n`;
}

export function adbCandidates(platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env, home = homedir()): string[] {
  const exe = platform === 'win32' ? 'adb.exe' : 'adb';
  const list: string[] = [];
  if (env.PHONEBRIDGE_ADB) list.push(env.PHONEBRIDGE_ADB);
  for (const variable of ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) if (env[variable]) list.push(join(env[variable]!, 'platform-tools', exe));
  for (const dir of (env.PATH ?? env.Path ?? '').split(delimiter)) if (dir) list.push(join(dir, exe));
  if (platform === 'darwin') list.push('/opt/homebrew/bin/adb', '/usr/local/bin/adb', join(home, 'Library', 'Android', 'sdk', 'platform-tools', 'adb'));
  else if (platform === 'win32') {
    if (env.LOCALAPPDATA) list.push(join(env.LOCALAPPDATA, 'Android', 'Sdk', 'platform-tools', exe));
    list.push(join(home, 'AppData', 'Local', 'Android', 'Sdk', 'platform-tools', exe));
    for (const base of [env.ProgramFiles, env['ProgramFiles(x86)']]) if (base) list.push(join(base, 'Android', 'platform-tools', exe));
  } else list.push(join(home, 'Android', 'Sdk', 'platform-tools', exe), '/usr/bin/adb');
  return [...new Set(list)];
}

export function findAdb(candidates = adbCandidates()): string | undefined {
  for (const path of candidates) {
    try { accessSync(path, constants.X_OK); return path; } catch { /* try next */ }
  }
}

type RunResult = { code: number | null; stdout: string };
export type AdbRunner = (args: string[], input?: string, timeoutMs?: number) => Promise<RunResult>;

export function processRunner(adb: string): AdbRunner {
  return (args, input, timeoutMs = 8000) => new Promise(resolve => {
    const child = spawn(adb, args, { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    let stdout = '';
    const timer = setTimeout(() => child.kill(), timeoutMs);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => { if (stdout.length < 65536) stdout += chunk; });
    child.once('error', () => { clearTimeout(timer); resolve({ code: null, stdout }); });
    child.once('close', code => { clearTimeout(timer); resolve({ code, stdout }); });
    child.stdin.on('error', () => undefined);
    child.stdin.end(input ?? '');
  });
}

export type UsbPhone = {
  serial: string; model?: string;
  /** adb authorization and PhoneBridge reply, in the order the owner resolves them. */
  state: 'unauthorized' | 'offline' | 'app_missing' | 'app_outdated' | 'unknown' | 'pairing_requested' | 'paused' |
    'accessibility_disabled' | 'locked' | 'connecting' | 'waiting' | 'connected_usb' | 'connected_wireless' | 'unreachable' | 'tunnel_failed';
  appVersion?: string; updatedAt: string;
};
export type UsbStatus = { available: boolean; adbFound: boolean; loopbackPort?: number; phonePort?: number; phones: UsbPhone[]; error?: string };

type WatcherOptions = {
  token: string; phonePort: number; loopbackPort: () => number | undefined; endpoint: () => string | undefined;
  runner?: AdbRunner; adbPath?: string | null; intervalMs?: number; announceMs?: number; computerName?: string;
  now?: () => number; autoPair?: boolean;
};

/** Polls adb, keeps a reverse tunnel per authorized phone and announces the route to PhoneBridge. */
export class UsbLinkWatcher {
  private timer?: NodeJS.Timeout;
  private running?: Promise<void>;
  private readonly phones = new Map<string, UsbPhone & { announcedAt: number; pairRequested: boolean }>();
  private readonly runner?: AdbRunner;
  private readonly digest: string;
  private closed = false;
  private lastError?: string;

  constructor(private readonly options: WatcherOptions) {
    const adb = options.adbPath === null ? undefined : (options.adbPath ?? findAdb());
    this.runner = options.runner ?? (adb ? processRunner(adb) : undefined);
    this.digest = usbTokenDigest(options.token);
  }

  private now() { return this.options.now?.() ?? Date.now(); }

  start(): void {
    if (!this.runner || this.timer || this.closed) return;
    const tick = () => { if (!this.running) this.running = this.scan().catch(() => undefined).finally(() => { this.running = undefined; }); };
    tick();
    this.timer = setInterval(tick, this.options.intervalMs ?? 3000);
    this.timer.unref?.();
  }

  status(): UsbStatus {
    const loopbackPort = this.options.loopbackPort();
    return { available: !!this.runner && !!loopbackPort, adbFound: !!this.runner,
      ...(loopbackPort ? { loopbackPort, phonePort: this.options.phonePort } : {}),
      phones: [...this.phones.values()].map(({ announcedAt: _a, pairRequested: _p, ...phone }) => phone),
      ...(this.lastError ? { error: this.lastError } : {}) };
  }

  async scan(): Promise<void> {
    const runner = this.runner;
    const loopback = this.options.loopbackPort();
    if (!runner || this.closed) return;
    const listed = await runner(['devices', '-l'], undefined, 5000);
    if (listed.code !== 0) { this.lastError = 'adb_unavailable'; return; }
    this.lastError = undefined;
    const seen = new Set<string>();
    for (const device of parseAdbDevices(listed.stdout)) {
      seen.add(device.serial);
      const previous = this.phones.get(device.serial);
      const base = { serial: device.serial, ...(device.model ? { model: device.model } : {}), updatedAt: new Date(this.now()).toISOString() };
      if (device.state !== 'device') {
        this.phones.set(device.serial, { ...base, state: device.state === 'unauthorized' || device.state === 'authorizing' ? 'unauthorized' : 'offline',
          announcedAt: 0, pairRequested: previous?.pairRequested ?? false });
        continue;
      }
      const due = !previous || previous.announcedAt === 0 || this.now() - previous.announcedAt >= (this.options.announceMs ?? 30000) ||
        !['connected_usb', 'connected_wireless'].includes(previous.state);
      if (!due || !loopback) { if (!previous) this.phones.set(device.serial, { ...base, state: 'waiting', announcedAt: 0, pairRequested: false }); continue; }
      const phone = await this.announce(runner, device.serial, loopback, previous?.pairRequested ?? false);
      this.phones.set(device.serial, { ...base, ...phone });
    }
    // An unplugged phone forgets its one-time pairing prompt; the next plug-in may prompt again.
    for (const serial of [...this.phones.keys()]) if (!seen.has(serial)) this.phones.delete(serial);
  }

  private async announce(runner: AdbRunner, serial: string, loopback: number, pairRequested: boolean) {
    const reverse = await runner(['-s', serial, 'reverse', `tcp:${this.options.phonePort}`, `tcp:${loopback}`], undefined, 5000);
    if (reverse.code !== 0) return { state: 'tunnel_failed' as const, announcedAt: this.now(), pairRequested };
    const reply = await runner(['-s', serial, 'shell'], linkScript(this.digest, this.options.phonePort), 8000);
    let parsed = parseBroadcastReply(reply.stdout);
    if (parsed.state === 'app_outdated') {
      const installed = await runner(['-s', serial, 'shell', 'pm', 'path', androidPackage], undefined, 5000);
      if (!installed.stdout.includes('package:')) parsed = { state: 'app_missing' };
    }
    let state = parsed.state as UsbPhone['state'];
    if (state === 'unknown' && !pairRequested && this.options.autoPair !== false) {
      if (await this.requestPairing(serial)) { state = 'pairing_requested'; pairRequested = true; }
    } else if (state === 'unknown' && pairRequested) state = 'pairing_requested';
    return { state, ...(parsed.versionName ? { appVersion: parsed.versionName } : {}), announcedAt: this.now(), pairRequested };
  }

  /** Opens the phone's normal pairing form, pre-filled. The owner reviews and confirms there. */
  async requestPairing(serial: string): Promise<boolean> {
    const runner = this.runner;
    const loopback = this.options.loopbackPort();
    if (!runner || !loopback || !/^[A-Za-z0-9._:-]{1,128}$/.test(serial)) return false;
    const known = this.phones.get(serial);
    // Only a phone currently listed as authorized by adb; the scan itself pairs new phones once.
    if (known && ['unauthorized', 'offline'].includes(known.state)) return false;
    if (!known && !parseAdbDevices((await runner(['devices', '-l'], undefined, 5000)).stdout).some(device => device.serial === serial && device.state === 'device')) return false;
    const reverse = await runner(['-s', serial, 'reverse', `tcp:${this.options.phonePort}`, `tcp:${loopback}`], undefined, 5000);
    if (reverse.code !== 0) return false;
    const endpoint = this.options.endpoint();
    const lan = endpoint && /^wss?:\/\/[0-9.]{7,15}:[1-9][0-9]{0,4}\/device$/.test(endpoint) ? endpoint : undefined;
    const started = await runner(['-s', serial, 'shell'], pairScript(this.options.token, this.options.phonePort, lan, this.options.computerName ?? hostname()), 10000);
    const ok = started.code === 0 && /Status: ok|Complete/.test(started.stdout) && !/Error|Exception|Security/.test(started.stdout);
    const phone = this.phones.get(serial);
    if (ok && phone) { phone.pairRequested = true; phone.state = 'pairing_requested'; }
    return ok;
  }

  /** Re-announce immediately, e.g. right after the owner confirmed pairing on the phone. */
  refresh(serial?: string): void {
    for (const phone of this.phones.values()) if (!serial || phone.serial === serial) phone.announcedAt = 0;
  }

  async close(): Promise<void> {
    this.closed = true;
    clearInterval(this.timer); this.timer = undefined;
    await this.running?.catch(() => undefined);
    // Reverse rules are left in place: a replacement supervisor (network change) may already
    // own the same phone port, and adb drops the rules itself when the cable is unplugged.
  }
}
