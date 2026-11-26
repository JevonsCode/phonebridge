import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const read = file => readFile(new URL('../dist/' + file, import.meta.url), 'utf8');
const source = await read('downloads.js');
const zh = await read('index.html');
const en = await read('en/index.html');

async function visit(navigator, html = zh) {
  const elements = new Map();
  for (const match of html.matchAll(/<[\w-]+\b[^<>]*\bid="([^"]+)"[^<>]*>/g)) {
    const tag = match[0];
    elements.set(match[1], {
      href: tag.match(/ href="([^"]+)"/)?.[1],
      dataset: { cta: tag.match(/ data-cta="([^"]+)"/)?.[1] },
      classList: new Set()
    });
  }
  const document = { documentElement: { lang: html === en ? 'en' : 'zh-CN' }, getElementById: id => elements.get(id) };
  vm.runInNewContext(source, { navigator, document });
  await new Promise(resolve => setImmediate(resolve));
  return { primary: elements.get('primary-download'), note: elements.get('device-note'), label: elements.get('download-label'), elements };
}

const mac = { platform: 'MacIntel', userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' };
function hints(platform, architecture, bitness = '64', wow64 = false) {
  return { platform, getHighEntropyValues: async () => ({ architecture, bitness, wow64 }) };
}

for (const [name, nav, expected] of [
  ['Apple silicon with Intel in the user agent', { ...mac, userAgentData: hints('macOS', 'arm') }, 'mac-arm'],
  ['Intel Mac', { ...mac, userAgentData: hints('macOS', 'x86') }, 'mac-intel'],
  ['64-bit Windows', { platform: 'Win32', userAgentData: hints('Windows', 'x86') }, 'windows'],
  ['Windows without client hints', { platform: 'Win32', userAgent: 'Windows NT 10.0; Win64; x64' }, 'windows'],
  ['32-bit browser on 64-bit Windows', { platform: 'Win32', userAgentData: hints('Windows', 'x86', '32', true) }, 'windows'],
  ['Android with legacy user agent', { platform: 'Linux armv8l', userAgent: 'Linux; Android 10; K' }, 'android'],
  ['Android with client hints', { userAgentData: hints('Android', 'arm') }, 'android']
]) {
  test(name + ' recommends an existing installer in both languages', async () => {
    for (const html of [zh, en]) {
      const { primary, label, elements } = await visit(nav, html);
      const pkg = elements.get(expected);
      assert.match(primary.href, /^https:\/\/github\.com\/JevonsCode\/phonebridge\/releases\/download\//);
      assert.equal(primary.href, pkg.href);
      assert.equal(label.textContent, pkg.dataset.cta);
      assert.ok(pkg.classList.has('recommended'));
      assert.equal(elements.get('all-downloads').href, '#downloads');
    }
  });
}

test('both Mac downloads are accessible when the browser withholds the chip', async () => {
  for (const nav of [mac, { ...mac, userAgentData: { getHighEntropyValues: async () => { throw Error('denied'); } } }]) {
    const { primary, elements, note } = await visit(nav);
    assert.equal(primary.href, '#mac-downloads');
    assert.match(note.textContent, /关于本机/);
    assert.match(elements.get('mac-arm').href, /-macos-arm64\.dmg$/);
    assert.match(elements.get('mac-intel').href, /-macos-x64\.dmg$/);
  }
});

test('iOS and iPadOS never suggest an Android or Mac installer', async () => {
  for (const nav of [{ platform: 'iPhone', userAgent: 'iPhone' }, { ...mac, maxTouchPoints: 5 }]) {
    const { primary, note } = await visit(nav);
    assert.equal(primary.href, '#downloads');
    assert.match(note.textContent, /iOS/);
  }
});

test('unsupported systems keep the platform chooser', async () => {
  for (const nav of [{}, { platform: 'Linux x86_64' }, { platform: 'Linux', userAgent: 'CrOS' },
    { userAgentData: hints('Windows', 'arm') }, { userAgentData: hints('Windows', 'x86', '32') },
    { userAgentData: hints('Android', 'x86') }]) {
    assert.equal((await visit(nav)).primary.href, '#downloads');
  }
});

test('without scripts both languages link to the chooser and all installers', () => {
  for (const html of [zh, en]) {
    assert.match(html, /id="primary-download" href="#downloads"/);
    for (const suffix of ['macos-arm64.dmg', 'macos-x64.dmg', 'windows-setup.exe', 'windows-x64.zip', 'arm64.apk']) {
      assert.ok(html.includes(suffix + '"'));
    }
  }
});
