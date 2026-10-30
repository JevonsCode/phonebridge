import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { PhoneDirectory } from '../src/phone-directory.js';

test('phone aliases, pauses and deletion survive restart without affecting another phone', t => {
  const dir = mkdtempSync(join(tmpdir(), 'phonebridge-phones-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'phones.json'); let book = new PhoneDirectory(path);
  const a = randomUUID(), b = randomUUID(), pairing = randomUUID();
  assert.equal(book.remember(a, 'Model A', pairing), 'allowed');
  book.remember(b, 'Model B', randomUUID());
  book.update(a, 'rename', '  Work phone  '); book.update(a, 'disconnect');
  book = new PhoneDirectory(path);
  assert.equal(book.get(a)?.alias, 'Work phone');
  assert.equal(book.remember(a, 'Model A', pairing), 'paused');
  assert.equal(book.get(b)?.paused, false);
  book.update(a, 'resume'); assert.equal(book.remember(a, 'Model A', pairing), 'allowed');
  book.update(a, 'delete'); book = new PhoneDirectory(path);
  assert.equal(book.list().length, 1); assert.equal(book.remember(a, 'Model A', pairing), 'removed');
  assert.equal(book.remember(a, 'Model A', randomUUID()), 'allowed');
  assert.equal(book.get(a)?.alias, undefined); assert.equal(book.list().length, 2);
});

test('invalid names and unknown IDs leave the saved phone directory unchanged', () => {
  const book = new PhoneDirectory(); const id = randomUUID(); book.remember(id, 'Phone');
  const original = book.list();
  for (const name of ['', '  ', 'bad\nname', 'x'.repeat(81)]) assert.throws(() => book.update(id, 'rename', name));
  assert.throws(() => book.update(randomUUID(), 'delete')); assert.deepEqual(book.list(), original);
});

test('phone directory refuses symlinks', t => {
  if (process.platform === 'win32') { t.skip('symlink privileges vary'); return; }
  const dir = mkdtempSync(join(tmpdir(), 'phonebridge-phones-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const target = join(dir, 'target.json'); new PhoneDirectory(target).remember(randomUUID(), 'Phone');
  const link = join(dir, 'link.json'); symlinkSync(target, link);
  assert.throws(() => new PhoneDirectory(link));
});
