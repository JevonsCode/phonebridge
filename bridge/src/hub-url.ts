import { networkInterfaces } from 'node:os';
import { isIP } from 'node:net';

/** Cleartext is only allowed when the target is this computer, never a remote LAN host. */
export function validateHubUrl(url: URL, localAddresses = Object.values(networkInterfaces()).flatMap(list => list?.map(item => item.address) ?? [])): void {
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('PHONEBRIDGE_URL must be an HTTP(S) origin.');
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const local = ['127.0.0.1', '::1', 'localhost'].includes(host) || (isIP(host) !== 0 && localAddresses.includes(host));
  if (url.protocol === 'http:' && !local) throw new Error('Remote MCP-to-hub connections require HTTPS. Use loopback or an IP currently assigned to this computer.');
}
