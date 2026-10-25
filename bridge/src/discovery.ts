import { createHmac, timingSafeEqual } from 'node:crypto';
import { createSocket, type Socket } from 'node:dgram';
import { isIP } from 'node:net';

export const discoveryPort = 8766;
const identityLabel = 'PhoneBridge discovery identity v1';

export function discoveryIdentity(token: string): string {
  return createHmac('sha256', token).update(identityLabel).digest('hex');
}

export function discoveryProof(token: string, identity: string, nonce: string, endpoint: string): string {
  return createHmac('sha256', token).update(`PhoneBridge discovery v1\n${identity}\n${nonce}\n${endpoint}`).digest('hex');
}

export function privateDiscoveryAddress(address: string): boolean {
  if (isIP(address) !== 4) return false;
  const parts = address.split('.').map(Number);
  return parts[0] === 10 || (parts[0] === 172 && parts[1]! >= 16 && parts[1]! <= 31) ||
    (parts[0] === 192 && parts[1] === 168);
}

type DiscoveryOptions = {
  token: string;
  // Supplied by the listening server, never from a request or a saved address.
  endpoint: () => string | undefined;
  port?: number;
  host?: string;
  allowLoopback?: boolean;
};

export function trustedDiscoveryResponse(token: string, request: unknown, endpoint: string | undefined, allowLoopback = false) {
  if (!request || typeof request !== 'object' || !endpoint) return;
  const value = request as { type?: unknown; version?: unknown; identity?: unknown; nonce?: unknown };
  const identity = discoveryIdentity(token);
  if (value.type !== 'phonebridge_discover' || value.version !== 1 ||
    typeof value.identity !== 'string' || !/^[a-f0-9]{64}$/.test(value.identity) ||
    typeof value.nonce !== 'string' || !/^[a-f0-9]{32}$/.test(value.nonce) ||
    !timingSafeEqual(Buffer.from(value.identity, 'hex'), Buffer.from(identity, 'hex'))) return;
  try {
    const parsed = new URL(endpoint);
    const explicitPort = /^wss?:\/\/[^/]+:([1-9][0-9]{0,4})\/device$/.exec(endpoint)?.[1];
    if (!['ws:', 'wss:'].includes(parsed.protocol) || parsed.pathname !== '/device' || !explicitPort || Number(explicitPort) > 65535 ||
      parsed.username || parsed.password || parsed.search || parsed.hash ||
      !(privateDiscoveryAddress(parsed.hostname) || (allowLoopback && parsed.hostname === '127.0.0.1'))) return;
  } catch { return; }
  return { type: 'phonebridge_found', version: 1, identity, nonce: value.nonce, endpoint,
    proof: discoveryProof(token, identity, value.nonce, endpoint) };
}

/** Only a paired identity receives a unicast, nonce-bound endpoint proof. */
export class TrustedDiscoveryResponder {
  private socket?: Socket;
  constructor(private readonly options: DiscoveryOptions) {
    const port = options.port ?? discoveryPort;
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid discovery port.');
  }

  get port(): number | undefined {
    const address = this.socket?.address();
    return address && typeof address !== 'string' ? address.port : undefined;
  }

  async start(): Promise<void> {
    if (this.socket) throw new Error('Discovery is already listening.');
    const socket = createSocket({ type: 'udp4', reuseAddr: true });
    this.socket = socket;
    socket.on('message', (bytes, remote) => {
      if (bytes.length > 1024 || !(privateDiscoveryAddress(remote.address) ||
        (this.options.allowLoopback && remote.address === '127.0.0.1'))) return;
      let request: unknown;
      try { request = JSON.parse(bytes.toString('utf8')); } catch { return; }
      const reply = trustedDiscoveryResponse(this.options.token, request, this.options.endpoint(), this.options.allowLoopback);
      if (reply) socket.send(Buffer.from(JSON.stringify(reply)), remote.port, remote.address, () => {});
    });
    try {
      await new Promise<void>((resolve, reject) => {
        socket.once('error', reject);
        socket.bind(this.options.port ?? discoveryPort, this.options.host ?? '0.0.0.0', () => {
          socket.off('error', reject);
          // UDP errors must never tear down an otherwise working paired service.
          socket.on('error', () => {});
          resolve();
        });
      });
    } catch (error) { await this.close(); throw error; }
  }

  async close(): Promise<void> {
    const socket = this.socket;
    this.socket = undefined;
    if (!socket) return;
    await new Promise<void>(resolve => { try { socket.close(() => resolve()); } catch { resolve(); } });
  }
}
