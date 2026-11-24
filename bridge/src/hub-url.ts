import { networkInterfaces } from 'node:os';
import { isIP } from 'node:net';

/** Managed pairing supports RFC 1918 LANs and RFC 6598 shared VPN addresses. */
export function privateIPv4Range(value: unknown): 'lan' | 'shared' | undefined {
  if (typeof value !== 'string' || isIP(value) !== 4) return;
  const [first, second] = value.split('.').map(Number);
  if (first === 10 || (first === 172 && second! >= 16 && second! <= 31) || (first === 192 && second === 168)) return 'lan';
  if (first === 100 && second! >= 64 && second! <= 127) return 'shared';
}

/** Cleartext is only allowed when the target is this computer, never a remote LAN host. */
export function validateHubUrl(url: URL, localAddresses = Object.values(networkInterfaces()).flatMap(list => list?.map(item => item.address) ?? [])): void {
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('PHONEBRIDGE_URL must be an HTTP(S) origin.');
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const local = ['127.0.0.1', '::1', 'localhost'].includes(host) || (isIP(host) !== 0 && localAddresses.includes(host));
  if (url.protocol === 'http:' && !local) throw new Error('Remote MCP-to-hub connections require HTTPS. Use loopback or an IP currently assigned to this computer.');
}
