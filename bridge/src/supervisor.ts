import http, { type IncomingMessage, type ServerResponse } from 'node:http';
import https from 'node:https';
import net, { type Socket } from 'node:net';
import { fork, type ChildProcess } from 'node:child_process';
import { createHash, timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { validateToken } from './protocol.js';

type Options = {
  token: string; host?: string; port?: number; allowLan?: boolean;
  tls?: { cert: Buffer; key: Buffer }; autoStart?: boolean;
  restartDelayMs?: number; startupTimeoutMs?: number;
  logFile?: string;
};

/** The original public endpoint survives a Hub crash. No RPC is ever replayed. */
export class DesktopSupervisor {
  private readonly server: http.Server | https.Server;
  private readonly digest: Buffer;
  private child?: ChildProcess;
  private hubUrl?: URL;
  private starting?: Promise<void>;
  private retry?: NodeJS.Timeout;
  private stopping = false;
  private attempts = 0;
  private readonly streams = new Set<Socket>();

  constructor(private readonly options: Options) {
    validateToken(options.token);
    const host = options.host ?? '127.0.0.1';
    if (!['127.0.0.1', '::1', 'localhost'].includes(host) && !options.allowLan) {
      throw new Error('Non-loopback bind requires --allow-lan.');
    }
    const port = options.port ?? 8765;
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('Invalid port.');
    this.digest = createHash('sha256').update(`Bearer ${options.token}`).digest();
    this.server = options.tls
      ? https.createServer(options.tls, (req, res) => void this.handle(req, res))
      : http.createServer((req, res) => void this.handle(req, res));
    this.server.requestTimeout = 10000;
    this.server.headersTimeout = 5000;
    this.server.on('connection', socket => this.track(socket));
    this.server.on('upgrade', (req, socket, head) => this.upgrade(req, socket as Socket, head));
  }

  get managedProcessId(): number | undefined { return this.child?.pid; }
  get serviceRunning(): boolean { return !!this.hubUrl; }

  async start(): Promise<string> {
    await new Promise<void>((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.options.port ?? 8765, this.options.host ?? '127.0.0.1', () => {
        this.server.off('error', reject); resolve();
      });
    });
    const address = this.server.address();
    if (!address || typeof address === 'string') throw new Error('Missing listen address.');
    if (this.options.autoStart !== false) {
      // Leave management available even when the Hub cannot start yet.
      await this.ensureRunning().catch(() => undefined);
    }
    return `${this.options.tls ? 'https' : 'http'}://${address.family === 'IPv6' ? `[${address.address}]` : address.address}:${address.port}`;
  }

  private authorized(req: IncomingMessage): boolean {
    const value = req.headers.authorization;
    return typeof value === 'string' && value.length <= 300 &&
      timingSafeEqual(createHash('sha256').update(value).digest(), this.digest);
  }

  private respond(res: ServerResponse, status: number, data: unknown): void {
    if (res.destroyed || res.headersSent) return;
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    res.end(JSON.stringify(data));
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (req.headers.origin) { req.resume(); this.respond(res, 403, { error: { code: 'ORIGIN_REFUSED' } }); return; }
    if (req.method === 'GET' && req.url === '/health') { this.respond(res, 200, { ok: true, protocol: 1 }); return; }
    if (!this.authorized(req)) { req.resume(); this.respond(res, 401, { error: { code: 'UNAUTHORIZED' } }); return; }
    if (req.url === '/service/start') {
      if (req.method !== 'POST') { req.resume(); this.respond(res, 405, { error: { code: 'METHOD_NOT_ALLOWED' } }); return; }
      if (req.headers['transfer-encoding'] || (req.headers['content-length'] && req.headers['content-length'] !== '0')) {
        req.resume(); this.respond(res, 400, { error: { code: 'EMPTY_BODY_REQUIRED' } }); return;
      }
      try {
        await this.ensureRunning();
        this.respond(res, 200, { serviceRunning: true });
      } catch { this.respond(res, 503, { error: { code: 'START_FAILED' } }); }
      return;
    }
    let endpoint: URL;
    try { endpoint = new URL(req.url ?? '/', 'http://localhost'); }
    catch { req.resume(); this.respond(res, 400, { error: { code: 'INVALID_URL' } }); return; }
    if (!((req.method === 'GET' && (req.url === '/status' || endpoint.pathname === '/operations')) || (req.method === 'POST' && req.url === '/rpc'))) {
      req.resume(); this.respond(res, 404, { error: { code: 'NOT_FOUND' } }); return;
    }
    const target = this.hubUrl;
    if (!target) { req.resume(); this.respond(res, 503, { error: { code: 'SERVICE_UNAVAILABLE' } }); return; }
    const proxy = http.request({ hostname: target.hostname, port: target.port, path: req.url, method: req.method, headers: req.headers }, upstream => {
      res.writeHead(upstream.statusCode ?? 502, upstream.headers);
      upstream.on('error', () => res.destroy());
      upstream.pipe(res);
    });
    proxy.on('socket', socket => this.track(socket));
    proxy.on('error', () => {
      if (res.headersSent) res.destroy();
      else this.respond(res, 503, { error: { code: 'SERVICE_UNAVAILABLE' } });
    });
    req.on('aborted', () => proxy.destroy());
    res.on('close', () => proxy.destroy());
    req.pipe(proxy);
  }

  private track(socket: Socket): void {
    if (this.streams.has(socket)) return;
    this.streams.add(socket);
    socket.on('error', () => socket.destroy());
    socket.once('close', () => this.streams.delete(socket));
  }

  private upgrade(req: IncomingMessage, socket: Socket, head: Buffer): void {
    if (req.url !== '/device' || req.headers.origin || !this.authorized(req)) {
      socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return;
    }
    const target = this.hubUrl;
    if (!target) { socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n'); return; }
    const upstream = net.connect(Number(target.port), target.hostname);
    this.track(upstream);
    socket.once('close', () => upstream.destroy());
    upstream.once('close', () => socket.destroy());
    upstream.once('connect', () => {
      const headers: string[] = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
      for (let i = 0; i < req.rawHeaders.length; i += 2) headers.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
      upstream.write(headers.join('\r\n') + '\r\n\r\n');
      if (head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
  }

  ensureRunning(): Promise<void> {
    if (this.stopping) return Promise.reject(new Error('Supervisor is stopping.'));
    if (this.hubUrl) return Promise.resolve();
    if (this.starting) return this.starting;
    clearTimeout(this.retry); this.retry = undefined;
    const child = fork(fileURLToPath(new URL('./hub-worker.js', import.meta.url)), [], {
      env: { ...process.env, PHONEBRIDGE_TOKEN: this.options.token, ...(this.options.logFile ? { PHONEBRIDGE_LOG_FILE: this.options.logFile } : {}) },
      stdio: ['ignore', 'ignore', 'ignore', 'ipc'], windowsHide: true,
      // Do not inherit tsx loaders or debugging flags into the fixed production worker.
      execArgv: [],
    });
    this.child = child;
    let settled = false;
    let timer: NodeJS.Timeout;
    const startedAt = Date.now();
    this.starting = new Promise<void>((resolve, reject) => {
      const fail = () => {
        if (settled) return;
        settled = true; clearTimeout(timer); reject(new Error('Hub startup failed.'));
      };
      timer = setTimeout(() => { fail(); child.kill(); }, this.options.startupTimeoutMs ?? 10000);
      child.on('message', message => {
        if (settled || this.stopping || this.child !== child || !message || typeof message !== 'object') return;
        const value = message as { type?: unknown; url?: unknown };
        if (value.type !== 'ready' || typeof value.url !== 'string') return;
        try {
          const url = new URL(value.url);
          if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || url.pathname !== '/' || url.username || url.password || url.search || url.hash) throw new Error();
          this.hubUrl = url; settled = true; clearTimeout(timer); resolve();
        } catch { fail(); child.kill(); }
      });
      const recover = () => {
        fail();
        if (this.child !== child) return;
        this.child = undefined; this.hubUrl = undefined;
        if (Date.now() - startedAt >= 30000) this.attempts = 0;
        if (!this.stopping) {
          const wait = Math.min(30000, (this.options.restartDelayMs ?? 2000) * 2 ** Math.min(this.attempts++, 4));
          this.retry = setTimeout(() => { this.retry = undefined; void this.ensureRunning().catch(() => undefined); }, wait);
        }
      };
      child.once('error', recover);
      child.once('exit', recover);
    }).finally(() => { this.starting = undefined; });
    return this.starting;
  }

  async close(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    clearTimeout(this.retry);
    const child = this.child;
    if (child && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise<void>(resolve => child.once('exit', () => resolve()));
      child.kill();
      await exited;
    }
    await this.starting?.catch(() => undefined);
    for (const socket of this.streams) socket.destroy();
    this.server.closeAllConnections();
    await new Promise<void>((resolve, reject) => this.server.close(error => error ? reject(error) : resolve()));
  }
}
