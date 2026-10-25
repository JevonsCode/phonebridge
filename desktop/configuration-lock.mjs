import { mkdir, lstat, writeFile, readFile, rename, unlink, readdir, realpath } from 'node:fs/promises';
import { dirname, basename, join, resolve } from 'node:path';
import { randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

function processStart(pid) {
  if (process.platform === 'win32') return undefined;
  const result = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8', timeout: 1000 });
  return result.status === 0 ? result.stdout.trim() : undefined;
}
function alive(record) {
  try { process.kill(record.pid, 0); } catch (error) { return error.code !== 'ESRCH'; }
  const observed = record.started ? processStart(record.pid) : undefined;
  // A failed/slow process query is not evidence that a live writer died.
  return !record.started || !observed || observed === record.started;
}

/** Bakery participants have unique names, so reaping a dead PID cannot unlink a new owner's lock. */
export async function withConfigurationLock(path, operation, { timeoutMs = 1500 } = {}) {
  const directory = join(await realpath(dirname(resolve(path))), basename(path)) + '.writers';
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || (process.platform !== 'win32' &&
    (info.uid !== process.getuid() || (info.mode & 0o077)))) throw new Error('Invalid configuration writer directory.');
  const id = `${process.pid}-${randomBytes(16).toString('hex')}`;
  const participant = join(directory, id + '.json');
  const record = { pid: process.pid, started: processStart(process.pid), choosing: true, ticket: 0 };
  const deadline = performance.now() + timeoutMs;
  const publish = async value => {
    const temp = participant + '.tmp';
    try { await writeFile(temp, JSON.stringify(value), { mode: 0o600, flag: 'wx' }); await rename(temp, participant); }
    finally { await unlink(temp).catch(() => {}); }
  };
  const readParticipant = async name => {
    const file = join(directory, name);
    let stat, value;
    try { stat = await lstat(file); if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024 ||
      (process.platform !== 'win32' && (stat.uid !== process.getuid() || (stat.mode & 0o077)))) throw new Error('Invalid configuration writer record.'); value = JSON.parse(await readFile(file, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return; throw error; }
    if (!Number.isInteger(value.pid) || value.pid <= 0 || !name.startsWith(value.pid + '-') ||
      typeof value.choosing !== 'boolean' || !Number.isSafeInteger(value.ticket) || value.ticket < 0 ||
      (value.started !== undefined && typeof value.started !== 'string')) throw new Error('Invalid configuration writer record.');
    if (!alive(value)) { await unlink(file).catch(error => { if (error.code !== 'ENOENT') throw error; }); return; }
    return value;
  };
  const names = async () => (await readdir(directory)).filter(name => /^[1-9][0-9]*-[a-f0-9]{32}\.json$/.test(name));
  const pause = async () => { if (performance.now() >= deadline) throw new Error('Configuration publication is busy. It will be retried.'); await delay(15); };
  try {
    // Publish choosing=true before looking at the other tickets. A new participant
    // appearing later must either observe this ticket or wait for this choice.
    await publish(record);
    let maximum = 0;
    for (const name of await names()) { const other = await readParticipant(name); if (other) maximum = Math.max(maximum, other.ticket); }
    record.ticket = maximum + 1; record.choosing = false;
    await publish(record);
    for (const name of await names()) {
      if (name === id + '.json') continue;
      let other;
      while ((other = await readParticipant(name)) && other.choosing) await pause();
      while (other && (other.ticket < record.ticket || (other.ticket === record.ticket && name < id + '.json'))) {
        await pause(); other = await readParticipant(name);
        if (other?.choosing) throw new Error('Invalid reused configuration writer identity.');
      }
    }
    return await operation();
  } finally { await unlink(participant).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
}

/** Windows shares the installer's OS mutex; the helper owns both comparison and File.Replace. */
export async function publishWindowsConfiguration(path, temporary, expected) {
  const expectedPath = `${path}.expected-${randomBytes(8).toString('hex')}`;
  try {
    if (expected !== undefined) await writeFile(expectedPath, JSON.stringify(expected), { flag: 'wx', mode: 0o600 });
    const helper = fileURLToPath(new URL('../scripts/windows/atomic-config.ps1', import.meta.url));
    await new Promise((done, reject) => {
      const child = spawn(join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', helper, '--publish', temporary, path,
          expected === undefined ? '--absent' : expectedPath], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
      let message = '';
      const timer = setTimeout(() => { child.kill(); reject(new Error('Configuration publication is busy. It will be retried.')); }, 6000);
      child.stderr.on('data', bytes => { message = (message + bytes).slice(-4096); });
      child.once('error', error => { clearTimeout(timer); reject(error); });
      child.once('exit', code => {
        clearTimeout(timer);
        if (code === 0) done(); else reject(new Error(/configuration changed/i.test(message)
          ? 'Desktop configuration changed. The newer configuration was preserved.' : 'Configuration publication is busy or unavailable. It will be retried.'));
      });
    });
  } finally { await unlink(expectedPath).catch(() => {}); }
}
