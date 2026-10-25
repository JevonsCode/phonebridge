import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, readdir, rename, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { withConfigurationLock } from '../configuration-lock.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'phonebridge-config-lock-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = join(directory, 'config.json'), childFile = join(directory, 'writer.mjs');
  await writeFile(file, '0');
  await writeFile(childFile, `import {withConfigurationLock} from ${JSON.stringify(new URL('../configuration-lock.mjs', import.meta.url).href)};
import {readFile,writeFile} from 'node:fs/promises';
import {setTimeout as delay} from 'node:timers/promises';
const [file,mode] = process.argv.slice(2);
if(mode==='hold') await withConfigurationLock(file,async()=>{console.log('locked');await new Promise(()=>{setInterval(()=>{},1000);});});
else for(let i=0;i<3;i++) await withConfigurationLock(file,async()=>{const n=Number(await readFile(file,'utf8'));await delay(12);await writeFile(file,String(n+1));},{timeoutMs:4000});
`);
  const launch = mode => {
    const child = spawn(process.execPath, [childFile, file, mode], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = ''; child.stderr.on('data', bytes => { stderr += bytes; });
    const exited = new Promise((done, reject) => { child.once('error', reject); child.once('exit', (code, signal) => done({ code, signal, stderr })); });
    t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill(); await exited; });
    return { child, exited };
  };
  return { directory, file, launch };
}

test('independent configuration writer processes serialize their read/modify/publish sections', async t => {
  const { file, launch } = await fixture(t);
  const workers = Array.from({ length: 3 }, () => launch('increment'));
  for (const worker of workers) { const result = await worker.exited; assert.equal(result.code, 0, result.stderr); }
  assert.equal(await readFile(file, 'utf8'), '9');
});

test('a busy writer times out promptly and a crashed writer leaves no permanent lock', async t => {
  const { file, launch } = await fixture(t), holder = launch('hold');
  await new Promise((done, reject) => { const timer = setTimeout(() => reject(new Error('Lock holder did not become ready')), 3000); holder.child.stdout.once('data', () => { clearTimeout(timer); done(); }); });
  let entered = false;
  await assert.rejects(withConfigurationLock(file, async () => { entered = true; }, { timeoutMs: 80 }), /busy/);
  assert.equal(entered, false);
  holder.child.kill('SIGKILL'); await holder.exited;
  await withConfigurationLock(file, async () => { entered = true; });
  assert.equal(entered, true);
  await delay(1);
});

test('Windows marker rename retries transient occupancy without republishing bytes or repeating the operation', { skip: process.platform !== 'win32' }, async t => {
  const { file } = await fixture(t), paths = new Set(), codes = ['EPERM', 'EACCES', 'EBUSY'];
  let attempts = 0, operations = 0, markerBytes;
  await withConfigurationLock(file, async () => { operations++; await writeFile(file, 'committed once'); }, {
    renameMarker: async (temporary, destination) => {
      const bytes = await readFile(temporary, 'utf8');
      if (!JSON.parse(bytes).choosing) {
        paths.add(`${temporary}\n${destination}`);
        markerBytes ??= bytes; assert.equal(bytes, markerBytes);
        const code = codes[attempts++];
        if (code) throw Object.assign(new Error('Injected marker occupancy'), { code });
      }
      await rename(temporary, destination);
    },
  });
  assert.equal(attempts, 4); assert.equal(paths.size, 1); assert.equal(operations, 1);
  assert.equal(await readFile(file, 'utf8'), 'committed once');
  assert.deepEqual(await readdir(file + '.writers'), []);
});

test('Windows permanent marker occupancy rejects at the deadline and cleans both marker files', { skip: process.platform !== 'win32' }, async t => {
  const { file } = await fixture(t), failure = Object.assign(new Error('Injected permanent occupancy'), { code: 'EPERM' });
  let attempts = 0, operations = 0, initialPublished = false;
  const started = performance.now();
  await assert.rejects(withConfigurationLock(file, async () => { operations++; }, {
    timeoutMs: 200,
    renameMarker: async (temporary, destination) => {
      if (!JSON.parse(await readFile(temporary, 'utf8')).choosing) {
        assert.equal(initialPublished, true);
        assert.equal(JSON.parse(await readFile(destination, 'utf8')).choosing, true);
        attempts++; throw failure;
      }
      await rename(temporary, destination);
      initialPublished = true;
    },
  }), error => error === failure);
  const elapsed = performance.now() - started;
  assert.ok(attempts >= 1 && attempts < 50); assert.ok(elapsed >= 180 && elapsed < 2000);
  assert.equal(operations, 0); assert.equal(await readFile(file, 'utf8'), '0');
  assert.deepEqual(await readdir(file + '.writers'), []);
});

test('other rename errors fail immediately and operation failures are never retried', async t => {
  const { file } = await fixture(t), failure = Object.assign(new Error('Injected permanent I/O error'), { code: 'EIO' });
  let attempts = 0, operations = 0;
  await assert.rejects(withConfigurationLock(file, async () => { operations++; }, {
    renameMarker: async (temporary, destination) => {
      if (!JSON.parse(await readFile(temporary, 'utf8')).choosing) { attempts++; throw failure; }
      await rename(temporary, destination);
    },
  }), error => error === failure);
  assert.equal(attempts, 1); assert.equal(operations, 0); assert.deepEqual(await readdir(file + '.writers'), []);
  const operationFailure = Object.assign(new Error('Injected operation failure'), { code: 'EPERM' });
  await assert.rejects(withConfigurationLock(file, async () => { operations++; throw operationFailure; }), error => error === operationFailure);
  assert.equal(operations, 1); assert.deepEqual(await readdir(file + '.writers'), []);
});
