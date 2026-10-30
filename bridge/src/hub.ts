import http, { type IncomingMessage, type ServerResponse } from 'node:http';
import https from 'node:https';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';
import { z } from 'zod';
import { BridgeError, parseCommand, validateToken, type Method, type Reply } from './protocol.js';
import { FileOperationJournal, historyQuerySchema, journalErrorCode, operationParams, type OperationJournal, type OperationRecord } from './operation-journal.js';

import { FileTransferSlot, fileMetadataSchema } from './file-transfer.js';

type Options = { token: string; host?: string; port?: number; allowLan?: boolean; timeoutMs?: number; heartbeatIntervalMs?: number; tls?: { cert: Buffer; key: Buffer }; journal?: OperationJournal; publicEndpoint?: string };
export type Routing = { deviceId?: string; controlId?: string; connectionId?: string };
type DisconnectReason = 'SOCKET_CLOSED' | 'SOCKET_ABNORMAL_CLOSE' | 'SOCKET_ERROR' | 'HEARTBEAT_TIMEOUT' | 'COMMAND_TIMEOUT' | 'SEND_FAILED' | 'PROTOCOL_ERROR' | 'HUB_SHUTDOWN' | 'JOURNAL_UNAVAILABLE';
type Device = { id: string; name: string; protocol: number; capabilities: string[]; readOnly: boolean; controlling: boolean; controlOwnerName: string; waitingCount: number; connectionId: string; ws?: WebSocket; ready: boolean; alive: boolean; lastSeenAt: string; lastComputerEndpoint: string; lastDisconnectedAt?: string; lastDisconnectReason?: DisconnectReason; pending?: Pending; dispatching: boolean; managementPending: Map<string, Pending>; managementDispatching: number; controlEvents: Map<string, CachedControlEvent>; controlEventSequence: number; controlWaiters: Set<ControlWaiter>; eventTail: Promise<void>; eventWrites: number; files: FileTransferSlot };
type Pending = { id: string; resolve: (reply: Reply) => void; reject: (error: BridgeError) => void; timer: NodeJS.Timeout };
type ControlWaiter = { controlId: string; event: (event: ControlEvent) => void; reject: (error: BridgeError) => void };
const responseSchema = z.object({ id: z.string().max(100), result: z.record(z.unknown()).optional(), error: z.object({ code: z.string().max(100), message: z.string().max(500), details: z.record(z.unknown()).optional() }).strict().optional() }).strict().refine(r => (r.result !== undefined) !== (r.error !== undefined));
const helloSchema = z.object({ type: z.literal('hello'), protocol: z.literal(1), device: z.string().max(120).optional(), readOnly: z.boolean().optional() }).strict();
const hello2Schema = z.object({ type: z.literal('hello'), protocol: z.literal(2), deviceId: z.string().uuid(), device: z.string().min(1).max(120), readOnly: z.boolean(), capabilities: z.array(z.string().min(1).max(100)).max(100) }).strict();
const statusSchema = z.object({ type: z.literal('status'), readOnly: z.boolean(), controlling: z.boolean(), controlOwnerName: z.string().max(80), waitingCount: z.number().int().min(0).max(64).default(0) }).strict();
const controlStateFields = { state: z.enum(['queued', 'active', 'released', 'expired', 'cancelled']), position: z.number().int().min(1).max(64).optional(), ownerName: z.string().max(80).optional() } as const;
const controlEventSchema = z.object({ type: z.literal('control_event'), controlId: z.string().uuid(), ...controlStateFields }).strict();
type ControlEvent = z.infer<typeof controlEventSchema>;
type ControlState = Omit<ControlEvent, 'type' | 'controlId'> & { expiresInMs?: number };
type CachedControlEvent = { event: ControlEvent; sequence: number; recorded: Promise<void> };
const controlStatusSchema = z.object({ ...controlStateFields, state: z.enum(['active', 'queued']), controlId: z.string().uuid().optional(), expiresInMs: z.number().int().min(0).max(120000).optional() }).strict();
const controlWaitQuerySchema = z.object({ deviceId: z.string().min(1).max(100).regex(/^[A-Za-z0-9_-]+$/), connectionId: z.string().uuid(), controlId: z.string().uuid(), waitMs: z.number().int().min(0).max(25000).default(25000) }).strict();

export class PhoneHub {
  private server: http.Server | https.Server;
  private wss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024, perMessageDeflate: false });
  private devices = new Map<string, Device>();
  private heartbeat?: NodeJS.Timeout;
  private digest: Buffer;
  private journal: OperationJournal;
  private controlWaiterCount = 0;
  private disconnectReasons = new WeakMap<WebSocket, DisconnectReason>();
  constructor(private options: Options) {
    validateToken(options.token);
    this.journal = options.journal ?? new FileOperationJournal();
    this.digest = createHash('sha256').update(`Bearer ${options.token}`).digest();
    const host = options.host ?? '127.0.0.1';
    if (!['127.0.0.1', '::1', 'localhost'].includes(host) && !options.allowLan) throw new Error('Non-loopback bind requires --allow-lan. Prefer a trusted network or TLS.');
    this.server = options.tls ? https.createServer(options.tls, (q, s) => void this.handle(q, s)) : http.createServer((q, s) => void this.handle(q, s));
    this.server.requestTimeout = 60000;
    this.server.headersTimeout = 5000;
    this.wss.on('headers', headers => headers.push('X-PhoneBridge-Protocol: 2',
      `X-PhoneBridge-System: ${process.platform === 'darwin' ? 'macOS' : process.platform === 'win32' ? 'Windows' : process.platform === 'linux' ? 'Linux' : 'Other'}`));
    this.server.on('upgrade', (req, socket, head) => {
      if (req.url !== '/device' || req.headers.origin || !this.authorized(req)) {
        socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return;
      }
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
  private errorBody(error: BridgeError) {
    return { error: { code: error.code, message: error.message, ...(error.details ? { details: error.details } : {}) } };
  }
  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    if (req.headers.origin) { this.respond(res, 403, { error: { code: 'ORIGIN_REFUSED', message: 'Browser origins are not supported.' } }); return; }
    if (req.method === 'GET' && req.url === '/health') { this.respond(res, 200, { ok: true, protocol: 1 }); return; }
    if (!this.authorized(req)) { this.respond(res, 401, { error: { code: 'UNAUTHORIZED', message: 'Authentication required.' } }); return; }
    if (req.method === 'GET' && req.url === '/devices') { this.respond(res, 200, { devices: this.listDevices(), details: this.diagnostics() }); return; }
    if (req.method === 'GET' && req.url === '/status') {
      const online = [...this.devices.values()].filter(d => this.online(d));
      this.respond(res, 200, { connected: online.length > 0, busy: online.some(d => !!d.pending || d.dispatching), protocol: 1, transfer: online.length === 1 ? online[0]!.files.status() : undefined, devices: this.listDevices(), details: this.diagnostics() }); return;
    }
    let endpoint: URL;
    try { endpoint = new URL(req.url ?? '/', 'http://localhost'); }
    catch { req.resume(); this.respond(res, 400, { error: { code: 'INVALID_URL', message: 'Malformed request URL.' } }); return; }
    if (req.method === 'GET' && endpoint.pathname === '/control-events') {
      try { this.respond(res, 200, await this.waitForControl(req, res, endpoint)); }
      catch (error) {
        const e = error instanceof BridgeError ? error : new BridgeError('INTERNAL', 'Control wait failed.', 500);
        if (!res.headersSent && !res.destroyed) this.respond(res, e.status, this.errorBody(e));
      }
      return;
    }
    if (endpoint.pathname === '/files' || /^\/files\/[a-f0-9-]{36}(?:\/received)?$/.test(endpoint.pathname)) {
      let offeredId: string | undefined;
      let target: Device | undefined;
      try {
        if (req.method === 'POST' && endpoint.pathname === '/files') {
          const routing = this.fileRouting(endpoint);
          target = this.selectDevice(routing.deviceId, routing.connectionId);
          const phone = target.ws;
          const encoded = req.headers['x-phonebridge-file'];
          if (typeof encoded !== 'string' || encoded.length > 4096) throw new BridgeError('INVALID_FILE', 'Missing file metadata.');
          const metadata = fileMetadataSchema.safeParse(JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8')));
          if (!metadata.success || req.headers['content-type'] !== 'application/octet-stream' || Number(req.headers['content-length']) !== metadata.data.size) throw new BridgeError('INVALID_FILE', 'Invalid file metadata or size. Maximum 50 MiB.');
          const offer = await target.files.upload(metadata.data, req);
          offeredId = offer.id;
          if (!this.online(target) || target.ws !== phone) throw new BridgeError('DISCONNECTED', 'Phone disconnected during upload.', 503);
          const reply = await this.command('file_offer', offer, { ...routing, deviceId: target.id, connectionId: target.connectionId });
          if (reply.error) throw new BridgeError(reply.error.code, reply.error.message, 409, reply.error.details);
          this.respond(res, 201, { transfer: target.files.status(), ...(typeof reply.result?.autoReceiveEnabled === 'boolean' ? { autoReceiveEnabled: reply.result.autoReceiveEnabled } : {}), ...(typeof reply.result?.state === 'string' ? { phoneState: reply.result.state } : {}) });
        } else {
          const id = endpoint.pathname.split('/')[2]!;
          target = [...this.devices.values()].find(d => d.files.status()?.id === id);
          if (!target) throw new BridgeError('FILE_UNAVAILABLE', 'File is no longer available.', 404);
          if (req.method === 'GET' && !endpoint.pathname.endsWith('/received')) {
            const bytes = target.files.download(id);
            res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': bytes.length, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
            res.end(bytes);
          } else if (req.method === 'POST' && endpoint.pathname.endsWith('/received')) {
            target.files.finish(id, 'received'); req.resume(); this.respond(res, 200, { ok: true });
          } else if (req.method === 'DELETE' && !endpoint.pathname.endsWith('/received')) {
            target.files.finish(id, 'declined'); req.resume(); this.respond(res, 200, { ok: true });
          } else { req.resume(); this.respond(res, 404, { error: { code: 'NOT_FOUND', message: 'Unknown endpoint.' } }); }
        }
      } catch (error) {
        if (offeredId && target?.files.status()?.id === offeredId) target.files.clear('failed');
        req.resume();
        const e = error instanceof BridgeError ? error : new BridgeError('FILE_UNAVAILABLE', 'File unavailable, invalid, or another file is awaiting the phone.', 409);
        if (!res.headersSent && !res.destroyed) this.respond(res, e.status, this.errorBody(e));
      }
      return;
    }
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
        this.respond(res, e.status, this.errorBody(e));
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
      this.respond(res, 200, await this.command(command.method, command.params, command));
    } catch (error) {
      const e = error instanceof BridgeError ? error : new BridgeError('INTERNAL', 'Bridge request failed.', 500);
      if (!res.headersSent && !res.destroyed) this.respond(res, e.status, this.errorBody(e));
    }
  }
  private online(device: Device): boolean { return device.ready && device.ws?.readyState === WebSocket.OPEN; }
  private publicEndpoint(): string {
    const configured = this.options.publicEndpoint ?? process.env.PHONEBRIDGE_PUBLIC_ENDPOINT;
    if (configured) {
      try { const u = new URL(configured); if (['http:', 'https:'].includes(u.protocol) && !u.username && !u.password && !u.search && !u.hash) return u.origin; } catch { /* use the actual listener below */ }
    }
    const address = this.server.address();
    return address && typeof address !== 'string'
      ? `${this.options.tls ? 'https' : 'http'}://${address.family === 'IPv6' ? `[${address.address}]` : address.address}:${address.port}` : '';
  }
  private diagnostics(): Record<string, unknown> {
    const knownDevices = [...this.devices.values()].map(d => ({ id: d.id, name: d.name, connected: this.online(d), readOnly: d.readOnly, lastSeenAt: d.lastSeenAt, lastComputerEndpoint: d.lastComputerEndpoint, ...(d.lastDisconnectedAt ? { lastDisconnectedAt: d.lastDisconnectedAt, lastDisconnectReason: d.lastDisconnectReason } : {}) }));
    const connectionState = knownDevices.some(d => d.connected) ? 'connected' : knownDevices.length ? 'phone_offline' : 'no_phone_connected';
    return { publicEndpoint: this.publicEndpoint(), connectionState, knownDevices,
      nextSteps: connectionState === 'connected' ? ['Use phone_list_devices to select an online phone; readOnly is separate from connectivity.'] :
        ['The phone reconnects to its paired computer automatically on the same network.', 'Compare the computer endpoint above with the phone connection status. A changed address is rediscovered by updated clients; no new pairing is needed.', 'If the computer Hub is stopped, use the phone desktop-service start button.'] };
  }
  private unavailableDevice(message: string): BridgeError {
    return Object.assign(new BridgeError('NO_DEVICE', `${message} Current computer: ${this.publicEndpoint()}.`, 503), { details: this.diagnostics() });
  }
  private listDevices() {
    return [...this.devices.values()].map(d => ({ id: d.id, name: d.name, connected: this.online(d), busy: !!d.pending || d.dispatching || d.managementDispatching > 0, protocol: d.protocol, capabilities: [...d.capabilities], readOnly: d.readOnly, controlling: d.controlling, controlOwnerName: d.controlOwnerName, waitingCount: d.waitingCount, connectionId: d.connectionId, lastSeenAt: d.lastSeenAt, lastComputerEndpoint: d.lastComputerEndpoint, ...(d.lastDisconnectedAt ? { lastDisconnectedAt: d.lastDisconnectedAt, lastDisconnectReason: d.lastDisconnectReason } : {}), transfer: d.files.status() }));
  }
  private selectDevice(deviceId?: string, connectionId?: string): Device {
    if (deviceId !== undefined) {
      const device = this.devices.get(deviceId);
      if (!device || !this.online(device)) throw this.unavailableDevice('The selected phone is offline or unknown. Check phone_list_devices; do not pair again solely because it is offline.');
      if (connectionId !== undefined && device.connectionId !== connectionId) throw new BridgeError('CONTROL_EXPIRED', 'The selected phone connection has changed.', 409);
      return device;
    }
    const online = [...this.devices.values()].filter(d => this.online(d));
    if (online.length > 1) throw new BridgeError('DEVICE_REQUIRED', 'Choose a deviceId when more than one phone is connected.', 409);
    if (!online.length) throw this.unavailableDevice('No phone is connected. Saved pairing can be reused; check phone and computer network/service status.');
    if (connectionId !== undefined && online[0]!.connectionId !== connectionId) throw new BridgeError('CONTROL_EXPIRED', 'The selected phone connection has changed.', 409);
    return online[0]!;
  }
  private fileRouting(endpoint: URL): Routing {
    const raw: Record<string, string> = {};
    for (const [key, value] of endpoint.searchParams) {
      if (!['deviceId', 'controlId', 'connectionId'].includes(key) || Object.hasOwn(raw, key)) throw new BridgeError('INVALID_PARAMS', 'Invalid file routing.');
      raw[key] = value;
    }
    const parsed = z.object({ deviceId: z.string().min(1).max(120).optional(), controlId: z.string().uuid().optional(), connectionId: z.string().uuid().optional() }).safeParse(raw);
    if (!parsed.success) throw new BridgeError('INVALID_PARAMS', 'Invalid file routing.');
    return parsed.data;
  }
  private async waitForControl(req: IncomingMessage, res: ServerResponse, endpoint: URL): Promise<Record<string, unknown>> {
    const raw: Record<string, unknown> = Object.create(null);
    for (const [key, value] of endpoint.searchParams) {
      if (Object.hasOwn(raw, key) || (key === 'waitMs' && !/^\d+$/.test(value))) throw new BridgeError('INVALID_PARAMS', 'Invalid control wait parameters.');
      raw[key] = key === 'waitMs' ? Number(value) : value;
    }
    const parsed = controlWaitQuerySchema.safeParse(raw);
    if (!parsed.success) throw new BridgeError('INVALID_PARAMS', 'Invalid control wait parameters.');
    const { deviceId, connectionId, controlId, waitMs } = parsed.data;
    const device = this.selectDevice(deviceId, connectionId);
    if (device.protocol !== 2 || !device.capabilities.includes('control_queue')) throw new BridgeError('UNSUPPORTED', 'This phone does not support queued control notifications.', 409);
    if (this.controlWaiterCount >= 64) throw new BridgeError('WAIT_LIMIT', 'At most 64 control waits may be open.', 429);
    const startedAt = Date.now();
    const eventSequenceAtStart = device.controlEventSequence;
    const state = await new Promise<ControlState>((resolve, reject) => {
      let settled = false; let timer: NodeJS.Timeout | undefined; let initial: ControlState | undefined;
      const cleanup = () => {
        device.controlWaiters.delete(waiter); --this.controlWaiterCount; clearTimeout(timer);
        req.off('aborted', aborted); res.off('close', aborted);
      };
      const finish = (value: ControlState) => { if (!settled) { settled = true; cleanup(); resolve(value); } };
      const fail = (error: BridgeError) => { if (!settled) { settled = true; cleanup(); reject(error); } };
      const aborted = () => fail(new BridgeError('REQUEST_CANCELLED', 'The control wait was cancelled.', 499));
      const waiter: ControlWaiter = { controlId, reject: fail, event: event => {
        const { state, position, ownerName } = event;
        // A grant/terminal event must beat even a queued status reply already in flight.
        if (state !== 'queued' || (initial && (position !== initial.position || ownerName !== initial.ownerName))) finish({ state, ...(position !== undefined ? { position } : {}), ...(ownerName !== undefined ? { ownerName } : {}) });
      } };
      device.controlWaiters.add(waiter); ++this.controlWaiterCount;
      req.once('aborted', aborted); res.once('close', aborted);
      if (req.aborted || res.destroyed) { aborted(); return; }
      // Register first: the native may send a grant before its initial status reply.
      void this.command('control_status', { controlId }, { deviceId, connectionId }).then(reply => {
        if (settled) return;
        if (reply.error) { fail(new BridgeError(reply.error.code, reply.error.message, 409, reply.error.details)); return; }
        const status = controlStatusSchema.safeParse(reply.result);
        if (!status.success) { fail(new BridgeError('INVALID_RESPONSE', 'Invalid phone control status.', 502)); return; }
        if (status.data.controlId !== undefined && status.data.controlId !== controlId) { fail(new BridgeError('INVALID_RESPONSE', 'Phone returned a different control ID.', 502)); return; }
        const { controlId: _reportedId, ...next } = status.data;
        initial = next;
        const received = device.controlEvents.get(controlId);
        if (received && received.event.state !== 'queued' && (received.sequence > eventSequenceAtStart || initial.state === received.event.state)) {
          // A newer push can be waiting for disk while an older status reply finishes.
          const auditBudget = waitMs === 0 ? this.options.timeoutMs ?? 15000 : Math.max(1, waitMs - (Date.now() - startedAt));
          timer = setTimeout(() => fail(new BridgeError('LOG_WRITE_FAILED', 'The new control event is not yet durably recorded. Check control status before acting.', 503)), auditBudget);
          void received.recorded.then(() => { if (!settled && device.controlEvents.get(controlId)?.sequence === received.sequence) waiter.event(received.event); }).catch(() => fail(new BridgeError('LOG_WRITE_FAILED', 'The new control state could not be recorded.', 503)));
          return;
        }
        if (initial.state === 'active') { finish(initial); return; }
        const remaining = Math.max(0, waitMs - (Date.now() - startedAt));
        if (!remaining) finish(initial);
        else timer = setTimeout(() => finish(initial!), remaining);
      }).catch(error => fail(error instanceof BridgeError ? error : new BridgeError('INTERNAL', 'Control status failed.', 500)));
    });
    return { deviceId, connectionId, controlId, ...state };
  }
  private rejectControlWaiters(device: Device, error: BridgeError): void {
    for (const waiter of [...device.controlWaiters]) waiter.reject(error);
  }
  private receiveControlEvent(device: Device, ws: WebSocket, event: ControlEvent): void {
    const previous = device.controlEvents.get(event.controlId)?.event;
    if (previous && previous.state === event.state && previous.position === event.position && previous.ownerName === event.ownerName) return;
    if (device.eventWrites >= 128) throw new Error('Control event write limit');
    ++device.eventWrites;
    const recorded = device.eventTail.then(async () => {
      await this.journal.append({ version: 1, requestId: randomUUID(), time: new Date().toISOString(), method: ['queued', 'active'].includes(event.state) ? 'acquire_control' : 'release_control', params: {}, status: 'completed', outcome: 'device_reported_success', deviceId: device.id, connectionId: device.connectionId, controlId: event.controlId, recordKind: 'control_event', controlEvent: event.state });
    });
    const sequence = ++device.controlEventSequence;
    device.controlEvents.delete(event.controlId); device.controlEvents.set(event.controlId, { event, sequence, recorded });
    if (device.controlEvents.size > 128) {
      const waitingIds = new Set([...device.controlWaiters].map(waiter => waiter.controlId));
      const oldest = [...device.controlEvents.keys()].find(controlId => !waitingIds.has(controlId));
      if (oldest) device.controlEvents.delete(oldest);
    }
    device.eventTail = recorded.then(() => {
      if (device.ws !== ws || !device.ready) return;
      if (device.controlEvents.get(event.controlId)?.sequence !== sequence) return;
      for (const waiter of [...device.controlWaiters]) if (waiter.controlId === event.controlId) waiter.event(event);
    }).catch(() => {
      this.rejectControlWaiters(device, new BridgeError('LOG_WRITE_FAILED', 'A phone control event could not be recorded. Check current control before acting.', 503));
      this.recordDisconnect(device, ws, 'JOURNAL_UNAVAILABLE');
      ws.close(1011, 'Control event journal unavailable');
    }).finally(() => { --device.eventWrites; });
  }
  private recordDisconnect(device: Device, ws: WebSocket, reason: DisconnectReason): void {
    if (device.ws !== ws || this.disconnectReasons.has(ws)) return;
    this.disconnectReasons.set(ws, reason);
    device.lastDisconnectedAt = new Date().toISOString(); device.lastDisconnectReason = reason;
    device.ready = false;
  }
  private attach(ws: WebSocket): void {
    let device: Device | undefined;
    const helloTimeout = setTimeout(() => ws.close(1008, 'Protocol handshake required'), 5000);
    ws.on('pong', () => { if (device?.ws === ws) { device.alive = true; device.lastSeenAt = new Date().toISOString(); } });
    ws.on('error', () => { if (device) this.recordDisconnect(device, ws, 'SOCKET_ERROR'); ws.terminate(); });
    ws.on('message', (data, binary) => {
      try {
        if (binary) throw new Error('Binary frame');
        const value: unknown = JSON.parse(data.toString());
        if (!device) {
          const hello = z.union([helloSchema, hello2Schema]).parse(value);
          const id = hello.protocol === 2 ? hello.deviceId : 'legacy';
          const existing = this.devices.get(id);
          // Reconnecting cannot bypass an outstanding command's journal fence.
          if (existing && (existing.ws || existing.dispatching || existing.pending || existing.managementDispatching)) { ws.close(1008, 'Device already connected'); return; }
          device = { id, name: hello.device ?? 'Phone', protocol: hello.protocol, capabilities: hello.protocol === 2 ? hello.capabilities : [], readOnly: hello.readOnly ?? false, controlling: false, controlOwnerName: '', waitingCount: 0, connectionId: randomUUID(), ws, ready: true, alive: true, lastSeenAt: new Date().toISOString(), lastComputerEndpoint: this.publicEndpoint(),
            ...(existing?.lastDisconnectedAt ? { lastDisconnectedAt: existing.lastDisconnectedAt, lastDisconnectReason: existing.lastDisconnectReason } : {}),
            dispatching: false, managementPending: new Map(), managementDispatching: 0, controlEvents: new Map(), controlEventSequence: 0, controlWaiters: new Set(), eventTail: Promise.resolve(), eventWrites: 0, files: new FileTransferSlot() };
          this.devices.set(id, device); clearTimeout(helloTimeout); return;
        }
        if (device.ws !== ws || !device.ready) return;
        if (device.protocol === 2 && typeof value === 'object' && value !== null && 'type' in value && value.type === 'status') {
          const status = statusSchema.parse(value);
          device.lastSeenAt = new Date().toISOString();
          device.readOnly = status.readOnly; device.controlling = status.controlling; device.controlOwnerName = status.controlOwnerName; device.waitingCount = status.waitingCount;
          return;
        }
        if (device.protocol === 2 && device.capabilities.includes('control_queue') && typeof value === 'object' && value !== null && 'type' in value && value.type === 'control_event') {
          const event = controlEventSchema.parse(value); device.lastSeenAt = new Date().toISOString();
          this.receiveControlEvent(device, ws, event); return;
        }
        const reply = responseSchema.parse(value);
        device.lastSeenAt = new Date().toISOString();
        const management = device.managementPending.get(reply.id);
        if (management) { device.managementPending.delete(reply.id); clearTimeout(management.timer); management.resolve(reply); return; }
        if (reply.id !== device.pending?.id) return;
        const pending = device.pending!; device.pending = undefined; clearTimeout(pending.timer); pending.resolve(reply);
      } catch { if (device) this.recordDisconnect(device, ws, 'PROTOCOL_ERROR'); ws.close(1008, 'Invalid protocol message'); }
    });
    ws.on('close', code => {
      clearTimeout(helloTimeout);
      if (!device || device.ws !== ws) return;
      this.recordDisconnect(device, ws, code === 1006 ? 'SOCKET_ABNORMAL_CLOSE' : 'SOCKET_CLOSED');
      device.ws = undefined; device.ready = false; device.controlling = false; device.controlOwnerName = ''; device.waitingCount = 0; device.controlEvents.clear(); device.files.clear();
      this.rejectControlWaiters(device, new BridgeError('DISCONNECTED', 'The phone connection closed while waiting for control.', 503, this.diagnostics()));
      this.rejectPending(device, new BridgeError('DISCONNECTED', 'Phone disconnected. Action outcome may be unknown; observe before trying again.', 503, this.diagnostics()));
    });
  }
  private rejectPending(device: Device, error: BridgeError): void {
    const p = device.pending; device.pending = undefined;
    if (p) { clearTimeout(p.timer); p.reject(error); }
    for (const pending of device.managementPending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    device.managementPending.clear();
  }
  private rejectRequest(device: Device, id: string, error: BridgeError): void {
    if (device.pending?.id === id) {
      const pending = device.pending; device.pending = undefined; clearTimeout(pending.timer); pending.reject(error); return;
    }
    const pending = device.managementPending.get(id);
    if (pending) { device.managementPending.delete(id); clearTimeout(pending.timer); pending.reject(error); }
  }
  async command(method: Method, params: Record<string, unknown>, routing: Routing = {}): Promise<Reply> {
    const command = parseCommand({ method, params, ...(routing.deviceId !== undefined ? { deviceId: routing.deviceId } : {}), ...(routing.controlId !== undefined ? { controlId: routing.controlId } : {}), ...(routing.connectionId !== undefined ? { connectionId: routing.connectionId } : {}) });
    const startedAt = Date.now();
    const base: OperationRecord = { version: 1, requestId: randomUUID(), time: new Date(startedAt).toISOString(), method, params: operationParams(method, command.params), status: 'started', outcome: 'unknown', ...(routing.deviceId ? { deviceId: routing.deviceId } : {}), ...(routing.controlId ? { controlId: routing.controlId } : {}) };
    if (['acquire_control', 'release_control', 'control_status', 'renew_control'].includes(method) && typeof command.params.controlId === 'string') base.controlId = command.params.controlId;
    const notDispatched = async (error: BridgeError): Promise<never> => {
      try { await this.journal.append({ ...base, status: 'failed', outcome: 'not_dispatched', errorCode: error.code, durationMs: Date.now() - startedAt }); }
      catch { throw new BridgeError('LOG_UNAVAILABLE', `Command was not dispatched (${error.code}); its rejection could not be recorded.`, 503, error.details); }
      throw error;
    };
    let device: Device;
    try { device = this.selectDevice(routing.deviceId, routing.connectionId); }
    catch (error) { return notDispatched(error as BridgeError); }
    base.deviceId = device.id;
    const requiredCapability = method === 'control_status' || (method === 'acquire_control' && command.params.queue === true) ? 'control_queue' : method === 'acquire_control' || method === 'release_control' ? 'control_lease' : method === 'renew_control' ? 'control_renew' : method === 'get_clipboard' || method === 'set_clipboard' ? 'clipboard' : method === 'node_action' ? 'element_actions' : undefined;
    if (requiredCapability && !device.capabilities.includes(requiredCapability)) return notDispatched(new BridgeError('UNSUPPORTED', 'This phone does not support the requested capability.', 409));
    if (routing.controlId && (device.protocol < 2 || !device.capabilities.includes('control_lease'))) return notDispatched(new BridgeError('UNSUPPORTED', 'This phone does not support task control.', 409));
    const management = device.protocol === 2 && ['acquire_control', 'release_control', 'control_status', 'renew_control'].includes(method);
    if (management ? device.managementDispatching >= 64 : device.pending || device.dispatching) return notDispatched(new BridgeError('BUSY', management ? 'Too many phone control requests are in progress.' : 'One command is already in progress on this phone.', 409));
    const ws = device.ws!; const id = base.requestId;
    // Screen operations remain single-flight; bounded control management is independent.
    if (management) ++device.managementDispatching; else device.dispatching = true;
    const releaseDispatch = () => { if (management) --device.managementDispatching; else device.dispatching = false; };
    try { await this.journal.append(base); }
    catch { releaseDispatch(); throw new BridgeError('LOG_UNAVAILABLE', 'Command was not dispatched because the operation journal could not be written.', 503); }
    if (!this.online(device) || device.ws !== ws || ws.readyState !== WebSocket.OPEN) {
      try { return await notDispatched(this.unavailableDevice('Phone disconnected before dispatch.')); }
      finally { releaseDispatch(); }
    }
    const pendingReply = new Promise<Reply>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (device.pending?.id !== id && !device.managementPending.has(id)) return;
        this.recordDisconnect(device, ws, 'COMMAND_TIMEOUT');
        this.rejectRequest(device, id, new BridgeError('TIMEOUT', 'Device command timed out. Outcome unknown; reconnect and observe. No automatic retry.', 504, this.diagnostics()));
        ws.terminate();
      }, this.options.timeoutMs ?? 15000);
      const pending = { id, resolve, reject, timer };
      if (management) device.managementPending.set(id, pending); else device.pending = pending;
      ws.send(JSON.stringify({ id, method: command.method, params: command.params, ...(routing.controlId ? { controlId: routing.controlId } : {}) }), error => { if (error && (device.pending?.id === id || device.managementPending.has(id))) { this.recordDisconnect(device, ws, 'SEND_FAILED'); this.rejectRequest(device, id, new BridgeError('SEND_FAILED', 'Could not deliver command.', 503, this.diagnostics())); ws.terminate(); } });
    });
    let reply: Reply | undefined; let failure: BridgeError | undefined;
    try { reply = await pendingReply; }
    catch (error) { failure = error instanceof BridgeError ? error : new BridgeError('SEND_FAILED', 'Command outcome unknown.', 503); }
    const errorCode = failure?.code ?? reply?.error?.code;
    const deviceReportedError = Boolean(reply?.error);
    // Device timeout/gesture cancellation can occur after a partial mutation.
    const uncertain = !!failure || ['TIMEOUT', 'GESTURE_CANCELLED', 'WINDOW_CHANGED', 'CONTROL_EXPIRED'].includes(errorCode ?? '');
    try {
      await this.journal.append({ ...base, time: new Date().toISOString(), status: uncertain ? 'uncertain' : deviceReportedError ? 'failed' : 'completed', outcome: uncertain ? 'unknown' : deviceReportedError ? 'device_reported_error' : 'device_reported_success', durationMs: Date.now() - startedAt, ...(errorCode !== undefined ? { errorCode: journalErrorCode(errorCode) } : {}) });
    } catch {
      throw new BridgeError('LOG_WRITE_FAILED', 'Command may have executed, but its final journal record could not be saved. Observe the phone; do not automatically retry.', 503, failure?.details ?? reply?.error?.details);
    } finally { releaseDispatch(); }
    if (failure) throw failure;
    return reply!;
  }
  async start(): Promise<string> {
    await new Promise<void>((resolve, reject) => { this.server.once('error', reject); this.server.listen(this.options.port ?? 8765, this.options.host ?? '127.0.0.1', () => { this.server.off('error', reject); resolve(); }); });
    this.heartbeat = setInterval(() => {
      for (const device of this.devices.values()) {
        if (!this.online(device)) continue;
        if (!device.alive) { this.recordDisconnect(device, device.ws!, 'HEARTBEAT_TIMEOUT'); device.ws!.terminate(); continue; }
        device.alive = false; device.ws!.ping();
      }
    }, this.options.heartbeatIntervalMs ?? 20000);
    this.heartbeat.unref();
    const address = this.server.address();
    if (!address || typeof address === 'string') throw new Error('Missing listen address');
    return `${this.options.tls ? 'https' : 'http'}://${address.family === 'IPv6' ? `[${address.address}]` : address.address}:${address.port}`;
  }
  async close(): Promise<void> {
    clearInterval(this.heartbeat);
    for (const device of this.devices.values()) {
      if (device.ws) this.recordDisconnect(device, device.ws, 'HUB_SHUTDOWN');
      device.ready = false; device.files.clear();
      this.rejectControlWaiters(device, new BridgeError('SHUTDOWN', 'Hub stopped while waiting for control.', 503, this.diagnostics()));
      this.rejectPending(device, new BridgeError('SHUTDOWN', 'Hub stopped.', 503, this.diagnostics()));
    }
    for (const ws of this.wss.clients) ws.terminate();
    await new Promise<void>(resolve => this.wss.close(() => resolve()));
    await Promise.all([...this.devices.values()].map(device => device.eventTail));
    this.server.closeAllConnections();
    await new Promise<void>((resolve, reject) => this.server.close(e => e ? reject(e) : resolve()));
  }
}
