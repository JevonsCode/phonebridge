import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { buildDownloadQrNotes, validateQrPublication } from '../publish-download-qr.mjs';

const version = '0.6.1';
const apkUrl = `https://github.com/JevonsCode/phonebridge/releases/download/v${version}/phonebridge-${version}-arm64.apk`;
const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 1]); // synthetic transport fixture; real PNG decoding is checked separately.
const qrHash = createHash('sha256').update(png).digest('hex');
const result = { tag: 'v0.6.1', version, apkUrl, size: 12, sha256: 'a'.repeat(64), qrName: 'phonebridge-0.6.1-android-download-qr.png', qrSha256: qrHash };
const release = () => ({ tag_name: result.tag, draft: false, published_at: '2026-10-13T00:00:00Z', body: 'Existing release notes.', assets: [{ name: 'phonebridge-0.6.1-arm64.apk', browser_download_url: apkUrl, size: 12, digest: `sha256:${result.sha256}`, state: 'uploaded' }] });

test('QR publication is bound to the verified official APK and exact PNG bytes', () => {
  const plan = validateQrPublication({ release: release(), result, png });
  assert.equal(plan.name, result.qrName);
  assert.equal(plan.uploadRequired, true);
  for (const mutation of [
    r => { r.apkUrl = 'http://localhost:1234/?key=private'; },
    r => { r.qrName = '../escape.png'; },
    r => { r.qrSha256 = 'b'.repeat(64); },
    r => { r.version = '0.6.2'; },
    r => { r.sha256 = 'c'.repeat(64); }
  ]) { const copy = { ...result }; mutation(copy); assert.throws(() => validateQrPublication({ release: release(), result: copy, png })); }
  const changed = release(); changed.assets[0].size++;
  assert.throws(() => validateQrPublication({ release: changed, result, png }));
});

test('existing QR assets are reused only for identical content, never overwritten', () => {
  const r = release();
  r.assets.push({ name: result.qrName, browser_download_url: `https://github.com/JevonsCode/phonebridge/releases/download/${result.tag}/${result.qrName}`, size: png.length, state: 'uploaded', digest: `sha256:${qrHash}` });
  assert.equal(validateQrPublication({ release: r, result, png }).uploadRequired, false);
  r.assets[1].digest = `sha256:${'d'.repeat(64)}`;
  assert.throws(() => validateQrPublication({ release: r, result, png }), /existing|Existing/);
});

test('release notes keep authored content and contain one idempotent bilingual QR section', () => {
  const before = '# Notes\n\nOriginal description with [a link](https://example.com).\n';
  const after = buildDownloadQrNotes(before, result);
  assert.ok(after.startsWith(before));
  assert.ok(after.includes(`![`)); assert.ok(after.includes(result.qrName));
  assert.ok(after.includes('扫码')); assert.ok(after.includes('Scan'));
  assert.equal(buildDownloadQrNotes(after, result), after);
  assert.equal((after.match(/<!-- phonebridge-download-qr:start -->/g)||[]).length, 1);
  assert.throws(() => buildDownloadQrNotes(`${after}\n${after}`, result), /section/);
});
