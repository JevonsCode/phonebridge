import test from 'node:test';
import assert from 'node:assert/strict';
import { access, copyFile, mkdir, mkdtemp, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));

async function copiedRuntimeFiles() {
  const packaging = (await readFile(path.join(root, 'scripts', 'package-macos.sh'), 'utf8')).replaceAll('\r\n', '\n');
  const copied = new Set();
  for (const match of packaging.matchAll(/for name in ([^;]+); do\n\s+cp "\$project\/(desktop(?:\/macos)?)\/\$name" "\$resources\//g)) {
    for (const name of match[1].trim().split(/\s+/)) copied.add(`${match[2]}/${name}`);
  }
  assert.ok(copied.has('desktop/server.mjs') && copied.has('desktop/macos/service.mjs'), 'Read the actual package runtime copy loops');
  return copied;
}

test('the macOS runtime copy list contains every statically imported desktop runtime module', async () => {
  const copied = await copiedRuntimeFiles();
  const pending = [...copied].filter(name => name.endsWith('.mjs'));
  const visited = new Set();
  while (pending.length) {
    const file = pending.pop();
    if (visited.has(file)) continue;
    visited.add(file);
    const source = await readFile(path.join(root, file), 'utf8');
    // These imports are resolved before a platform's main() or --self-test can
    // select a branch. Platform-specific dynamic commands are tested separately.
    for (const match of source.matchAll(/(?:\bfrom\s*|\bimport\s*)(['"])(\.[^'"]+)\1/g)) {
      const dependency = path.posix.normalize(path.posix.join(path.posix.dirname(file), match[2]));
      if (!dependency.startsWith('desktop/')) continue;
      assert.ok(copied.has(dependency), `${file} imports ${dependency}, which is missing from the macOS package`);
      if (dependency.endsWith('.mjs')) pending.push(dependency);
    }
  }
});

test('the copied macOS dashboard entry imports with the staged desktop files and actual bridge runtime', async t => {
  try { await access(path.join(root, 'bridge', 'dist', 'credentials.js')); }
  catch (error) { if (error.code === 'ENOENT') { t.skip('Build bridge before the native module-resolution check'); return; } throw error; }
  const stage = await mkdtemp(path.join(tmpdir(), 'phonebridge-macos-copy-test-'));
  t.after(() => rm(stage, { recursive: true, force: true }));
  for (const file of await copiedRuntimeFiles()) {
    await mkdir(path.dirname(path.join(stage, file)), { recursive: true });
    await copyFile(path.join(root, file), path.join(stage, file));
  }
  // Borrow read-only build/dependency inputs. Importing this guarded entry does
  // not run a dashboard, read user credentials, or register a service.
  await symlink(path.join(root, 'bridge'), path.join(stage, 'bridge'), process.platform === 'win32' ? 'junction' : 'dir');
  const entry = await import(pathToFileURL(path.join(stage, 'desktop', 'macos', 'server.mjs')).href);
  assert.equal(typeof entry.main, 'function');
});
