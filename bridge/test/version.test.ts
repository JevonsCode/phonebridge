import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readAppVersion } from '../src/version.js';

test('installed manifest takes precedence; development uses mobile release then bridge package', async t => {
  const root = await mkdtemp(join(tmpdir(), 'phonebridge-version-')); t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'mobile')); await mkdir(join(root, 'bridge'));
  await writeFile(join(root, 'bridge', 'package.json'), JSON.stringify({ version: '1.2.3' }));
  assert.deepEqual(await readAppVersion(root), { version: '1.2.3', source: 'bridge-package' });
  await writeFile(join(root, 'mobile', 'pubspec.yaml'), 'name: phonebridge\nversion: 2.3.4+12\n');
  assert.deepEqual(await readAppVersion(root), { version: '2.3.4', source: 'mobile-pubspec' });
  await writeFile(join(root, 'package-manifest.json'), '\uFEFF' + JSON.stringify({ product: 'PhoneBridge', version: '3.4.5-beta.2' }));
  assert.deepEqual(await readAppVersion(root), { version: '3.4.5-beta.2', source: 'package-manifest' });
});

test('missing or malformed metadata never invents a release version', async t => {
  const root = await mkdtemp(join(tmpdir(), 'phonebridge-version-')); t.after(() => rm(root, { recursive: true, force: true }));
  await writeFile(join(root, 'package-manifest.json'), JSON.stringify({ product: 'PhoneBridge', version: 'invalid\nversion' }));
  assert.deepEqual(await readAppVersion(root), { version: 'unknown', source: 'unavailable' });
});
