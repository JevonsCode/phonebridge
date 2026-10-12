import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { FileTransferSlot } from '../src/file-transfer.js';

async function* bytes(...chunks: Buffer[]) { yield* chunks; }
const metadata = { name: '图片.png', mimeType: 'image/png', size: 3 };

test('one bounded file is offered, verified and released after phone acknowledgement', async () => {
  const slot = new FileTransferSlot({ maxBytes: 16 });
  try {
    const offer = await slot.upload(metadata, bytes(Buffer.from('abc')));
    assert.equal(offer.sha256, createHash('sha256').update('abc').digest('hex'));
    assert.equal(slot.status()?.state, 'pending');
    assert.equal(slot.download(offer.id).toString(), 'abc');
    slot.finish(offer.id, 'received');
    assert.equal(slot.status()?.state, 'received');
    slot.clear(); // A later disconnect does not rewrite a completed receipt.
    assert.equal(slot.status()?.state, 'received');
    assert.throws(() => slot.download(offer.id));
  } finally { slot.clear(); }
});

test('rejects unsafe names, mismatched sizes, excess bytes and simultaneous offers', async () => {
  const slot = new FileTransferSlot({ maxBytes: 16 });
  try {
    for (const name of ['../file', '..', '/tmp/f', 'a\\b', 'a\n.png']) {
      await assert.rejects(slot.upload({ ...metadata, name }, bytes(Buffer.from('abc'))));
    }
    await assert.rejects(slot.upload({ ...metadata, size: 17 }, bytes(Buffer.alloc(17))));
    await assert.rejects(slot.upload(metadata, bytes(Buffer.from('ab'))));
    await assert.rejects(slot.upload(metadata, bytes(Buffer.from('abcd'))));
    const first = await slot.upload(metadata, bytes(Buffer.from('abc')));
    await assert.rejects(slot.upload(metadata, bytes(Buffer.from('abc'))), /already/i);
    assert.equal(slot.download(first.id).toString(), 'abc');
    slot.finish(first.id, 'declined');
    assert.equal(slot.status()?.state, 'declined');
  } finally { slot.clear(); }
});

test('disconnect invalidates an upload already in progress', async () => {
  const slot = new FileTransferSlot();
  let proceed!: () => void;
  const barrier = new Promise<void>(resolve => { proceed = resolve; });
  async function* slow() { yield Buffer.from('a'); await barrier; yield Buffer.from('bc'); }
  const pending = slot.upload(metadata, slow());
  await new Promise(resolve => setImmediate(resolve));
  slot.clear(); proceed();
  await assert.rejects(pending);
  assert.equal(slot.status()?.state, 'cancelled');
});

test('unaccepted bytes expire without an unbounded retention timer', async () => {
  let now = 0;
  const slot = new FileTransferSlot({ ttlMs: 100, now: () => now });
  try {
    const offer = await slot.upload(metadata, bytes(Buffer.from('abc')));
    now = 101;
    assert.throws(() => slot.download(offer.id));
    assert.equal(slot.status()?.state, 'expired');
  } finally { slot.clear(); }
});
