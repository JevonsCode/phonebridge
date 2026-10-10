import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import test from 'node:test';
import { CERTIFICATE, PACKAGE, PUBLIC_FILES, createPublicUpdates, distribute, parseVersion, selectDesktopAssets, selectReleaseAsset, validateDesktopIdentity, verifyApk } from '../release-distribution.mjs';

const apkBytes = Buffer.from('fixture APK bytes, deliberately not a real signed APK');
const hash = createHash('sha256').update(apkBytes).digest('hex');
const oldHash = 'a'.repeat(64);
const assetUrl = version => `https://github.com/JevonsCode/phonebridge/releases/download/v${version}/phonebridge-${version}-arm64.apk`;
function input(version = '0.2.6', versionCode = 2010) {
  return {
    release: { tag_name: `v${version}`, draft: false, published_at: '2026-10-11T08:00:00Z', body: '中文更新。English update.', assets: [{ name: `phonebridge-${version}-arm64.apk`, browser_download_url: assetUrl(version), size: apkBytes.length, state: 'uploaded', digest: `sha256:${hash}` }] },
    tag: `v${version}`, apkBytes,
    badging: `package: name='${PACKAGE}' versionCode='${versionCode}' versionName='${version}' platformBuildVersionName='16'\nnative-code: 'arm64-v8a'\n`,
    signerReport: `Verifies\nSigner #1 certificate DN: CN=Android Debug\nSigner #1 certificate SHA-256 digest: ${CERTIFICATE}\n`
  };
}
const current = () => ({ schema: 1, versionName: '0.2.5', versionCode: 2009, apkUrl: assetUrl('0.2.5'), sha256: oldHash, size: 100, notes: 'Existing notes' });
function publicFixture() {
  return {
    [PUBLIC_FILES[0]]: `${JSON.stringify(current(), null, 2)}\n`,
    [PUBLIC_FILES[1]]: `<a href="${assetUrl('0.2.5')}">下载</a><small>当前版本 0.2.5</small><a href="${assetUrl('0.2.5')}">安装</a>`,
    [PUBLIC_FILES[2]]: `<a href="${assetUrl('0.2.5')}">Download</a><small>Current version 0.2.5</small><a href="${assetUrl('0.2.5')}">Install</a>`,
    'README.md': `[APK](${assetUrl('0.2.5')})\nDo not change this content.`
  };
}
async function fixture(t, contents = publicFixture()) {
  const base = await mkdtemp(path.join(os.tmpdir(), 'phonebridge-distribution-test-'));
  t.after(() => rm(base, { recursive: true, force: true }));
  const root = path.join(base, 'checkout');
  await mkdir(root);
  for (const [file, text] of Object.entries(contents)) {
    await mkdir(path.dirname(path.join(root, file)), { recursive: true });
    await writeFile(path.join(root, file), text);
  }
  return { root, outputDir: path.join(base, 'submission'), base, contents };
}
async function assertUntouched(f) {
  for (const file of PUBLIC_FILES) assert.equal(await readFile(path.join(f.root, file), 'utf8'), f.contents[file]);
  await assert.rejects(access(f.outputDir), { code: 'ENOENT' });
}

test('canonical versions reject paths, shell characters, ambiguous numbers, prereleases, and huge components', () => {
  assert.deepEqual(parseVersion('0.2.6'), [0, 2, 6]);
  assert.deepEqual(parseVersion('10.0.12'), [10, 0, 12]);
  for (const version of ['v0.2.6', '01.2.6', '0.02.6', '../0.2.6', '0.2.6;echo bad', '0.2.6\n', '0.2.6-beta', '0.2', '-1.2.3', '1.2.9007199254740992', undefined]) assert.throws(() => parseVersion(version));
});

test('select only the exact published official ARM64 asset', () => {
  assert.equal(selectReleaseAsset(input().release).url, assetUrl('0.2.6'));
  const mutations = [
    i => { i.release.draft = true; },
    i => { i.release.published_at = null; },
    i => { i.release.tag_name = 'v0.2.7'; },
    i => { i.release.assets.push({ ...i.release.assets[0] }); },
    i => { i.release.assets[0].name = '../../evil.apk'; },
    i => { i.release.assets[0].browser_download_url = 'https://evil.example/app.apk'; },
    i => { i.release.assets[0].browser_download_url += '?token=x'; },
    i => { i.release.assets[0].size = -1; },
    i => { i.release.assets[0].state = 'open'; },
    i => { i.release.assets[0].digest = 'md5:bad'; }
  ];
  for (const mutate of mutations) { const i = input(); mutate(i); assert.throws(() => selectReleaseAsset(i.release, i.tag)); }
});

function addDesktopAssets(i) {
  for (const suffix of ['windows-setup.exe', 'windows-x64.zip']) {
    const name = `phonebridge-${i.tag.slice(1)}-${suffix}`;
    i.release.assets.push({ name, browser_download_url: `https://github.com/JevonsCode/phonebridge/releases/download/${i.tag}/${name}`, size: 1234, state: 'uploaded', digest: `sha256:${'c'.repeat(64)}` });
  }
  return i;
}

test('optional Windows metadata selects exact installer/portable names and fails closed on bad metadata', () => {
  assert.deepEqual(selectDesktopAssets(input().release), []);
  const selected = selectDesktopAssets(addDesktopAssets(input('0.6.0', 2011)).release);
  assert.deepEqual(selected.map(asset => asset.kind), ['installer', 'portable']);
  assert.equal(selected[0].name, 'phonebridge-0.6.0-windows-setup.exe');
  for (const mutate of [
    i => { i.release.assets[1].browser_download_url = 'https://evil.example/setup.exe'; },
    i => { i.release.assets[1].digest = null; },
    i => { i.release.assets[1].size = 0; },
    i => { i.release.assets[1].state = 'open'; },
    i => { i.release.assets.push({ ...i.release.assets[1] }); }
  ]) { const i = addDesktopAssets(input()); mutate(i); assert.throws(() => selectDesktopAssets(i.release)); }
});

test('Windows embedded manifest and diagnostic enforce product, platform and the actual release version', () => {
  const identity = { product: 'PhoneBridge', version: '0.6.0', platform: 'windows-x64', dryRun: true };
  assert.deepEqual(validateDesktopIdentity(identity, 'v0.6.0'), { product: 'PhoneBridge', version: '0.6.0', platform: 'windows-x64' });
  assert.doesNotThrow(() => validateDesktopIdentity(identity, 'v0.6.0', { diagnostic: true }));
  for (const wrong of [
    { ...identity, version: '0.2.5' },
    { ...identity, version: '0.6.0\n' },
    { ...identity, product: 'OtherApp' },
    { ...identity, platform: 'windows-arm64' },
    { ...identity, platform: undefined },
    null, [], 'exit code zero'
  ]) assert.throws(() => validateDesktopIdentity(wrong, 'v0.6.0'));
  for (const dryRun of [undefined, false, 'true', 1]) assert.throws(() => validateDesktopIdentity({ ...identity, dryRun }, 'v0.6.0', { diagnostic: true }), /dryRun/);
  assert.throws(() => validateDesktopIdentity(identity, 'v0.6.1'), /version/);
});

test('the retained release snapshot freezes optional desktop absence, names, sizes and digests despite later edits', async t => {
  for (const present of [false, true]) {
    const original = present ? addDesktopAssets(input('0.6.0', 2011)) : input('0.6.0', 2011);
    const snapshotBytes = JSON.stringify(original.release);
    const expected = selectDesktopAssets(original.release);
    if (present) {
      original.release.assets[1].digest = `sha256:${'d'.repeat(64)}`;
      original.release.assets[1].size = 4567;
      original.release.assets.pop();
    } else addDesktopAssets(original);
    assert.notDeepEqual(selectDesktopAssets(original.release), expected);
    const f = await fixture(t);
    await distribute({ ...f, ...input('0.6.0', 2011), release: JSON.parse(snapshotBytes) });
    const kit = JSON.parse(await readFile(path.join(f.outputDir, 'uptodown-submission.json'), 'utf8'));
    assert.deepEqual(kit.desktopAssets, expected);
  }
});

test('the exact workflow PowerShell guard rejects single-backslash traversal and absolute paths', async t => {
  const workflow = await readFile(new URL('../../.github/workflows/release-distribution.yml', import.meta.url), 'utf8');
  const lines = workflow.split(/\r?\n/);
  const normalization = lines.find(line => line.includes('$entryName = $entry.FullName.Replace'));
  const rejection = lines.find(line => line.includes("throw 'Unsafe ZIP entry path'"));
  assert.ok(normalization && rejection);
  const names = ['../escape', '..\\escape', 'safe\\..\\escape', 'safe/../escape', '\\outside', '\\\\server\\share', 'C:\\outside', 'desktop\\server.mjs', 'runtime/node.exe'];
  const source = `$names = @(${names.map(name => `'${name.replaceAll("'", "''")}'`).join(',')})\n$results = @()\nforeach ($name in $names) { $entry = [pscustomobject]@{ FullName = $name }; $blocked = $false; try { ${normalization.trim()}\n${rejection.trim()} } catch { $blocked = $true }; $results += [pscustomobject]@{ name=$name; blocked=$blocked; normalized=$entryName } }\nConvertTo-Json -InputObject $results -Compress`;
  const host = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';
  const run = spawnSync(host, ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(source, 'utf16le').toString('base64')], { encoding: 'utf8' });
  if (run.error?.code === 'ENOENT') { t.skip('PowerShell unavailable on this test host'); return; }
  assert.equal(run.status, 0, run.stderr);
  const results = JSON.parse(run.stdout.trim());
  assert.deepEqual(results.map(result => result.blocked), [true, true, true, true, true, true, true, false, false]);
  assert.equal(results[7].normalized, 'desktop/server.mjs');
});

test('present Windows assets synchronize existing desktop URLs in both languages and README and join kit', async t => {
  const contents = publicFixture();
  for (const file of PUBLIC_FILES.slice(1)) {
    contents[file] += '\nhttps://github.com/JevonsCode/phonebridge/releases/download/v0.2.5/phonebridge-0.2.5-windows-setup.exe\nhttps://github.com/JevonsCode/phonebridge/releases/download/v0.2.5/phonebridge-0.2.5-windows-x64.zip';
  }
  const f = await fixture(t, contents);
  await distribute({ ...f, ...addDesktopAssets(input('0.6.0', 2011)) });
  for (const file of PUBLIC_FILES.slice(1)) {
    const text = await readFile(path.join(f.root, file), 'utf8');
    assert.ok(text.includes('/v0.6.0/phonebridge-0.6.0-windows-setup.exe'));
    assert.ok(text.includes('/v0.6.0/phonebridge-0.6.0-windows-x64.zip'));
    assert.ok(!text.includes('/v0.2.5/'));
  }
  const kit = JSON.parse(await readFile(path.join(f.outputDir, 'uptodown-submission.json'), 'utf8'));
  assert.equal(kit.desktopAssets.length, 2);
  assert.equal(kit.desktopAssets[0].sha256, 'c'.repeat(64));
});

test('invalid optional desktop metadata prevents Android manifest publication and kit generation', async t => {
  const f = await fixture(t), i = addDesktopAssets(input()); i.release.assets[1].digest = null;
  await assert.rejects(distribute({ ...f, ...i }), /Windows asset must include/);
  await assertUntouched(f);
});

test('verified APK produces digest, Android metadata, and exact asset URL', () => {
  const result = verifyApk(input());
  assert.equal(result.sha256, hash);
  assert.equal(result.size, apkBytes.length);
  assert.equal(result.versionCode, 2010);
  assert.equal(result.packageName, PACKAGE);
  assert.equal(result.certificate, CERTIFICATE);
  assert.equal(result.url, assetUrl('0.2.6'));
});

const invalidApks = [
  ['wrong package', i => { i.badging = i.badging.replace(PACKAGE, 'dev.attacker.app'); }, /package name/],
  ['wrong versionName', i => { i.badging = i.badging.replace("versionName='0.2.6'", "versionName='0.2.7'"); }, /versionName/],
  ['wrong signing identity', i => { i.signerReport = i.signerReport.replace(CERTIFICATE, 'b'.repeat(64)); }, /certificate/],
  ['extra signer', i => { i.signerReport += `Signer #2 certificate SHA-256 digest: ${CERTIFICATE}\n`; }, /certificate/],
  ['missing signing evidence', i => { i.signerReport = 'Verifies\n'; }, /certificate/],
  ['wrong GitHub hash', i => { i.release.assets[0].digest = `sha256:${'b'.repeat(64)}`; }, /SHA-256/],
  ['wrong explicit hash even with matching GitHub digest', i => { i.expectedHash = 'b'.repeat(64); }, /SHA-256/],
  ['malformed explicit hash', i => { i.expectedHash = 'ABC'; }, /SHA-256/],
  ['different downloaded bytes', i => { i.apkBytes = Buffer.alloc(apkBytes.length, 0); }, /SHA-256/],
  ['truncated APK', i => { i.apkBytes = apkBytes.subarray(1); }, /size/],
  ['zero versionCode', i => { i.badging = i.badging.replace("versionCode='2010'", "versionCode='0'"); }, /versionCode/],
  ['Android versionCode overflow', i => { i.badging = i.badging.replace("versionCode='2010'", "versionCode='2100000001'"); }, /versionCode/],
  ['wrong ABI', i => { i.badging = i.badging.replace('arm64-v8a', 'x86_64'); }, /ARM64/],
  ['mixed ABI', i => { i.badging = i.badging.replace("'arm64-v8a'", "'arm64-v8a' 'armeabi-v7a'"); }, /ARM64/],
  ['duplicate package report', i => { i.badging += i.badging; }, /exactly one package/],
  ['digest absent with no trusted expected hash', i => { i.release.assets[0].digest = null; }, /trusted expected/]
];
for (const [name, mutate, error] of invalidApks) {
  test(`${name}: reject before public writes, kit creation, or downstream publication`, async t => {
    const f = await fixture(t), i = input();
    mutate(i);
    await assert.rejects(distribute({ ...f, ...i }), error);
    await assertUntouched(f);
  });
}

test('digest absent accepts an explicitly trusted expected hash', () => {
  const i = input(); i.release.assets[0].digest = null; i.expectedHash = hash;
  assert.equal(verifyApk(i).sha256, hash);
});

test('end-to-end generation synchronizes every bilingual URL and mock version, README and manifest', async t => {
  const f = await fixture(t), result = await distribute({ ...f, ...input() });
  assert.equal(result.changed, true); assert.equal(result.stale, false);
  const manifest = JSON.parse(await readFile(path.join(f.root, PUBLIC_FILES[0]), 'utf8'));
  assert.deepEqual(manifest, { schema: 1, versionName: '0.2.6', versionCode: 2010, apkUrl: assetUrl('0.2.6'), sha256: hash, size: apkBytes.length, notes: '中文更新。English update.' });
  for (const file of PUBLIC_FILES.slice(1)) {
    const text = await readFile(path.join(f.root, file), 'utf8');
    assert.ok(text.includes(assetUrl('0.2.6'))); assert.ok(!text.includes(assetUrl('0.2.5')));
  }
  assert.match(await readFile(path.join(f.root, PUBLIC_FILES[1]), 'utf8'), /当前版本 0\.2\.6/);
  assert.match(await readFile(path.join(f.root, PUBLIC_FILES[2]), 'utf8'), /Current version 0\.2\.6/);
  const kit = JSON.parse(await readFile(path.join(f.outputDir, 'uptodown-submission.json'), 'utf8'));
  assert.equal(kit.apkUrl, manifest.apkUrl); assert.equal(kit.sha256, hash); assert.equal(kit.certificateSha256, CERTIFICATE);
  assert.equal(kit.consoleUrl, 'https://www.uptodown.dev/apps/1000896707');
  assert.equal(kit.status, 'manual-or-editorial-review-required');
  assert.ok(kit.descriptions.zh.includes('默认只读')); assert.ok(kit.descriptions.en.includes('read-only'));
  assert.match(await readFile(path.join(f.outputDir, 'uptodown-submission.md'), 'utf8'), /No store API upload was performed/);
});

test('transforms actual current website and README layouts without changing the real checkout', async t => {
  const repositoryRoot = fileURLToPath(new URL('../../', import.meta.url));
  const actual = {};
  actual[PUBLIC_FILES[0]] = publicFixture()[PUBLIC_FILES[0]];
  for (const file of PUBLIC_FILES.slice(1)) actual[file] = await readFile(path.join(repositoryRoot, file), 'utf8');
  const f = await fixture(t, actual);
  await distribute({ ...f, ...input() });
  for (const file of PUBLIC_FILES.slice(1)) assert.ok((await readFile(path.join(f.root, file), 'utf8')).includes(assetUrl('0.2.6')));
});

test('older release is verified but preserves all newer public files and marks kit stale', async t => {
  const f = await fixture(t), i = input('0.2.4', 2008);
  const result = await distribute({ ...f, ...i });
  assert.equal(result.stale, true); assert.equal(result.changed, false);
  for (const file of PUBLIC_FILES) assert.equal(await readFile(path.join(f.root, file), 'utf8'), f.contents[file]);
  assert.match(await readFile(path.join(f.outputDir, 'summary.md'), 'utf8'), /Pages deployment is skipped/);
});

test('version ordering is numeric and increasing versionCode is mandatory', () => {
  const f = publicFixture();
  assert.equal(createPublicUpdates(current(), f, verifyApk(input('0.2.10', 2014))).stale, false);
  assert.throws(() => createPublicUpdates(current(), f, verifyApk(input('0.2.6', 2009))), /increase versionCode/);
  assert.throws(() => createPublicUpdates(current(), f, verifyApk(input('0.2.4', 2010))), /conflicting versionCode/);
});

test('same release is idempotent and exact checked-in hash permits missing GitHub digest', async t => {
  const f = await fixture(t);
  await distribute({ ...f, ...input() });
  const i = input(); i.release.assets[0].digest = null;
  const result = await distribute({ ...f, ...i, outputDir: path.join(f.base, 'second-kit') });
  assert.equal(result.changed, false); assert.equal(result.stale, false);
});

test('same version cannot replace existing bytes or versionCode', async t => {
  const f = await fixture(t), i = input('0.2.5', 2009);
  await assert.rejects(distribute({ ...f, ...i }), /expected SHA-256/);
  await assertUntouched(f);
});

test('fallback hash is not reused for an unmatched version or URL', async t => {
  const f = await fixture(t), i = input('0.2.5', 2009);
  const changedManifest = { ...current(), apkUrl: 'https://evil.example/not-official.apk' };
  await writeFile(path.join(f.root, PUBLIC_FILES[0]), JSON.stringify(changedManifest));
  i.release.assets[0].digest = null;
  await assert.rejects(distribute({ ...f, ...i }), /trusted expected/);
  await assert.rejects(access(f.outputDir), { code: 'ENOENT' });
});

test('missing URL fails before any files are modified', async t => {
  const contents = publicFixture(); contents[PUBLIC_FILES[2]] = '<small>Current version 0.2.5</small>';
  const f = await fixture(t, contents);
  await assert.rejects(distribute({ ...f, ...input() }), /APK link not found/);
  await assertUntouched(f);
});

test('missing mock version label fails before any files are modified', async t => {
  const contents = publicFixture(); contents[PUBLIC_FILES[2]] = contents[PUBLIC_FILES[2]].replace('Current version', 'Illustrated version');
  const f = await fixture(t, contents);
  await assert.rejects(distribute({ ...f, ...input() }), /update preview version/);
  await assertUntouched(f);
});

test('existing temporary public output fails preflight before any public writes', async t => {
  const f = await fixture(t);
  await writeFile(path.join(f.root, 'README.md.release-tmp'), 'other process output');
  await assert.rejects(distribute({ ...f, ...input() }), /Temporary output already exists/);
  for (const file of PUBLIC_FILES) assert.equal(await readFile(path.join(f.root, file), 'utf8'), f.contents[file]);
});

test('the requested v0.6.0 release uses the same dynamic validation and synchronization path', async t => {
  const f = await fixture(t), result = await distribute({ ...f, ...input('0.6.0', 2011) });
  assert.equal(result.version, '0.6.0'); assert.equal(result.apkUrl, assetUrl('0.6.0'));
  const manifest = JSON.parse(await readFile(path.join(f.root, PUBLIC_FILES[0]), 'utf8'));
  assert.equal(manifest.versionName, '0.6.0'); assert.equal(manifest.versionCode, 2011);
});

test('binary public file is rejected before writes', async t => {
  const contents = publicFixture(); contents['README.md'] += '\0';
  const f = await fixture(t, contents);
  await assert.rejects(distribute({ ...f, ...input() }), /binary/);
  await assertUntouched(f);
});

test('artifact directory inside checkout is rejected before writes', async t => {
  const f = await fixture(t);
  await assert.rejects(distribute({ ...f, ...input(), outputDir: path.join(f.root, 'kit') }), /outside the checkout/);
  await assertUntouched(f);
});

test('symlinked public directory cannot escape the checkout', async t => {
  const f = await fixture(t);
  const outside = path.join(f.base, 'outside'); await mkdir(outside);
  await writeFile(path.join(outside, 'index.html'), f.contents[PUBLIC_FILES[2]]);
  await rm(path.join(f.root, 'website/dist/en'), { recursive: true });
  try { await symlink(outside, path.join(f.root, 'website/dist/en'), process.platform === 'win32' ? 'junction' : 'dir'); }
  catch (error) { if (error.code === 'EPERM') { t.skip('Host disallows symlinks'); return; } throw error; }
  await assert.rejects(distribute({ ...f, ...input() }), /symlink/);
  assert.equal(await readFile(path.join(outside, 'index.html'), 'utf8'), f.contents[PUBLIC_FILES[2]]);
  await assert.rejects(access(f.outputDir), { code: 'ENOENT' });
});

test('CLI rejects malformed metadata and Android tool failure without generating public output', async t => {
  const f = await fixture(t), i = input();
  const metadataPath = path.join(f.base, 'release.json'), apkPath = path.join(f.base, 'download.apk');
  await writeFile(metadataPath, JSON.stringify(i.release)); await writeFile(apkPath, apkBytes);
  const script = fileURLToPath(new URL('../release-distribution.mjs', import.meta.url));
  const args = ['--root', f.root, '--release-json', metadataPath, '--tag', 'v0.2.6', '--apk', apkPath, '--output', f.outputDir, '--aapt', path.join(f.base, 'nonexistent-tool'), '--apksigner', path.join(f.base, 'nonexistent-signer')];
  const failedTool = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  assert.equal(failedTool.status, 1); await assertUntouched(f);
  args[args.indexOf('--tag') + 1] = 'v../../escape';
  const failedTag = spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  assert.equal(failedTag.status, 1); assert.match(failedTag.stderr, /canonical/); await assertUntouched(f);
});

test('workflow gates downstream commit/deploy on verification, explicitly deploys bot pushes, and stages only allowlisted files', async () => {
  const workflow = await readFile(new URL('../../.github/workflows/release-distribution.yml', import.meta.url), 'utf8');
  assert.ok(workflow.indexOf('Verify APK and synchronize') < workflow.indexOf('Upload Uptodown'));
  assert.ok(workflow.indexOf('Upload Uptodown') < workflow.indexOf('Commit only generated'));
  assert.match(workflow, /if: steps\.generate\.outputs\.changed == 'true'/);
  assert.equal((workflow.match(/if: steps\.generate\.outputs\.stale == 'false'/g) || []).length, 3);
  assert.match(workflow, /actions\/deploy-pages@v4/);
  assert.match(workflow, /git add -- website\/dist\/update\.json website\/dist\/index\.html website\/dist\/en\/index\.html README\.md/);
  assert.ok(!workflow.includes('git add .')); assert.ok(!workflow.includes('git push --force'));
  assert.equal((workflow.match(/if: always\(\)/g) || []).length, 1);
  assert.match(workflow, /group: github-pages/); assert.match(workflow, /cancel-in-progress: false/);
  assert.match(workflow, /needs: validate-windows/);
  assert.match(workflow, /run: \.\/scripts\/test-desktop-client\.ps1/);
  assert.match(workflow, /Start-Process -FilePath \$assetPath -ArgumentList '--self-test' -Wait -PassThru -WindowStyle Hidden/);
  assert.match(workflow, /Get-FileHash -LiteralPath \$assetPath -Algorithm SHA256/);
  assert.equal((workflow.match(/gh api /g) || []).length, 1);
  assert.equal((workflow.match(/name: verified-release-snapshot/g) || []).length, 1);
  const [windows, publication] = workflow.split(/^  distribute:/m);
  assert.ok(windows.indexOf('Persist verified release metadata') > windows.indexOf('Verify downloaded Windows assets'));
  assert.ok(publication.includes('actions/download-artifact@v4'));
  assert.ok(!publication.includes('gh api '));
  assert.equal((workflow.match(/validateDesktopIdentity\(/g) || []).length, 3);
  assert.equal((workflow.match(/diagnostic: true/g) || []).length, 2);
  assert.ok(windows.indexOf('Portable package release identity mismatch') < windows.indexOf("Join-Path $downloadRoot 'portable-diagnostic.json'"));
});

test('immutable uploads are unique per retry while publication keeps the successful producer artifact ID', async () => {
  const workflow = await readFile(new URL('../../.github/workflows/release-distribution.yml', import.meta.url), 'utf8');
  const [producer, consumer] = workflow.split(/^  distribute:/m);
  const snapshotTemplate = producer.match(/^\s+name: (verified-release-snapshot-.*)$/m)?.[1];
  const kitTemplate = consumer.match(/^\s+name: (uptodown-submission-.*)$/m)?.[1];
  assert.ok(snapshotTemplate && kitTemplate);
  const render = (template, attempt) => template.replaceAll('${{ github.run_id }}', '12345').replaceAll('${{ github.run_attempt }}', String(attempt)).replaceAll('${{ env.RELEASE_TAG }}', 'v0.6.0');
  assert.equal(render(snapshotTemplate, 1), 'verified-release-snapshot-12345-1');
  assert.equal(render(snapshotTemplate, 2), 'verified-release-snapshot-12345-2');
  assert.equal(render(kitTemplate, 1), 'uptodown-submission-v0.6.0-12345-1');
  assert.equal(render(kitTemplate, 2), 'uptodown-submission-v0.6.0-12345-2');
  assert.match(producer, /release-artifact-id: \$\{\{ steps\.snapshot\.outputs\.artifact-id \}\}/);
  assert.match(producer, /id: snapshot\s+uses: actions\/upload-artifact@v4/);
  assert.match(consumer, /artifact-ids: \$\{\{ needs\.validate-windows\.outputs\.release-artifact-id \}\}/);
  assert.match(consumer, /merge-multiple: true/);
  const download = consumer.match(/uses: actions\/download-artifact@v4[\s\S]*?      - name:/)?.[0];
  assert.ok(download);
  assert.ok(!download.includes('github.run_attempt'));
  assert.ok(!download.includes('name: verified-release-snapshot'));
});
