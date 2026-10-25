import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const versionPattern = /^\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?(?:\+[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$/;
export type AppVersion = { version: string; source: 'package-manifest' | 'mobile-pubspec' | 'bridge-package' | 'unavailable' };

/** Packaged processes identify their payload; source runs share the mobile App release version. */
export async function readAppVersion(root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')): Promise<AppVersion> {
  const read = (path: string) => readFile(path, 'utf8').then(value => value.replace(/^\uFEFF/, '')).catch(() => '');
  const valid = (value: unknown): value is string => typeof value === 'string' && versionPattern.test(value);
  try {
    const manifest = JSON.parse(await read(join(root, 'package-manifest.json')));
    if (manifest.product === 'PhoneBridge' && valid(manifest.version)) return { version: manifest.version, source: 'package-manifest' };
  } catch { /* A source checkout has no installed package manifest. */ }
  const mobile = /^version:\s*([^\s#]+)/m.exec(await read(join(root, 'mobile', 'pubspec.yaml')))?.[1];
  if (valid(mobile)) return { version: mobile.split('+')[0]!, source: 'mobile-pubspec' };
  try {
    const bridge = JSON.parse(await read(join(root, 'bridge', 'package.json')));
    if (valid(bridge.version)) return { version: bridge.version, source: 'bridge-package' };
  } catch { /* Report unavailable metadata without inventing a release version. */ }
  return { version: 'unknown', source: 'unavailable' };
}
