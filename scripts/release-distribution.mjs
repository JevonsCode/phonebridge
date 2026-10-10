import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstat, mkdir, readFile, realpath, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPOSITORY = 'JevonsCode/phonebridge';
export const PACKAGE = 'dev.phonebridge.phonebridge';
export const CERTIFICATE = '8ce72b7e5687933ea65307b99d3e2b1e41c837a26d18740f9dbc72aeb0bcdbc0';
export const PUBLIC_FILES = ['website/dist/update.json', 'website/dist/index.html', 'website/dist/en/index.html', 'README.md'];
const CONSOLE_URL = 'https://www.uptodown.dev/apps/1000896707';
const SHA256 = /^[a-f0-9]{64}$/;
const apkLinks = /https:\/\/github\.com\/JevonsCode\/phonebridge\/releases\/download\/v\d+\.\d+\.\d+\/phonebridge-\d+\.\d+\.\d+-arm64\.apk/g;

function requireThat(condition, message) {
  if (!condition) throw new Error(message);
}

export function parseVersion(version) {
  requireThat(typeof version === 'string' && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version), 'Version must be a canonical major.minor.patch');
  const numbers = version.split('.').map(Number);
  requireThat(numbers.every(Number.isSafeInteger), 'Version component is too large');
  return numbers;
}

function compareVersions(a, b) {
  const aa = parseVersion(a), bb = parseVersion(b);
  for (let i = 0; i < 3; i++) if (aa[i] !== bb[i]) return aa[i] > bb[i] ? 1 : -1;
  return 0;
}

export function selectReleaseAsset(release, expectedTag = release?.tag_name) {
  requireThat(typeof expectedTag === 'string' && expectedTag.startsWith('v'), 'Release tag must start with v');
  const version = expectedTag.slice(1);
  parseVersion(version);
  requireThat(release?.tag_name === expectedTag && release.draft === false && typeof release.published_at === 'string' && Number.isFinite(Date.parse(release.published_at)), 'Release must be published and match the requested tag');
  requireThat(Array.isArray(release.assets), 'Release assets are missing');
  const name = `phonebridge-${version}-arm64.apk`;
  const assets = release.assets.filter(asset => asset.name === name);
  requireThat(assets.length === 1, 'Expected exactly one named ARM64 APK');
  const asset = assets[0];
  const url = `https://github.com/${REPOSITORY}/releases/download/${expectedTag}/${name}`;
  requireThat(asset.browser_download_url === url, 'APK URL must be the exact official release asset URL');
  requireThat(Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size <= 2147483647, 'APK asset size is invalid');
  requireThat(asset.state === 'uploaded', 'APK asset upload is incomplete');
  let digest;
  if (asset.digest != null) {
    requireThat(typeof asset.digest === 'string' && /^sha256:[a-f0-9]{64}$/.test(asset.digest), 'Invalid GitHub asset SHA-256 digest');
    digest = asset.digest.slice(7);
  }
  return { version, tag: expectedTag, name, url, size: asset.size, digest };
}

export function selectDesktopAssets(release, expectedTag = release?.tag_name) {
  const android = selectReleaseAsset(release, expectedTag);
  const selected = [];
  for (const [suffix, kind] of [['windows-setup.exe', 'installer'], ['windows-x64.zip', 'portable']]) {
    const name = `phonebridge-${android.version}-${suffix}`;
    const matches = release.assets.filter(asset => asset.name === name);
    requireThat(matches.length <= 1, 'Duplicate Windows release asset');
    if (!matches.length) continue;
    const asset = matches[0];
    const url = `https://github.com/${REPOSITORY}/releases/download/${expectedTag}/${name}`;
    requireThat(asset.browser_download_url === url && asset.state === 'uploaded', 'Windows asset must use the exact official uploaded release URL');
    requireThat(Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size <= 2147483647, 'Windows asset size is invalid');
    requireThat(typeof asset.digest === 'string' && /^sha256:[a-f0-9]{64}$/.test(asset.digest), 'Windows asset must include GitHub SHA-256 digest');
    selected.push({ kind, name, url, size: asset.size, sha256: asset.digest.slice(7) });
  }
  return selected;
}

export function validateDesktopIdentity(identity, tag, { diagnostic = false } = {}) {
  requireThat(typeof tag === 'string' && tag.startsWith('v'), 'Desktop identity requires a v-prefixed release tag');
  const version = tag.slice(1);
  parseVersion(version);
  requireThat(identity && typeof identity === 'object' && !Array.isArray(identity), 'Desktop identity report must be an object');
  requireThat(identity.product === 'PhoneBridge', 'Desktop product identity is incorrect');
  requireThat(identity.version === version, 'Desktop package version does not match release tag');
  requireThat(identity.platform === 'windows-x64', 'Desktop platform must be windows-x64');
  if (diagnostic) requireThat(identity.dryRun === true, 'Desktop diagnostic must confirm dryRun=true');
  return { product: identity.product, version: identity.version, platform: identity.platform };
}

export function parseAndroidReports(badging, signerReport) {
  const packageLines = [...badging.matchAll(/^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'[^\r\n]*$/gm)];
  requireThat(packageLines.length === 1, 'aapt must report exactly one package');
  const [, packageName, code, versionName] = packageLines[0];
  requireThat(/^[1-9]\d*$/.test(code), 'APK versionCode is invalid');
  const versionCode = Number(code);
  requireThat(Number.isSafeInteger(versionCode) && versionCode <= 2100000000, 'APK versionCode is outside Android limits');
  const native = badging.match(/^native-code:\s*([^\r\n]+)$/m)?.[1];
  requireThat(native?.trim() === "'arm64-v8a'", 'APK must contain only ARM64 native libraries');
  const certificates = [...signerReport.matchAll(/^Signer #\d+ certificate SHA-256 digest:\s*([a-fA-F0-9:]+)\s*$/gm)].map(match => match[1].replaceAll(':', '').toLowerCase());
  requireThat(certificates.length === 1 && certificates[0] === CERTIFICATE, 'APK signing certificate does not match the existing preview identity');
  return { packageName, versionName, versionCode, certificate: certificates[0] };
}

export function verifyApk({ release, tag, apkBytes, badging, signerReport, expectedHash }) {
  const asset = selectReleaseAsset(release, tag);
  const android = parseAndroidReports(badging, signerReport);
  requireThat(android.packageName === PACKAGE, 'APK package name is incorrect');
  requireThat(android.versionName === asset.version, 'APK versionName does not match release tag');
  requireThat(apkBytes.length === asset.size, 'Downloaded APK size does not match release metadata');
  const sha256 = createHash('sha256').update(apkBytes).digest('hex');
  if (expectedHash !== undefined && expectedHash !== '') {
    requireThat(SHA256.test(expectedHash), 'Expected SHA-256 must be 64 lowercase hexadecimal characters');
    requireThat(sha256 === expectedHash, 'Downloaded APK does not match expected SHA-256');
  }
  requireThat(asset.digest || expectedHash, 'GitHub asset digest is absent; provide a trusted expected SHA-256');
  if (asset.digest) requireThat(sha256 === asset.digest, 'Downloaded APK SHA-256 does not match GitHub asset digest');
  return { ...asset, ...android, sha256 };
}

export function createPublicUpdates(current, files, verified, notes, desktopAssets = []) {
  requireThat(current?.schema === 1 && Number.isSafeInteger(current.versionCode) && current.versionCode > 0 && SHA256.test(current.sha256), 'Existing update manifest is invalid');
  const order = compareVersions(verified.version, current.versionName);
  if (order < 0) {
    requireThat(verified.versionCode < current.versionCode, 'Older version has a conflicting versionCode');
    return { stale: true, updates: {} };
  }
  if (order === 0) requireThat(verified.versionCode === current.versionCode && verified.sha256 === current.sha256 && verified.url === current.apkUrl && verified.size === current.size, 'An existing release cannot be silently replaced');
  if (order > 0) requireThat(verified.versionCode > current.versionCode, 'Newer version must increase versionCode');
  const updates = {};
  for (const file of PUBLIC_FILES.slice(1)) {
    const original = files[file];
    requireThat(typeof original === 'string' && !original.includes('\0'), `Public text file is missing or binary: ${file}`);
    requireThat((original.match(apkLinks) || []).length > 0, `Official APK link not found in ${file}`);
    let updated = original.replace(apkLinks, verified.url);
    for (const desktop of desktopAssets) {
      const suffix = desktop.kind === 'installer' ? 'windows-setup\\.exe' : 'windows-x64\\.zip';
      const links = new RegExp(`https://github\\.com/JevonsCode/phonebridge/releases/download/v[0-9]+\\.[0-9]+\\.[0-9]+/phonebridge-[0-9]+\\.[0-9]+\\.[0-9]+-${suffix}`, 'g');
      updated = updated.replace(links, desktop.url);
    }
    if (file.endsWith('index.html')) {
      const label = file.includes('/en/') ? 'Current version' : '当前版本';
      const pattern = new RegExp(`${label} [0-9]+\\.[0-9]+\\.[0-9]+`, 'g');
      requireThat((original.match(pattern) || []).length === 1, `Expected one update preview version in ${file}`);
      updated = updated.replace(pattern, `${label} ${verified.version}`);
    }
    updates[file] = updated;
  }
  const manifest = { schema: 1, versionName: verified.version, versionCode: verified.versionCode, apkUrl: verified.url, sha256: verified.sha256, size: verified.size, notes: notes ?? current.notes ?? '' };
  requireThat(typeof manifest.notes === 'string' && manifest.notes.length <= 10000, 'Release notes must be text under 10000 characters');
  updates[PUBLIC_FILES[0]] = `${JSON.stringify(manifest, null, 2)}\n`;
  return { stale: false, updates };
}

function submissionKit(verified, stale, desktopAssets) {
  const descriptions = {
    zh: 'PhoneBridge 是供机主授权使用的 Android 无障碍桥接工具。手机与机主的本地 Hub 配对，现有 MCP AI 客户端可读取允许应用的界面、截图，并在手机端开启操作后点击、滑动和输入。默认只读，无内置大模型、云端中转、遥测或账号；无法绕过锁屏、应用沙箱或受保护截图。这是采用现有 debug 签名的早期开发者预览版，兼容性以仓库验证记录为准。',
    en: 'PhoneBridge is an owner-authorized Android accessibility bridge. The phone pairs with the owner\'s local Hub so existing MCP AI clients can inspect allowed apps, take screenshots, and tap, swipe or type after actions are enabled on the phone. It starts read-only and includes no AI model, cloud relay, telemetry or account. It cannot bypass lock screens, app sandboxes or protected screenshots. This is an early developer preview using the existing debug signing identity; compatibility is limited to the repository\'s verification record.'
  };
  const metadata = { app: 'PhoneBridge', packageName: PACKAGE, tag: verified.tag, versionName: verified.version, versionCode: verified.versionCode, apkUrl: verified.url, sha256: verified.sha256, size: verified.size, certificateSha256: verified.certificate, desktopAssets, consoleUrl: CONSOLE_URL, status: 'manual-or-editorial-review-required', staleOfficialTrigger: stale, descriptions };
  const markdown = `# PhoneBridge ${verified.tag}: Uptodown submission kit\n\n- APK: ${verified.url}\n- SHA-256: \`${verified.sha256}\`\n- Bytes: ${verified.size}\n- Package: ${PACKAGE}\n- versionCode: ${verified.versionCode}\n- Signing certificate SHA-256: \`${verified.certificate}\`\n- Existing developer console: ${CONSOLE_URL}\n\n## 中文介绍\n\n${descriptions.zh}\n\n## English description\n\n${descriptions.en}\n\n## Distribution status\n\nNo store API upload was performed. Use the existing console for submission if editorial tracking has not collected this official release. Keep editorial tracking of the official source enabled. A console app record or this kit does not prove public listing, editorial approval, or store propagation. Public Uptodown availability requires a separate live check.\n${stale ? '\nThis trigger is older than the official manifest; public download files and Pages were preserved.\n' : ''}`;
  const desktopMarkdown = desktopAssets.length ? `\n## Optional Windows release assets\n\n${desktopAssets.map(asset => `- ${asset.kind}: ${asset.url}\n  - SHA-256: \`${asset.sha256}\`; bytes: ${asset.size}`).join('\n')}\n\nWindows workflow validation must independently check downloaded bytes and dry-run diagnostics. These are companion desktop assets, not an Android store upload.\n` : '';
  return { metadata, markdown: markdown + desktopMarkdown };
}

function inside(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

async function safePublicPath(root, relative) {
  requireThat(PUBLIC_FILES.includes(relative), 'Refusing a non-allowlisted public path');
  let cursor = root;
  for (const part of relative.split('/')) {
    cursor = path.join(cursor, part);
    requireThat(!(await lstat(cursor)).isSymbolicLink(), `Refusing symlink in public path: ${relative}`);
  }
  requireThat(inside(root, await realpath(cursor)), 'Public path escapes checkout');
  requireThat((await lstat(cursor)).isFile(), 'Public path must be a regular file');
  return cursor;
}

export async function distribute({ root, release, tag, apkBytes, badging, signerReport, expectedHash, outputDir }) {
  root = await realpath(root);
  const targets = {}, files = {};
  for (const relative of PUBLIC_FILES) {
    targets[relative] = await safePublicPath(root, relative);
    files[relative] = await readFile(targets[relative], 'utf8');
  }
  const current = JSON.parse(files[PUBLIC_FILES[0]]);
  const candidate = selectReleaseAsset(release, tag);
  // A previously verified checked-in hash is a fallback only for the exact release and URL.
  const trustedHash = expectedHash || (current.versionName === candidate.version && current.apkUrl === candidate.url ? current.sha256 : undefined);
  const verified = verifyApk({ release, tag, apkBytes, badging, signerReport, expectedHash: trustedHash });
  const desktopAssets = selectDesktopAssets(release, tag);
  const generated = createPublicUpdates(current, files, verified, release.body || undefined, desktopAssets);
  requireThat(typeof outputDir === 'string', 'An output directory outside the checkout is required');
  outputDir = path.resolve(outputDir);
  requireThat(!inside(root, outputDir), 'Submission artifacts must be outside the checkout');
  await mkdir(outputDir, { recursive: true });
  requireThat(!inside(root, await realpath(outputDir)), 'Submission output resolves inside checkout');
  const kit = submissionKit(verified, generated.stale, desktopAssets);
  // All validation and transformations finish before any public file is written.
  for (const relative of Object.keys(generated.updates)) {
    const temporary = `${targets[relative]}.release-tmp`;
    requireThat(!(await lstat(temporary).catch(error => error.code === 'ENOENT' ? null : Promise.reject(error))), 'Temporary output already exists');
  }
  let changed = false;
  for (const [relative, text] of Object.entries(generated.updates)) {
    if (text === files[relative]) continue;
    const temporary = `${targets[relative]}.release-tmp`;
    await writeFile(temporary, text, { flag: 'wx' });
    await rename(temporary, targets[relative]);
    changed = true;
  }
  const result = { tag: verified.tag, version: verified.version, sha256: verified.sha256, size: verified.size, apkUrl: verified.url, stale: generated.stale, changed };
  await writeFile(path.join(outputDir, 'uptodown-submission.json'), `${JSON.stringify(kit.metadata, null, 2)}\n`);
  await writeFile(path.join(outputDir, 'uptodown-submission.md'), kit.markdown);
  await writeFile(path.join(outputDir, 'result.json'), `${JSON.stringify(result, null, 2)}\n`);
  await writeFile(path.join(outputDir, 'summary.md'), `## PhoneBridge ${verified.tag}\n\nVerified existing signed ARM64 APK: [download](${verified.url}).\n\nSHA-256: \`${verified.sha256}\`; bytes: ${verified.size}.\n\n${generated.stale ? 'Older trigger: newer official public files are preserved; Pages deployment is skipped.' : 'Official manifest and bilingual APK links are synchronized. The following workflow steps commit and deploy Pages; their own status determines publication success.'}\n\nUptodown: submission kit generated; manual/editorial review remains. [Existing developer console](${CONSOLE_URL}). No store upload or public listing is claimed.\n`);
  return result;
}

async function main() {
  const options = {};
  const args = process.argv.slice(2);
  requireThat(args.length % 2 === 0, 'Arguments must be --name value pairs');
  for (let i = 0; i < args.length; i += 2) {
    requireThat(['--root', '--release-json', '--tag', '--apk', '--output', '--aapt', '--apksigner', '--expected-sha256'].includes(args[i]) && !(args[i] in options), 'Unknown or duplicate CLI option');
    options[args[i]] = args[i + 1];
  }
  for (const key of ['--root', '--release-json', '--tag', '--apk', '--output', '--aapt', '--apksigner']) requireThat(options[key], `Missing ${key}`);
  const release = JSON.parse(await readFile(options['--release-json'], 'utf8'));
  selectReleaseAsset(release, options['--tag']);
  requireThat(!inside(await realpath(options['--root']), await realpath(options['--apk'])), 'APK download must be outside the checkout');
  const badging = execFileSync(options['--aapt'], ['dump', 'badging', options['--apk']], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  // execFileSync throws on invalid signatures; certificate text alone is never verification.
  const signerReport = execFileSync(options['--apksigner'], ['verify', '--verbose', '--print-certs', options['--apk']], { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const result = await distribute({ root: options['--root'], release, tag: options['--tag'], apkBytes: await readFile(options['--apk']), badging, signerReport, expectedHash: options['--expected-sha256'], outputDir: options['--output'] });
  console.log(JSON.stringify(result));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
