import { open } from 'node:fs/promises';
import { constants } from 'node:fs';
import { basename, extname, isAbsolute } from 'node:path';
import { fileMetadataSchema, MAX_FILE_BYTES } from './file-transfer.js';
import { validateHubUrl } from './hub-url.js';
import { validateToken } from './protocol.js';

const mimeTypes: Record<string, string> = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.heic': 'image/heic', '.pdf': 'application/pdf', '.txt': 'text/plain', '.mp4': 'video/mp4', '.mp3': 'audio/mpeg', '.zip': 'application/zip' };

/** Only the explicit file is opened; the hub never accepts a local filesystem path. */
export async function sendLocalFile(url: URL, token: string, path: string): Promise<unknown> {
  validateHubUrl(url); validateToken(token);
  if (typeof path !== 'string' || !isAbsolute(path) || path.length > 4096) throw new Error('Choose an absolute path to a local file.');
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0)).catch(() => { throw new Error('The selected file cannot be opened.'); });
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size < 1 || stat.size > MAX_FILE_BYTES) throw new Error('Choose a non-empty regular file up to 50 MiB.');
    const metadata = fileMetadataSchema.parse({ name: basename(path), size: stat.size, mimeType: mimeTypes[extname(path).toLowerCase()] ?? 'application/octet-stream' });
    const stream = file.createReadStream({ autoClose: false, start: 0, end: stat.size - 1 });
    try {
      const response = await fetch(new URL('/files', url), {
        method: 'POST', redirect: 'error', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream', 'Content-Length': String(stat.size), 'X-PhoneBridge-File': Buffer.from(JSON.stringify(metadata)).toString('base64url') },
        body: stream as unknown as BodyInit, duplex: 'half', signal: AbortSignal.timeout(60000),
      } as RequestInit);
      const text = await response.text();
      if (text.length > 8192) throw new Error('Invalid file transfer response.');
      const result = JSON.parse(text);
      if (!response.ok) throw new Error(result.error?.message ?? 'The phone could not accept the file offer.');
      return { ...result, message: 'Waiting for the phone owner to receive the file, then choose Share. No message has been sent.' };
    } finally { stream.destroy(); }
  } finally { await file.close(); }
}
