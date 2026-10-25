import { spawnSync } from 'node:child_process';
import { lstat, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { validateHubUrl } from './hub-url.js';

export type DesktopEndpointSource = () => Promise<URL | undefined>;
type Options = { configFile?: string; credentialFile?: string; stateDirectory?: string };
const privateIPv4 = (value: unknown): value is string => {
  if (typeof value !== 'string' || !/^\d+\.\d+\.\d+\.\d+$/.test(value)) return false;
  const pieces = value.split('.'), n = pieces.map(Number);
  return !pieces.some((piece, index) => String(n[index]) !== piece || n[index]! > 255) &&
    (n[0] === 10 || (n[0] === 172 && n[1]! >= 16 && n[1]! <= 31) || (n[0] === 192 && n[1] === 168));
};
const samePath = (a: string, b: string) => process.platform === 'win32' ? resolve(a).toLowerCase() === resolve(b).toLowerCase() : resolve(a) === resolve(b);

/** Follow only this user's installed desktop endpoint, never an arbitrary discovered service. */
export function desktopEndpointSource(initialUrl: URL, options: Options = {}): DesktopEndpointSource {
  const explicit = options.configFile ?? process.env.PHONEBRIDGE_DESKTOP_CONFIG;
  const credential = options.credentialFile ?? process.env.PHONEBRIDGE_CREDENTIAL_FILE;
  // Legacy v1 launchers supply the credential path but no desktop metadata. Do
  // not let standalone/loopback adapters or test fixtures attach to a real install.
  const implicit = !explicit && initialUrl.protocol === 'http:' && privateIPv4(initialUrl.hostname) && credential && isAbsolute(credential);
  const configFile = explicit || (implicit ? join(options.stateDirectory ?? join(homedir(), '.phonebridge'), process.platform === 'win32' ? 'desktop.json' : 'desktop-macos.json') : undefined);
  let previous = '', endpoint: URL | undefined;
  return async () => {
    if (!configFile || !isAbsolute(configFile)) return undefined;
    try {
      const info = await lstat(configFile);
      if (!info.isFile() || info.isSymbolicLink() || info.size > 32768) return undefined;
      const content = await readFile(configFile, 'utf8');
      const fingerprint = `${info.ino}:${info.ctimeMs}:${info.mode}:${info.uid}:${content}`;
      if (fingerprint === previous) return endpoint;
      const config = JSON.parse(content.replace(/^\uFEFF/, ''));
      if (process.platform === 'win32') {
        if (config.schema !== 'phonebridge-desktop-v1') return undefined;
        const script = "$ErrorActionPreference='Stop'; $p=[Console]::In.ReadToEnd(); $i=[Security.Principal.WindowsIdentity]::GetCurrent(); $f=Get-Item -LiteralPath $p; if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { exit 1 }; $o=[IO.File]::GetAccessControl($p).GetOwner([Security.Principal.SecurityIdentifier]).Value; if ($o -ne $i.User.Value -and $o -ne $i.Owner.Value) { exit 1 }; [Console]::Write($i.User.Value)";
        const result = spawnSync(join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoProfile', '-NonInteractive', '-Command', script], { input: configFile, encoding: 'utf8', windowsHide: true, timeout: 5000, maxBuffer: 32768 });
        if (result.error || result.status !== 0 || config.ownerSid !== result.stdout.trim()) return undefined;
      } else if (config.schema !== 'phonebridge-macos-desktop-v1' || config.ownerUid !== process.getuid?.() || info.uid !== process.getuid?.() || (info.mode & 0o077)) return undefined;
      if (!privateIPv4(config.hostAddress) || !Number.isInteger(config.port) || config.port < 1 || config.port > 65535) return undefined;
      const configuredCredential = config.credentialFile ?? join(dirname(configFile), 'pairing.json');
      if (typeof configuredCredential !== 'string' || !isAbsolute(configuredCredential) ||
          (credential && (!isAbsolute(credential) || !samePath(credential, configuredCredential)))) return undefined;
      const current = new URL(`http://${config.hostAddress}:${config.port}`);
      validateHubUrl(current);
      previous = fingerprint; endpoint = current;
      return current;
    } catch { return undefined; } // Retain the current endpoint when metadata is temporarily unavailable.
  };
}
