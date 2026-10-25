import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';

export const MAX_FILE_BYTES = 50 * 1024 * 1024;
export const fileMetadataSchema = z.object({
  name: z.string().min(1).max(180).refine(name => !/[\\/\x00-\x1f\x7f]/.test(name) && !['.', '..'].includes(name)),
  mimeType: z.string().max(100).regex(/^[a-z0-9][a-z0-9.+-]*\/[a-z0-9][a-z0-9.+-]*$/),
  size: z.number().int().min(1).max(MAX_FILE_BYTES),
}).strict();
export const fileOfferSchema = fileMetadataSchema.extend({ id: z.string().uuid(), sha256: z.string().regex(/^[0-9a-f]{64}$/), expiresAt: z.number().int().min(0).optional() });
export type FileOffer = z.infer<typeof fileOfferSchema>;
type TransferState = 'uploading' | 'pending' | 'receiving' | 'received' | 'declined' | 'expired' | 'cancelled' | 'failed';
type Status = { id: string; name: string; size: number; state: TransferState; expiresAt?: number };

/** A single in-memory handoff: bounded size, lifetime and concurrency; no path is ever accepted. */
export class FileTransferSlot {
  private bytes?: Buffer;
  private current?: Status;
  private revision = 0;
  private expires = 0;
  private timer?: NodeJS.Timeout;
  private readonly now: () => number;
  private readonly maxBytes: number;
  private readonly ttlMs: number;
  constructor(options: { maxBytes?: number; ttlMs?: number; now?: () => number } = {}) {
    this.now = options.now ?? Date.now;
    this.maxBytes = options.maxBytes ?? MAX_FILE_BYTES;
    this.ttlMs = options.ttlMs ?? 10 * 60 * 1000;
  }
  private expire(): void {
    if (this.expires && this.now() >= this.expires && this.bytes) this.clear('expired');
  }
  status(): Status | undefined {
    this.expire();
    return this.current ? { ...this.current, ...(this.expires && ['pending', 'receiving'].includes(this.current.state) ? { expiresAt: this.expires } : {}) } : undefined;
  }
  async upload(raw: unknown, source: AsyncIterable<Uint8Array>): Promise<FileOffer> {
    const metadata = fileMetadataSchema.parse(raw);
    if (metadata.size > this.maxBytes) throw new Error('File exceeds the size limit.');
    this.expire();
    if (this.current && ['uploading', 'pending', 'receiving'].includes(this.current.state)) throw new Error('A file is already awaiting the phone.');
    const revision = ++this.revision;
    const id = randomUUID();
    this.current = { id, name: metadata.name, size: metadata.size, state: 'uploading' };
    let size = 0;
    const chunks: Buffer[] = [];
    const hash = createHash('sha256');
    try {
      for await (const chunk of source) {
        if (revision !== this.revision) throw new Error('The file transfer was cancelled.');
        size += chunk.length;
        if (size > metadata.size || size > this.maxBytes) throw new Error('File exceeds its declared size.');
        const copy = Buffer.from(chunk); chunks.push(copy); hash.update(copy);
      }
      if (revision !== this.revision) throw new Error('The file transfer was cancelled.');
      if (size !== metadata.size) throw new Error('File size changed during transfer.');
      this.bytes = Buffer.concat(chunks, size);
      this.current.state = 'pending';
      this.expires = this.now() + this.ttlMs;
      this.timer = setTimeout(() => this.clear('expired'), this.ttlMs); this.timer.unref();
      return { ...metadata, id, sha256: hash.digest('hex'), expiresAt: this.expires };
    } catch (error) {
      if (revision === this.revision) this.clear('failed');
      throw error;
    }
  }
  download(id: string): Buffer {
    this.expire();
    if (!this.bytes || this.current?.id !== id || !['pending', 'receiving'].includes(this.current.state)) throw new Error('File is no longer available.');
    this.current.state = 'receiving';
    return this.bytes;
  }
  finish(id: string, state: 'received' | 'declined'): void {
    this.expire();
    if (this.current?.id === id && this.current.state === state) return;
    if (this.current?.id !== id || !['pending', 'receiving'].includes(this.current.state)) throw new Error('File is no longer available.');
    if (state === 'received' && this.current.state !== 'receiving') throw new Error('File has not been downloaded.');
    this.clear(state);
  }
  clear(state: TransferState = 'cancelled'): void {
    ++this.revision;
    clearTimeout(this.timer); this.timer = undefined;
    this.bytes = undefined; this.expires = 0;
    if (this.current && ['uploading', 'pending', 'receiving'].includes(this.current.state)) this.current = { ...this.current, state };
  }
}
