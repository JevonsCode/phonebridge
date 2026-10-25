import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawnSync } from 'node:child_process';

const windows = process.platform === 'win32';
const root = fileURLToPath(new URL('../../', import.meta.url));
const powershell = join(process.env.SystemRoot ?? '', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const helper = join(root, 'scripts', 'windows', 'package-archive.ps1');
const version = '9.8.7';
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'phonebridge-installer-archive-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}
function ps(host, script, args) {
  return execFileSync(host, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, ...args], { encoding: 'utf8', windowsHide: true });
}

test('Windows PowerShell 5.1 and PowerShell 7 create canonical ZIP names with the actual packaging helper', { skip: !windows }, async t => {
  const directory = await fixture(t), source = join(directory, 'source');
  for (const name of ['runtime', 'desktop', 'empty', 'docs']) await mkdir(join(source, name), { recursive: true });
  for (const name of ['PhoneBridge.exe', 'runtime/node.exe', 'desktop/server.mjs', 'docs/中文.txt']) await writeFile(join(source, name), 'fixture');
  const script = join(directory, 'archive.ps1');
  await writeFile(script, `param($Helper,$Source,$Archive)
$ErrorActionPreference='Stop'; [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. $Helper
New-PhoneBridgePackageArchive -SourceDirectory $Source -ArchivePath $Archive
$zip=[IO.Compression.ZipFile]::OpenRead($Archive)
try { ConvertTo-Json -InputObject @($zip.Entries | ForEach-Object FullName) -Compress } finally { $zip.Dispose() }
`);
  for (const [label, host] of [['Windows PowerShell 5.1', powershell], ['PowerShell 7', 'pwsh']]) {
    await t.test(label, child => {
      const probe = spawnSync(host, ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8', windowsHide: true });
      if (probe.error?.code === 'ENOENT') { child.skip('Host unavailable'); return; }
      assert.equal(probe.status, 0, probe.stderr);
      const entries = JSON.parse(ps(host, script, [helper, source, join(directory, `${label}.zip`)]));
      assert.equal(entries.some(name => name.includes('\\')), false);
      for (const name of ['runtime/node.exe', 'desktop/server.mjs', 'docs/中文.txt', 'empty/']) assert.ok(entries.includes(name), name);
    });
  }
});

test('the real installer diagnose entry accepts legacy/current separators and rejects normalized collisions before installation', { skip: !windows, timeout: 60000 }, async t => {
  const directory = await fixture(t), generated = join(directory, 'Installer.generated.cs');
  await writeFile(generated, '\ufeff' + (await readFile(join(root, 'desktop', 'Installer.cs'), 'utf8')).replaceAll('__VERSION__', version));
  const create = join(directory, 'raw-zip.ps1');
  await writeFile(create, `param($Spec,$Archive)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
$stream=[IO.File]::Open($Archive,[IO.FileMode]::CreateNew)
$zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
try { foreach($row in (Get-Content -LiteralPath $Spec -Raw -Encoding UTF8 | ConvertFrom-Json)) { $entry=$zip.CreateEntry($row.name); $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false))); try{$writer.Write([string]$row.content)}finally{$writer.Dispose()} } } finally { $zip.Dispose();$stream.Dispose() }
`);
  const required = [
    { name: 'PhoneBridge.exe', content: 'fixture launcher; never executed' },
    { name: 'runtime/node.exe', content: 'fixture node; never executed' },
    { name: 'desktop/server.mjs', content: 'fixture source; never executed' },
    { name: 'package-manifest.json', content: JSON.stringify({ product: 'PhoneBridge', platform: 'windows-x64', version }) },
  ];
  const cases = [
    ['current-slashes', [{ name: 'runtime/', content: '' }, ...required], true],
    ['legacy-backslashes', [{ name: 'runtime\\', content: '' }, ...required.map(row => ({ ...row, name: row.name.replaceAll('/', '\\') }))], true],
    ['mixed-separator-duplicate', [...required, { ...required[1], name: 'runtime\\node.exe' }], false],
    ['case-duplicate', [...required, { ...required[0], name: 'phonebridge.EXE' }], false],
    ['directory-file-alias', [...required, { name: 'runtime/', content: '' }, { name: 'runtime', content: 'conflict' }], false],
    ['file-as-parent', [{ name: 'runtime', content: 'conflict' }, ...required], false],
    ['dot-equivalent', [...required, { name: 'runtime/./node.exe', content: 'alias' }], false],
    ['backslash-traversal', [...required, { name: '..\\escape.txt', content: 'escape' }], false],
    ['required-file-is-directory', required.map(row => row.name === 'runtime/node.exe' ? { ...row, name: 'runtime\\node.exe\\' } : row), false],
  ];
  const csc = join(process.env.SystemRoot, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe');
  for (const [name, rows, accepted] of cases) {
    await t.test(name, async () => {
      const spec = join(directory, name + '.json'), archive = join(directory, name + '.zip'), installer = join(directory, name + '.exe');
      await writeFile(spec, JSON.stringify(rows)); ps(powershell, create, [spec, archive]);
      execFileSync(csc, ['/nologo', '/target:winexe', '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll', '/reference:System.IO.Compression.dll', '/reference:System.IO.Compression.FileSystem.dll', '/out:' + installer, '/resource:' + archive + ',PhoneBridgePackage', generated], { windowsHide: true });
      const report = join(directory, name + ' report.json');
      const result = spawnSync(installer, ['--diagnose', '--report-path', report], { encoding: 'utf8', timeout: 10000, windowsHide: true });
      assert.equal(result.status, accepted ? 0 : 1, result.stderr);
      if (accepted) {
        const diagnosis = JSON.parse(await readFile(report, 'utf8'));
        assert.equal(diagnosis.embeddedPackageValid, true); assert.equal(diagnosis.dryRun, true); assert.equal(diagnosis.pathContainmentPassed, true);
      } else await assert.rejects(readFile(report), /ENOENT/);
    });
  }
});
