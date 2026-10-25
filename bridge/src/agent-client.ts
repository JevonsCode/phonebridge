import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { validateHubUrl } from './hub-url.js';
import { BridgeError, type Method } from './protocol.js';
import { sendLocalFile } from './send-file.js';
import { desktopEndpointSource, type DesktopEndpointSource } from './desktop-endpoint.js';

export const targetShape = {
  deviceId: z.string().min(1).max(100).optional(),
  taskHandle: z.string().uuid().optional(),
};
export type Target = { deviceId?: string; taskHandle?: string; connectionId?: string };
export type Routing = { deviceId?: string; controlId?: string; connectionId?: string };
export class AgentError extends Error {
  constructor(readonly code: string, message: string, readonly outcome = 'not_dispatched', readonly details?: Record<string, unknown>) { super(message); }
}
const deviceSchema = z.object({
  id: z.string(), name: z.string().optional(), connected: z.boolean(),
  connectionId: z.string().optional(), protocol: z.number().optional(),
  capabilities: z.array(z.string()).default([]),
}).passthrough();
export type AgentDevice = z.infer<typeof deviceSchema>;
type Task = { deviceId: string; controlId: string; connectionId: string; state: 'active' | 'queued' };
const terminalErrors = new Set(['CONTROL_EXPIRED', 'NO_DEVICE', 'DISCONNECTED', 'SHUTDOWN', 'SERVICE_UNAVAILABLE']);
const uncertainErrors = new Set(['TIMEOUT', 'DISCONNECTED', 'SEND_FAILED', 'LOG_WRITE_FAILED', 'GESTURE_CANCELLED', 'WINDOW_CHANGED', 'CONTROL_EXPIRED']);

/** Handles select one live phone connection. They never follow the UI or reconnect silently. */
export class AgentClient {
  private readonly tasks = new Map<string, Task>();
  private closing?: Promise<void>;
  private closingRequested = false;
  private readonly acquisitions = new Set<Promise<Record<string, unknown>>>();
  private deviceDetails?: Record<string, unknown>;
  constructor(readonly url: URL, private readonly token: string, private readonly endpointSource: DesktopEndpointSource = desktopEndpointSource(url)) {}
  get connectionDetails(): Record<string, unknown> | undefined { return this.deviceDetails; }

  private async refreshEndpoint(): Promise<void> {
    const current = await this.endpointSource();
    if (current) { validateHubUrl(current); this.url.href = current.href; }
  }

  async request(path: string, body?: unknown, timeoutMs = 18000): Promise<Record<string, any>> {
    await this.refreshEndpoint();
    validateHubUrl(this.url);
    const response = await fetch(new URL(path, this.url), {
      method: body === undefined ? 'GET' : 'POST', redirect: 'error',
      headers: { Authorization: `Bearer ${this.token}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(Math.max(1, timeoutMs)),
    });
    const reader = response.body?.getReader();
    if (!reader) throw new AgentError('INVALID_RESPONSE', 'The computer service returned an empty response.', 'unknown');
    const chunks: Uint8Array[] = []; let size = 0;
    try {
      while (true) {
        const next = await reader.read(); if (next.done) break;
        size += next.value.length;
        if (size > 4 * 1024 * 1024) throw new AgentError('INVALID_RESPONSE', 'The computer service response was too large.', 'unknown');
        chunks.push(next.value);
      }
    } finally { await reader.cancel(); }
    const reply = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!reply || typeof reply !== 'object' || Array.isArray(reply)) throw new AgentError('INVALID_RESPONSE', 'Invalid service response.', 'unknown');
    if (!response.ok || reply.error) {
      const code = typeof reply.error?.code === 'string' ? reply.error.code : 'HTTP_ERROR';
      const uncertain = uncertainErrors.has(code);
      throw new AgentError(code, typeof reply.error?.message === 'string' ? reply.error.message : `Computer service returned ${response.status}.`, uncertain ? 'unknown' : response.ok ? 'device_reported_error' : 'not_dispatched',
        reply.error?.details && typeof reply.error.details === 'object' && !Array.isArray(reply.error.details) ? reply.error.details : undefined);
    }
    return reply;
  }

  async devices(timeoutMs?: number): Promise<AgentDevice[]> {
    const reply = await this.request('/devices', undefined, timeoutMs);
    const devices = z.array(deviceSchema).parse(reply.devices);
    this.deviceDetails = { ...(reply.details && typeof reply.details === 'object' && !Array.isArray(reply.details) ? reply.details : {}),
      knownDevices: Array.isArray(reply.details?.knownDevices) ? reply.details.knownDevices : devices };
    return devices;
  }

  acquire(deviceId?: string): Promise<Record<string, unknown>> {
    if (this.closingRequested) return Promise.reject(new AgentError('CLIENT_CLOSED', 'The AI connection is closing.'));
    const operation = this.acquireTask(deviceId);
    this.acquisitions.add(operation);
    void operation.then(() => this.acquisitions.delete(operation), () => this.acquisitions.delete(operation));
    return operation;
  }

  private async acquireTask(deviceId?: string): Promise<Record<string, unknown>> {
    const devices = (await this.devices()).filter(d => d.connected);
    if (this.closingRequested) throw new AgentError('CLIENT_CLOSED', 'The AI connection is closing.');
    const device = deviceId ? devices.find(d => d.id === deviceId) : devices.length === 1 ? devices[0] : undefined;
    if (!device) throw new AgentError(deviceId || !devices.length ? 'NO_DEVICE' : 'DEVICE_REQUIRED', deviceId ? 'The selected phone is offline or unknown.' : 'Select a phone from phone_list_devices.', 'not_dispatched', this.deviceDetails);
    if (!device.capabilities.includes('control_lease') || !device.connectionId) throw new AgentError('UNSUPPORTED', 'Upgrade the phone and computer service to use task control.');
    const controlId = randomUUID();
    const result = await this.request('/rpc', { method: 'acquire_control', params: { controlId, ...(device.capabilities.includes('control_queue') ? { queue: true } : {}) }, deviceId: device.id, connectionId: device.connectionId });
    const state = z.enum(['active', 'queued']).parse(result.result?.state ?? 'active');
    const taskHandle = randomUUID();
    this.tasks.set(taskHandle, { deviceId: device.id, controlId, connectionId: device.connectionId, state });
    if (this.closingRequested) {
      await this.release(taskHandle, 2000).catch(() => undefined);
      throw new AgentError('CLIENT_CLOSED', 'The AI connection closed during acquisition; its task was cancelled where reachable.');
    }
    return { ...(result.result ?? {}), taskHandle, deviceId: device.id, state, idleTimeoutMs: 60000, instruction: state === 'queued'
      ? 'Another AI is using this phone. Call phone_wait_for_control with this taskHandle; do not operate until state is active. Release to cancel waiting.'
      : 'Reuse this taskHandle for the entire workflow, including clipboard/files. Do not acquire again for each command: control changes invalidate old node/screenshot IDs. Renew explicitly before a planned idle interval reaches 60 seconds. Release in finally when done. Expired handles require a new acquire and fresh observation.' };
  }

  async resolve(target: Target, timeoutMs?: number, allowQueued = false): Promise<Routing> {
    if (!target.taskHandle) return { ...(target.deviceId ? { deviceId: target.deviceId } : {}), ...(target.connectionId ? { connectionId: target.connectionId } : {}) };
    const task = this.tasks.get(target.taskHandle);
    if (!task) throw new AgentError('CONTROL_EXPIRED', 'This task handle is unknown or expired. Acquire control again and observe.');
    if (task.state === 'queued' && !allowQueued) throw new AgentError('CONTROL_QUEUED', 'This task is waiting for the phone. Call phone_wait_for_control before observing or acting.');
    if (target.deviceId && target.deviceId !== task.deviceId) throw new AgentError('TARGET_MISMATCH', 'taskHandle is bound to a different phone.');
    const device = (await this.devices(timeoutMs)).find(d => d.id === task.deviceId);
    if (!device?.connected || device.connectionId !== task.connectionId) {
      this.tasks.delete(target.taskHandle);
      throw new AgentError('CONTROL_EXPIRED', 'The phone connection changed. Acquire control again and observe; do not replay actions.', 'not_dispatched', this.deviceDetails);
    }
    return { deviceId: task.deviceId, controlId: task.controlId, connectionId: task.connectionId };
  }

  async command(method: Method, params: Record<string, unknown>, target: Target = {}, timeoutMs?: number): Promise<Record<string, any>> {
    const started = Date.now();
    const routing = await this.resolve(target, timeoutMs);
    try {
      const reply = await this.request('/rpc', { method, params, ...routing }, timeoutMs === undefined ? undefined : Math.max(1, timeoutMs - (Date.now() - started)));
      if (!reply.result || typeof reply.result !== 'object' || Array.isArray(reply.result)) throw new AgentError('INVALID_RESPONSE', 'Invalid phone result.', 'unknown');
      return reply.result;
    } catch (error) {
      if (target.taskHandle && error instanceof AgentError && terminalErrors.has(error.code)) this.tasks.delete(target.taskHandle);
      throw error;
    }
  }

  async release(taskHandle: string, timeoutMs = 18000): Promise<Record<string, unknown>> {
    // Resolve checks connection identity before sending; even a failed release cannot revive this handle.
    try {
      const started = Date.now();
      const route = await this.resolve({ taskHandle }, timeoutMs, true);
      const result = await this.request('/rpc', { method: 'release_control', params: { controlId: route.controlId }, deviceId: route.deviceId, connectionId: route.connectionId }, Math.max(1, timeoutMs - (Date.now() - started)));
      return result.result ?? {};
    } finally { this.tasks.delete(taskHandle); }
  }

  async renew(taskHandle: string): Promise<Record<string, unknown>> {
    const route = await this.resolve({ taskHandle });
    try {
      const reply = await this.request('/rpc', { method: 'renew_control', params: { controlId: route.controlId }, ...route });
      if (!reply.result || reply.result.state !== 'active') throw new AgentError('INVALID_RESPONSE', 'The phone did not confirm an active lease renewal.', 'unknown');
      return { ...reply.result, taskHandle, instruction: 'Active lease renewed. Continue using this workflow handle; release it in finally.' };
    } catch (error) {
      if (error instanceof AgentError && terminalErrors.has(error.code)) this.tasks.delete(taskHandle);
      throw error;
    }
  }

  async waitForControl(taskHandle: string, timeoutMs: number): Promise<Record<string, unknown>> {
    const route = await this.resolve({ taskHandle }, timeoutMs + 3000, true);
    const endpoint = new URL('/control-events', this.url);
    for (const [key, value] of Object.entries({ ...route, waitMs: timeoutMs })) endpoint.searchParams.set(key, String(value));
    try {
      const result = await this.request(endpoint.pathname + endpoint.search, undefined, timeoutMs + 3000);
      if (result.deviceId !== route.deviceId || result.connectionId !== route.connectionId || result.controlId !== route.controlId)
        throw new AgentError('INVALID_RESPONSE', 'The control notification does not belong to this phone task.', 'unknown');
      const state = z.enum(['active', 'queued', 'released', 'expired', 'cancelled']).parse(result.state);
      const task = this.tasks.get(taskHandle);
      if (!task) throw new AgentError('CONTROL_EXPIRED', 'This task ended while waiting for control.');
      if (state === 'active' || state === 'queued') task.state = state;
      else { this.tasks.delete(taskHandle); throw new AgentError('CONTROL_EXPIRED', `The phone task is ${state}.`); }
      return { ...result, taskHandle, instruction: state === 'active' ? 'Control granted. Observe the phone before acting; release this task in finally.' : 'Still queued. Wait again for a notification, or release this task to cancel. No phone action was sent.' };
    } catch (error) {
      if (error instanceof AgentError && terminalErrors.has(error.code)) this.tasks.delete(taskHandle);
      throw error;
    }
  }

  async sendFile(path: string, target: Target): Promise<unknown> {
    try { const routing = await this.resolve(target); await this.refreshEndpoint(); return await sendLocalFile(this.url, this.token, path, routing); }
    catch (error) {
      if (target.taskHandle && (error instanceof AgentError || error instanceof BridgeError) && terminalErrors.has(error.code)) this.tasks.delete(target.taskHandle);
      if (error instanceof BridgeError) throw new AgentError(error.code, error.message, uncertainErrors.has(error.code) ? 'unknown' : 'not_dispatched', error.details);
      throw error;
    }
  }
  close(): Promise<void> {
    this.closingRequested = true;
    return this.closing ??= (async () => {
      const deadline = Date.now() + 2000;
      let timer: NodeJS.Timeout | undefined;
      try {
        // Late successful acquisitions cancel themselves; wait within the shared shutdown budget.
        await Promise.race([Promise.allSettled([...this.acquisitions]), new Promise<void>(resolve => { timer = setTimeout(resolve, 2000); })]);
      } finally { clearTimeout(timer); }
      await Promise.allSettled([...this.tasks.keys()].map(id => this.release(id, Math.max(1, deadline - Date.now()))));
    })();
  }
}

export const conditionSchema = z.object({
  packageName: z.string().min(1).max(255).optional(),
  text: z.string().min(1).max(512).optional(),
  description: z.string().min(1).max(256).optional(),
  resourceId: z.string().min(1).max(255).optional(),
  absent: z.boolean().default(false),
}).strict().refine(value => !!(value.packageName || value.text || value.description || value.resourceId), 'At least one literal selector is required.');
export type Condition = z.infer<typeof conditionSchema>;

export function checkCondition(state: Record<string, any>, condition: Condition): Record<string, unknown> {
  if (typeof state.packageName !== 'string' || !Array.isArray(state.nodes)) throw new AgentError('INVALID_RESPONSE', 'Phone state did not include a package and node list.', 'unknown');
  const packageMatches = !condition.packageName || state.packageName === condition.packageName;
  const nodeConditions = !!(condition.text || condition.description || condition.resourceId);
  const nodes = Array.isArray(state.nodes) ? state.nodes : [];
  const node = nodes.find(n => n && (!condition.text || n.text === condition.text) &&
    (!condition.description || n.description === condition.description) && (!condition.resourceId || n.resourceId === condition.resourceId));
  const present = packageMatches && (!nodeConditions || !!node);
  // Truncated trees cannot establish that an element is absent.
  const canProveAbsence = !packageMatches || !nodeConditions || state.truncated !== true;
  const matched = condition.absent ? !present && canProveAbsence : present;
  return { matched, evidence: { packageName: state.packageName, snapshotId: state.snapshotId,
    ...(node && packageMatches ? { nodeId: node.id } : {}), truncated: state.truncated === true } };
}

export async function observeCondition(client: AgentClient, condition: Condition, target: Target, timeoutMs: number): Promise<Record<string, unknown>> {
  const deadline = Date.now() + Math.max(1, timeoutMs);
  // Pin the target before polling: a disconnected phone must never turn into the next phone online.
  let pinned = target;
  if (!target.taskHandle && !target.deviceId) {
    const online = (await client.devices(timeoutMs === 0 ? undefined : Math.max(1, deadline - Date.now()))).filter(d => d.connected);
    if (online.length !== 1) throw new AgentError(online.length ? 'DEVICE_REQUIRED' : 'NO_DEVICE', 'Select a phone before observing a condition.');
    pinned = { deviceId: online[0]!.id, connectionId: online[0]!.connectionId };
  } else if (!target.taskHandle && !target.connectionId) {
    const device = (await client.devices(timeoutMs === 0 ? undefined : Math.max(1, deadline - Date.now()))).find(d => d.id === target.deviceId && d.connected);
    if (!device) throw new AgentError('NO_DEVICE', 'The selected phone is offline.');
    pinned = { ...target, connectionId: device.connectionId };
  }
  if (timeoutMs === 0) {
    const state = await client.command('state', {}, pinned);
    const result = checkCondition(state, condition);
    return { ...result, state, ...(!result.matched ? { code: 'ASSERTION_FAILED', message: 'Condition was not observed. No action was retried.' } : {}) };
  }
  let state: Record<string, any> | undefined;
  let lastObservationError: AgentError | undefined;
  do {
    let observed: Record<string, any> | undefined;
    try {
      observed = await client.command('state', {}, pinned, Math.max(1, deadline - Date.now()));
      state = observed; lastObservationError = undefined;
    } catch (error) {
      // App launches can temporarily lack an accessible, verifiable window.
      // Only wait-mode state reads may retry these observed transition codes.
      if (timeoutMs > 0 && error instanceof AgentError && ['NO_WINDOW', 'WINDOW_UNSAFE'].includes(error.code)) lastObservationError = error;
      else { if (Date.now() >= deadline && !(error instanceof AgentError)) break; throw error; }
    }
    if (observed) {
      const checked = checkCondition(observed, condition);
      if (checked.matched) return { ...checked, state: observed };
    }
    if (Date.now() >= deadline) break;
    await new Promise(resolve => setTimeout(resolve, Math.min(200, Math.max(1, deadline - Date.now()))));
  } while (Date.now() < deadline);
  return { matched: false, code: 'WAIT_TIMEOUT',
    ...(lastObservationError ? { lastError: { code: lastObservationError.code, message: lastObservationError.message, outcome: lastObservationError.outcome,
      ...(lastObservationError.details ? { details: lastObservationError.details } : {}) } }
      : state ? { evidence: checkCondition(state, condition).evidence, state } : {}),
    message: lastObservationError ? `Waiting ended after the last observation returned ${lastObservationError.code}. Inspect lastError, let the app transition settle, then observe again. No action was retried.`
      : 'Condition was not observed. No action was retried.' };
}
