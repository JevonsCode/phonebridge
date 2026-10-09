import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdir, lstat, readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { validateToken } from './protocol.js';

export const credentialPath = () => process.env.PHONEBRIDGE_CREDENTIAL_FILE ?? join(homedir(), '.phonebridge', 'pairing.json');

function dpapi(value: string, protect: boolean): string {
  const prefix = "$ErrorActionPreference='Stop'; [void][System.Reflection.Assembly]::LoadWithPartialName('System.Security'); $v=[Console]::In.ReadToEnd(); ";
  const code = prefix + (protect
    ? "[Convert]::ToBase64String([System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($v),$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser))"
    : "[Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($v),$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser))");
  const result = spawnSync('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', code], { input: value, encoding: 'utf8', windowsHide: true, timeout: 15000, maxBuffer: 32768 });
  if (result.error || result.status !== 0) throw new Error('Windows could not open the saved PhoneBridge credential for this user.');
  return result.stdout.trim();
}

export async function loadSavedToken(path = credentialPath()): Promise<string | undefined> {
  let info;
  try { info = await lstat(path); } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error; }
  if (!info.isFile() || info.isSymbolicLink() || info.size > 32768) throw new Error('Invalid PhoneBridge credential file.');
  if (process.platform !== 'win32' && ((info.mode & 0o077) !== 0 || info.uid !== process.getuid?.())) throw new Error('PhoneBridge credential must be owned by this user with mode 600.');
  try {
    const record = JSON.parse(await readFile(path, 'utf8'));
    if (record.version !== 1 || typeof record.data !== 'string') throw new Error();
    const token = process.platform === 'win32' && record.protection === 'windows-dpapi'
      ? dpapi(record.data, false)
      : process.platform !== 'win32' && record.protection === 'user-file' ? record.data : '';
    validateToken(token);
    return token;
  } catch { throw new Error('Saved PhoneBridge credential is unavailable or invalid. Restore it, or remove it and pair again.'); }
}

/** Opt-in persistent identity: never rotate an existing credential silently. */
export async function loadOrCreateSavedToken(path = credentialPath(), preferredToken?: string): Promise<string> {
  if (preferredToken !== undefined) validateToken(preferredToken);
  const previous = await loadSavedToken(path);
  if (previous) {
    if (preferredToken !== undefined && preferredToken !== previous) throw new Error('PHONEBRIDGE_TOKEN differs from the saved credential. Remove the saved credential explicitly before pairing a new identity.');
    return previous;
  }
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const parent = await lstat(dirname(path));
  if (!parent.isDirectory() || parent.isSymbolicLink() || (process.platform !== 'win32' && ((parent.mode & 0o077) !== 0 || parent.uid !== process.getuid?.()))) throw new Error('Use a private, user-owned directory for PhoneBridge credentials.');
  const token = preferredToken ?? randomBytes(32).toString('base64url');
  const record = { version: 1, protection: process.platform === 'win32' ? 'windows-dpapi' : 'user-file', data: process.platform === 'win32' ? dpapi(token, true) : token };
  try { await writeFile(path, JSON.stringify(record), { flag: 'wx', mode: 0o600 }); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
    const winner = await loadSavedToken(path);
    if (!winner || (preferredToken !== undefined && winner !== preferredToken)) throw new Error('Concurrent pairing identity conflict.');
    return winner;
  }
  return token;
}
