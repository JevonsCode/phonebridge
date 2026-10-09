import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { loadOrCreateSavedToken, loadSavedToken } from '../src/credentials.js';

test('saved pairing survives a fresh process and never silently rotates', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-credential-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'pairing.json');
  assert.equal(await loadSavedToken(path), undefined);
  const token = await loadOrCreateSavedToken(path);
  assert.equal(await loadSavedToken(path), token);
  assert.equal(await loadOrCreateSavedToken(path), token);
  await assert.rejects(loadOrCreateSavedToken(path, 'different_identity_0123456789_abcdef'), /differs/);
  const disk = await readFile(path, 'utf8');
  if (process.platform === 'win32') assert.equal(disk.includes(token), false, 'Windows disk record must be DPAPI encrypted');
  const code = `import {loadSavedToken} from ${JSON.stringify(new URL('../src/credentials.ts', import.meta.url).href)}; import {createHash} from 'node:crypto'; const token=await loadSavedToken(process.env.TEST_CREDENTIAL_PATH); console.log(createHash('sha256').update(token).digest('hex'));`;
  const child = spawnSync(process.execPath, ['--import', 'tsx', '--input-type=module', '-e', code], { env: { ...process.env, TEST_CREDENTIAL_PATH: path }, encoding: 'utf8', timeout: 20000, windowsHide: true });
  assert.equal(child.status, 0, 'fresh process must load credential');
  assert.equal(child.stdout.trim(), createHash('sha256').update(token).digest('hex'));
});

test('corrupt saved credentials fail instead of creating a new pairing identity', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-invalid-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'pairing.json');
  await writeFile(path, '{broken', { mode: 0o600 });
  await assert.rejects(loadOrCreateSavedToken(path), /invalid/);
  assert.equal(await readFile(path, 'utf8'), '{broken');
});

test('POSIX stored credentials refuse group/world readable files', { skip: process.platform === 'win32' }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'phonebridge-mode-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, 'pairing.json');
  await loadOrCreateSavedToken(path);
  await chmod(path, 0o644);
  await assert.rejects(loadSavedToken(path), /mode 600/);
});
