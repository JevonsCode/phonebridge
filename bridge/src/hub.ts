import http, { type IncomingMessage, type ServerResponse } from 'node:http';
import https from 'node:https';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { z } from 'zod';
import { BridgeError, parseCommand, validateToken, type Method, type Reply } from './protocol.js';
import { FileOperationJournal, historyQuerySchema, journalErrorCode, operationParams, type OperationJournal, type OperationRecord } from './operation-journal.js';

type Options = { token: string; host?: string; port?: number; allowLan?: boolean; timeoutMs?: number; tls?: { cert: Buffer; key: Buffer }; journal?: OperationJournal };
type Pending = { id: string; resolve: (reply: Reply) => void; reject: (error: BridgeError) => void; timer: NodeJS.Timeout };
const responseSchema = z.object({ id: z.string().max(100), result: z.record(z.unknown()).optional(), error: z.object({ code: z.string().max(100), message: z.string().max(500) }).strict().optional() }).strict().refine(r => (r.result !== undefined) !== (r.error !== undefined));
const helloSchema = z.object({ type: z.literal('hello'), protocol: z.literal(1), device: z.string().max(120).optional(), readOnly: z.boolean().optional() }).strict();

export class PhoneHub {
  private server: http.Server | https.Server;
  private wss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024, perMessageDeflate: false });
  private phone?: WebSocket;
  private ready = false;
  private pending?: Pending;
  private heartbeat?: NodeJS.Timeout;
  private alive = true;
  private digest: Buffer;
  private journal: OperationJournal;
  private dispatching = false;
  constructor(private options: Options) {
    validateToken(options.token);
    this.journal = options.journal ?? new FileOperationJournal();
    this.digest = createHash('sha256').update(`Bearer ${options.token}`).digest();
    const host = options.host ?? '127.0.0.1';
    if (!['127.0.0.1', '::1', 'localhost'].includes(host) && !options.allowLan) throw new Error('Non-loopback bind requires --allow-lan. Prefer a trusted network or TLS.');
    this.server = options.tls ? https.createServer(options.tls, (q, s) => void this.handle(q, s)) : http.createServer((q, s) => void this.handle(q, s));
    this.server.requestTimeout = 10000;
    this.server.headersTimeout = 5000;
    this.server.on('upgrade', (req, socket, head) => {
      if (req.url !== '/device' || req.headers.origin || !this.authorized(req)) {
        socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return;
      }
      if (this.phone) { socket.end('HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n'); return; }
      this.wss.handleUpgrade(req, socket, head, ws => this.attach(ws));
    });
  }
  private authorized(req: IncomingMessage): boolean {
    const header = req.headers.authorization;
    if (typeof header !== 'string' || header.length > 300) return false;
    return timingSafeEqual(createHash('sha256').update(header).digest(), this.digest);
  }
  private respond(res: ServerResponse, status: number, data: unknown): void {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    res.end(JSON.stringify(data));
  }
  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (req.headers.origin) { this.respond(res, 403, { error: { code: 'ORIGIN_REFUSED', message: 'Browser origins are not supported.' } }); return; }
    if (req.method === 'GET' && req.url === '/health') { this.respond(res, 200, { ok: true, protocol: 1 }); return; }
    if (!this.authorized(req)) { this.respond(res, 401, { error: { code: 'UNAUTHORIZED', message: 'Authentication required.' } }); return; }
    if (req.method === 'GET' && req.url === '/status') { this.respond(res, 200, { connected: this.ready, busy: !!this.pending || this.dispatching, protocol: 1 }); return; }
    let endpoint: URL;
    try { endpoint = new URL(req.url ?? '/', 'http://localhost'); }
    catch { req.resume(); this.respond(res, 400, { error: { code: 'INVALID_URL', message: 'Malformed request URL.' } }); return; }
    if (req.method === 'GET' && endpoint.pathname === '/operations') {
      try {
        const raw: Record<string, unknown> = Object.create(null);
        for (const [key, value] of endpoint.searchParams) {
          if (Object.hasOwn(raw, key)) throw new BridgeError('INVALID_PARAMS', 'Duplicate history parameter.');
          raw[key] = key === 'limit' ? Number(value) : value;
        }
        const query = historyQuerySchema.safeParse(raw);
        if (!query.success) throw new BridgeError('INVALID_PARAMS', 'Invalid operation history filter.');
        this.respond(res, 200, await this.journal.read(query.data));
      } catch (error) {
        const e = error instanceof BridgeError ? error : new BridgeError('LOG_UNAVAILABLE', 'Operation history could not be read.', 503);
        this.respond(res, e.status, { error: { code: e.code, message: e.message } });
      }
      return;
    }
    if (req.method !== 'POST' || req.url !== '/rpc') { this.respond(res, 404, { error: { code: 'NOT_FOUND', message: 'Unknown endpoint.' } }); return; }
    try {
      if (!req.headers['content-type']?.startsWith('application/json')) throw new BridgeError('CONTENT_TYPE', 'Use application/json.', 415);
      let size = 0; const chunks: Buffer[] = [];
      for await (const chunk of req) {
        const bytes = Buffer.from(chunk); size += bytes.length;
        if (size > 32768) throw new BridgeError('TOO_LARGE', 'Request exceeds 32 KiB.', 413);
        chunks.push(bytes);
      }
      let value: unknown;
      try { value = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new BridgeError('INVALID_JSON', 'Malformed JSON.'); }
      const command = parseCommand(value);
      this.respond(res, 200, await this.command(command.method, command.params));
    } catch (error) {
      const e = error instanceof BridgeError ? error : new BridgeError('INTERNAL', 'Bridge request failed.', 500);
      if (!res.headersSent && !res.destroyed) this.respond(res, e.status, { error: { code: e.code, message: e.message } });
    }
  }
  private attach(ws: WebSocket): void {
    this.phone = ws; this.ready = false; this.alive = true;
    const helloTimeout = setTimeout(() => ws.close(1008, 'Protocol handshake required'), 5000);
    ws.on('pong', () => { this.alive = true; });
    ws.on('error', () => ws.terminate());
    ws.on('message', (data, binary) => {
      if (this.phone !== ws) return;
      try {
        if (binary) throw new Error('Binary frame');
        const value: unknown = JSON.parse(data.toString());
        if (!this.ready) {
          helloSchema.parse(value); clearTimeout(helloTimeout); this.ready = true; return;
        }
        const reply = responseSchema.parse(value);
        if (reply.id !== this.pending?.id) return;
        const pending = this.pending!; this.pending = undefined; clearTimeout(pending.timer); pending.resolve(reply);
      } catch { ws.close(1008, 'Invalid protocol message'); }
    });
    ws.on('close', () => {
      clearTimeout(helloTimeout);
      if (this.phone !== ws) return;
      this.phone = undefined; this.ready = false;
      this.rejectPending(new BridgeError('DISCONNECTED', 'Phone disconnected. Action outcome may be unknown; observe before trying again.', 503));
    });
  }
  private rejectPending(error: BridgeError): void {
    const p = this.pending; this.pending = undefined;
    if (p) { clearTimeout(p.timer); p.reject(error); }
  }
  async command(method: Method, params: Record<string, unknown>): Promise<Reply> {
    const command = parseCommand({ method, params });
    const startedAt = Date.now();
    const base: OperationRecord = { version: 1, requestId: randomUUID(), time: new Date(startedAt).toISOString(), method, params: operationParams(method, command.params), status: 'started', outcome: 'unknown' };
    const notDispatched = async (error: BridgeError): Promise<never> => {
      try { await this.journal.append({ ...base, status: 'failed', outcome: 'not_dispatched', errorCode: error.code, durationMs: Date.now() - startedAt }); }
      catch { throw new BridgeError('LOG_UNAVAILABLE', `Command was not dispatched (${error.code}); its rejection could not be recorded.`, 503); }
      throw error;
    };
    if (!this.ready || this.phone?.readyState !== WebSocket.OPEN) return notDispatched(new BridgeError('NO_DEVICE', 'Connect and authorize the phone first.', 503));
    if (this.pending || this.dispatching) return notDispatched(new BridgeError('BUSY', 'One command is already in progress.', 409));
    const ws = this.phone; const id = base.requestId;
    // Reserve single-flight before awaiting disk. No other action can slip through.
    this.dispatching = true;
    try { await this.journal.append(base); }
    catch { this.dispatching = false; throw new BridgeError('LOG_UNAVAILABLE', 'Command was not dispatched because the operation journal could not be written.', 503); }
    if (!this.ready || this.phone !== ws || ws.readyState !== WebSocket.OPEN) {
      try { return await notDispatched(new BridgeError('NO_DEVICE', 'Phone disconnected before dispatch.', 503)); }
      finally { this.dispatching = false; }
    }
    const pendingReply = new Promise<Reply>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.rejectPending(new BridgeError('TIMEOUT', 'Device command timed out. Outcome unknown; reconnect and observe. No automatic retry.', 504));
        this.ready = false; ws.terminate();
      }, this.options.timeoutMs ?? 15000);
      this.pending = { id, resolve, reject, timer };
      ws.send(JSON.stringify({ id, ...command }), error => { if (error) { this.rejectPending(new BridgeError('SEND_FAILED', 'Could not deliver command.', 503)); ws.terminate(); } });
    });
    let reply: Reply | undefined; let failure: BridgeError | undefined;
    try { reply = await pendingReply; }
    catch (error) { failure = error instanceof BridgeError ? error : new BridgeError('SEND_FAILED', 'Command outcome unknown.', 503); }
    const errorCode = failure?.code ?? reply?.error?.code;
    const deviceReportedError = Boolean(reply?.error);
    // Device timeout/gesture cancellation can occur after a partial mutation.
    const uncertain = !!failure || ['TIMEOUT', 'GESTURE_CANCELLED', 'WINDOW_CHANGED'].includes(errorCode ?? '');
    try {
      await this.journal.append({ ...base, time: new Date().toISOString(), status: uncertain ? 'uncertain' : deviceReportedError ? 'failed' : 'completed', outcome: uncertain ? 'unknown' : deviceReportedError ? 'device_reported_error' : 'device_reported_success', durationMs: Date.now() - startedAt, ...(errorCode !== undefined ? { errorCode: journalErrorCode(errorCode) } : {}) });
    } catch {
      throw new BridgeError('LOG_WRITE_FAILED', 'Command may have executed, but its final journal record could not be saved. Observe the phone; do not automatically retry.', 503);
    } finally { this.dispatching = false; }
    if (failure) throw failure;
    return reply!;
  }
  async start(): Promise<string> {
    await new Promise<void>((resolve, reject) => { this.server.once('error', reject); this.server.listen(this.options.port ?? 8765, this.options.host ?? '127.0.0.1', () => { this.server.off('error', reject); resolve(); }); });
    this.heartbeat = setInterval(() => {
      if (!this.phone) return;
      if (!this.alive) { this.phone.terminate(); return; }
      this.alive = false; this.phone.ping();
    }, 20000);
    this.heartbeat.unref();
    const address = this.server.address();
    if (!address || typeof address === 'string') throw new Error('Missing listen address');
    return `${this.options.tls ? 'https' : 'http'}://${address.family === 'IPv6' ? `[${address.address}]` : address.address}:${address.port}`;
  }
  async close(): Promise<void> {
    clearInterval(this.heartbeat); this.ready = false;
    this.rejectPending(new BridgeError('SHUTDOWN', 'Hub stopped.', 503));
    for (const ws of this.wss.clients) ws.terminate();
    await new Promise<void>(resolve => this.wss.close(() => resolve()));
    this.server.closeAllConnections();
    await new Promise<void>((resolve, reject) => this.server.close(e => e ? reject(e) : resolve()));
  }
}
