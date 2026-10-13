import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFile, writeFile, unlink, lstat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { REPOSITORY, selectReleaseAsset } from './release-distribution.mjs';

const START = '<!-- phonebridge-download-qr:start -->';
const END = '<!-- phonebridge-download-qr:end -->';
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const requireThat = (condition, message) => { if (!condition) throw new Error(message); };

export function validateQrPublication({ release, result, png }) {
  const apk = selectReleaseAsset(release, result.tag);
  requireThat(result.version === apk.version && result.apkUrl === apk.url && result.size === apk.size, 'QR must refer to the verified official APK');
  requireThat(/^[a-f0-9]{64}$/.test(result.sha256) && (!apk.digest || apk.digest === result.sha256), 'Published APK digest changed after verification');
  const name = `phonebridge-${apk.version}-android-download-qr.png`;
  requireThat(result.qrName === name, 'Invalid QR asset name');
  requireThat(Buffer.isBuffer(png) && png.length > 8 && png.length <= 1024 * 1024 && png.subarray(0, 8).equals(PNG_SIGNATURE), 'Expected a bounded PNG');
  const sha256 = createHash('sha256').update(png).digest('hex');
  requireThat(sha256 === result.qrSha256, 'QR content differs from the verified generation result');
  const url = `https://github.com/${REPOSITORY}/releases/download/${apk.tag}/${name}`;
  const existing = release.assets.filter(asset => asset.name === name);
  requireThat(existing.length <= 1, 'Duplicate existing QR assets');
  if (existing.length) {
    const asset = existing[0];
    requireThat(asset.state === 'uploaded' && asset.browser_download_url === url && asset.size === png.length && asset.digest === `sha256:${sha256}`, 'Existing QR asset differs; refusing replacement');
  }
  return { name, url, sha256, uploadRequired: existing.length === 0 };
}

export function buildDownloadQrNotes(body, result) {
  requireThat(typeof body === 'string', 'Release notes must be text');
  const starts = body.split(START).length - 1, ends = body.split(END).length - 1;
  requireThat(starts === ends && starts <= 1 && (!starts || body.indexOf(START) < body.indexOf(END)), 'Invalid managed QR section');
  const url = `https://github.com/${REPOSITORY}/releases/download/${result.tag}/${result.qrName}`;
  const section = `${START}\n## 安卓扫码下载 / Android download\n\n用手机浏览器扫码下载 PhoneBridge ${result.version}（Android 11+ · ARM64）。\nScan with your phone to download the Android APK.\n\n[![PhoneBridge ${result.version} Android download QR](${url})](${result.apkUrl})\n\n[直接下载 APK / Download APK](${result.apkUrl})\n${END}`;
  return starts ? body.slice(0, body.indexOf(START)) + section + body.slice(body.indexOf(END) + END.length) : `${body.trimEnd()}\n\n${section}\n`;
}

function github(args) {
  return execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
}

async function main() {
  requireThat(process.argv.length === 3, 'Usage: node scripts/publish-download-qr.mjs /path/to/verified-output');
  const directory = path.resolve(process.argv[2]);
  const result = JSON.parse(await readFile(path.join(directory, 'result.json'), 'utf8'));
  // Validate the tag/name before using either as an API or filesystem component.
  requireThat(/^v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/.test(result.tag), 'Invalid release tag');
  requireThat(result.qrName === `phonebridge-${result.tag.slice(1)}-android-download-qr.png`, 'Invalid QR asset name');
  const file = path.join(directory, result.qrName);
  const stat = await lstat(file);
  requireThat(stat.isFile() && !stat.isSymbolicLink() && stat.size <= 1024 * 1024, 'Expected a regular QR PNG');
  const png = await readFile(file);
  const endpoint = `repos/${REPOSITORY}/releases/tags/${result.tag}`;
  let release = JSON.parse(github(['api', endpoint]));
  let plan = validateQrPublication({ release, result, png });
  if (plan.uploadRequired) github(['release', 'upload', result.tag, file, '--repo', REPOSITORY]);
  // Preserve the latest authored notes and revalidate assets after the upload.
  release = JSON.parse(github(['api', endpoint]));
  plan = validateQrPublication({ release, result, png });
  requireThat(!plan.uploadRequired, 'QR upload was not confirmed');
  requireThat(Number.isSafeInteger(release.id) && release.id > 0, 'Invalid release ID');
  const body = buildDownloadQrNotes(release.body ?? '', result);
  if (body !== (release.body ?? '')) {
    const payload = path.join(directory, 'release-qr-notes.json');
    await writeFile(payload, JSON.stringify({ body }), { flag: 'wx', mode: 0o600 });
    try { github(['api', '--method', 'PATCH', `repos/${REPOSITORY}/releases/${release.id}`, '--input', payload]); }
    finally { await unlink(payload); }
  }
  const published = JSON.parse(github(['api', endpoint]));
  requireThat(published.body === body, 'Published QR notes did not match');
  validateQrPublication({ release: published, result, png });
  console.log(JSON.stringify({ tag: result.tag, qrUrl: plan.url, qrSha256: plan.sha256, notesVerified: true }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
