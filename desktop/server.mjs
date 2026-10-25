import http from 'node:http';
import { randomBytes, createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, unlink, lstat, link } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { homedir, hostname, networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { lstatSync } from 'node:fs';
import { localNetworks, privateIPv4, windowsIdentity } from './network.mjs';
import { serializeNetworkChange, createNetworkRecovery, persistNetworkConfig } from './network-transaction.mjs';
import { startLauncherMaintenance } from './launcher-maintenance.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// Dashboard claims are separate from the hub/service identity. Legacy clients
// keyed claims only by config path, so an upgrade could reuse old application
// code indefinitely. Do not kill a legacy PID: it may also own a supervisor.
export function dashboardIdentity({ projectRoot, nodePath, source, platform = process.platform }) {
  const canonical = path => platform === 'win32' ? resolve(path).toLowerCase() : resolve(path);
  return createHash('sha256').update(JSON.stringify(['phonebridge-dashboard-v2', canonical(projectRoot), canonical(nodePath)]))
    .update('\0').update(source).digest('hex');
}
export function dashboardStatePath(configurationPath, clientIdentity) {
  if (!/^[a-f0-9]{64}$/.test(clientIdentity)) throw new Error('Invalid dashboard identity');
  const absolute = resolve(configurationPath);
  const configKey = createHash('sha256').update(absolute.toLowerCase()).digest('hex').slice(0, 12);
  return join(dirname(absolute), `client-${configKey}-${clientIdentity}.json`);
}
export async function reusableDashboardUrl(record, { ownerSid, clientIdentity, expectedPid, timeout = 1500, fetchImpl = fetch }) {
  if (!record || record.ownerSid !== ownerSid) throw new Error('Untrusted client state');
  if (record.clientIdentity !== clientIdentity || (expectedPid !== undefined && record.pid !== expectedPid)) return null;
  const match = typeof record.url === 'string' && /^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/session\/[A-Za-z0-9_-]{32}$/.exec(record.url);
  if (!Number.isInteger(record.pid) || record.pid <= 0 || !match || match[0] !== record.url || Number(match[1]) > 65535) throw new Error('Untrusted client state');
  try {
    const response = await fetchImpl(`${record.url}/ping`, { signal: AbortSignal.timeout(timeout), redirect: 'error' });
    const data = await response.json();
    return response.ok && data.client === 'phonebridge-desktop' && data.pid === record.pid && data.clientIdentity === clientIdentity ? record.url : null;
  } catch { return null; }
}
export const configPath = () => process.env.PHONEBRIDGE_DESKTOP_CONFIG ?? join(homedir(), '.phonebridge', 'desktop.json');
export function validateConfig(config, sid) {
  if (!config || config.schema !== 'phonebridge-desktop-v1' || config.ownerSid !== sid) throw new Error('Desktop configuration belongs to another user or has an unsupported schema.');
  if (!privateIPv4(config.hostAddress) && !(process.env.PHONEBRIDGE_DESKTOP_TEST === '1' && config.hostAddress === '127.0.0.1')) throw new Error('PhoneBridge needs a private LAN address. Existing configuration was preserved.');
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error('Invalid desktop port.');
  for (const key of ['projectRoot', 'nodePath', 'launcherPath', 'powershellPath']) if (typeof config[key] !== 'string' || !/^(?:[a-z]:[\\/]|\/)/i.test(config[key]) || /["\r\n]/.test(config[key])) throw new Error('Unsafe desktop path.');
  return config;
}
export async function readOwnedConfig(path, sid) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || info.size > 32768) throw new Error('Invalid desktop configuration file.');
  return validateConfig(JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, '')), sid);
}
export async function authenticatedStatus(config, token, { interfaces = networkInterfaces(), fetchImpl = fetch } = {}) {
  if (!Object.values(interfaces).flat().some(network => network?.address === config.hostAddress)) throw new Error('The saved network is no longer local to this computer.');
  const response = await fetchImpl(`http://${config.hostAddress}:${config.port}/status`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(2500), redirect: 'error' });
  if (!response.ok) throw new Error('Existing endpoint cannot be authenticated.');
  const status = await response.json();
  if (typeof status.connected !== 'boolean') throw new Error('Unexpected endpoint identity.');
  return status;
}
export function createMcpConfiguration(config, credentialFile, { configFile, platform = config.schema === 'phonebridge-macos-desktop-v1' ? 'darwin' : 'win32' } = {}) {
  const activeConfig = configFile ?? process.env.PHONEBRIDGE_DESKTOP_CONFIG ?? join(homedir(), '.phonebridge', platform === 'darwin' ? 'desktop-macos.json' : 'desktop.json');
  const stable = join(dirname(resolve(activeConfig)), 'bin', platform === 'darwin' ? 'phonebridge-mcp' : 'PhoneBridgeMcp.exe');
  const installedCredential = config.credentialFile ?? join(dirname(resolve(activeConfig)), 'pairing.json');
  const canonicalName = platform === 'darwin' ? 'desktop-macos.json' : 'desktop.json';
  if (basename(activeConfig) === canonicalName && config.mcpLauncherPath === stable && resolve(credentialFile) === resolve(installedCredential)) {
    try {
      const info = lstatSync(stable);
      if (info.isFile() && !info.isSymbolicLink()) return { mcpServers: { phonebridge: platform === 'darwin' ? { command: '/bin/sh', args: [stable] } : { command: stable, args: [] } } };
    } catch { /* Portable/development use retains the explicit direct-runtime configuration. */ }
  }
  return { mcpServers: { phonebridge: { command: config.nodePath,
    args: [join(config.projectRoot,'bridge','dist','mcp.js')],
    env: { PHONEBRIDGE_URL:`http://${config.hostAddress}:${config.port}`,PHONEBRIDGE_CREDENTIAL_FILE:resolve(credentialFile) }
  } } };
}
export async function replaceNetwork(config, address, { createCandidate, persist, previous, activate }) {
  const next = { ...config, hostAddress: address };
  const candidate = await createCandidate(next);
  try { await persist(next); }
  catch (error) { await candidate.close().catch(() => {}); throw error; }
  // Publish the new QR only once a working endpoint and durable configuration both exist.
  Object.assign(config, next); activate(candidate);
  await previous?.close();
}
function safeRequest(req, authority, secret, mutation) {
  const site = req.headers['sec-fetch-site'];
  return req.headers.host === authority && (!site || ['none', 'same-origin'].includes(site)) &&
    (!req.headers.origin || req.headers.origin === `http://${authority}`) &&
    (!mutation || (req.headers.origin === `http://${authority}` && req.headers['x-phonebridge-csrf'] === secret));
}
export async function createDashboard({ config, token, status, startService, changeNetwork, networks, language = 'en', qr, testShutdown, mcpConfiguration, allowLan, startupError, clientIdentity }) {
  const secret = randomBytes(24).toString('base64url');
  const base = `/session/${secret}`;
  let authority = '';
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store'); res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    const send = (code, value, type = 'application/json') => { res.writeHead(code, { 'Content-Type': type }); res.end(type === 'application/json' ? JSON.stringify(value) : value); };
    if (!safeRequest(req, authority, secret, req.method !== 'GET')) { req.resume(); send(403, { error: 'Local request required' }); return; }
    try {
      if (req.method === 'GET' && req.url === base) {
        const html = (await readFile(join(root, 'desktop', 'dashboard.html'), 'utf8')).replaceAll('__BASE__', base).replace('__LANG__', language);
        send(200, html, 'text/html; charset=utf-8'); return;
      }
      if (req.method === 'GET' && req.url === `${base}/app.js`) { send(200, await readFile(join(root, 'desktop', 'dashboard.js'), 'utf8'), 'text/javascript; charset=utf-8'); return; }
      if (req.method === 'GET' && req.url === `${base}/ping`) { send(200, { client: 'phonebridge-desktop', pid: process.pid, clientIdentity }); return; }
      if (req.method === 'GET' && req.url === `${base}/status`) {
        let current; try { current = await status(); } catch { current = { connected: false, unavailable: true }; }
        const devices = Array.isArray(current.devices) ? current.devices.map(({ id, name, connected, protocol, capabilities, busy, readOnly, connectionId, controlling, controlOwnerName, waitingCount, transfer }) => ({ id, name, connected, protocol, capabilities, busy, readOnly, connectionId, controlling, controlOwnerName, ...(Number.isInteger(waitingCount) && waitingCount >= 0 && waitingCount <= 64 ? { waitingCount } : {}), ...(transfer ? { transfer: { name: transfer.name, state: transfer.state, size: transfer.size, mimeType: transfer.mimeType } } : {}) })) : [];
        send(200, { connected: current.connected, devices, transfer: current.transfer, unavailable: !!current.unavailable, address: config.hostAddress, port: config.port, networks: networks().map(a => ({ name: a.name, address: a.address })), qr: await qr(), mcpConfiguration:mcpConfiguration?.(), name: process.env.COMPUTERNAME ?? hostname(), error: startupError?.() }); return;
      }
      if (req.method === 'POST' && req.url === `${base}/start`) { req.resume(); await startService(); send(200, { ok: true }); return; }
      if (allowLan && req.method === 'POST' && req.url === `${base}/allow-lan`) { req.resume(); await allowLan(); send(200, { ok: true }); return; }
      if (testShutdown && req.method === 'POST' && req.url === `${base}/shutdown`) { req.resume(); send(200,{ok:true}); setImmediate(testShutdown); return; }
      if (req.method === 'POST' && req.url === `${base}/send-file`) {
        let body = ''; for await (const chunk of req) { body += chunk; if (body.length > 8192) throw new Error('Request too large'); }
        const { path, deviceId, connectionId } = JSON.parse(body);
        if (deviceId !== undefined && (typeof deviceId !== 'string' || !deviceId || deviceId.length > 256)) throw new Error('Invalid device target');
        if (connectionId !== undefined && (typeof connectionId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(connectionId))) throw new Error('Invalid connection identity');
        const { sendLocalFile } = await import('../bridge/dist/send-file.js');
        send(200, await sendLocalFile(new URL(`http://${config.hostAddress}:${config.port}`), token, path, { deviceId, connectionId })); return;
      }
      if (req.method === 'POST' && req.url === `${base}/network`) {
        let body = ''; for await (const chunk of req) { body += chunk; if (body.length > 1024) throw new Error('Request too large'); }
        const { address } = JSON.parse(body); await changeNetwork(address); send(200, { ok: true }); return;
      }
      req.resume(); send(404, { error: 'Not found' });
    } catch (error) { send(409, { error: error instanceof Error ? error.message : 'Unable to complete request' }); }
  });
  server.requestTimeout = 5000; server.headersTimeout = 5000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  authority = `127.0.0.1:${server.address().port}`;
  return { url: `http://${authority}${base}`, secret, close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }) };
}
function openBrowser(url) { spawn(process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `Start-Process '${url}'`], { windowsHide: true, stdio: 'ignore' }).unref(); }
export function nativeReady(args, url, fields = {}) {
  const ready = { ready: true, ...fields, dashboardLoopback: true };
  if (args.includes('--native-window')) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' || parsed.hostname !== '127.0.0.1' || !parsed.port || parsed.username || parsed.password || parsed.search || parsed.hash || !/^\/session\/[A-Za-z0-9_-]{32}$/.test(parsed.pathname)) throw new Error('Invalid local dashboard session.');
    ready.dashboardUrl = parsed.href;
  }
  return ready;
}
function announceReady(args, url, fields) {
  if (!args.includes('--no-open') && !args.includes('--native-window')) openBrowser(url);
  console.log(JSON.stringify(nativeReady(args, url, fields)));
}
async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--self-test')) { const { runSelfTest } = await import('./self-test.mjs'); await runSelfTest(); return; }
  const sid = windowsIdentity(); const path = resolve(configPath());
  if (args.includes('--diagnose')) {
    let existing = false; try { await readOwnedConfig(path, sid); existing = true; } catch (e) { if (e.code !== 'ENOENT') throw e; }
    const manifest=JSON.parse((await readFile(join(root,'package-manifest.json'),'utf8').catch(e=>{if(e.code==='ENOENT')return '{}';throw e;})).replace(/^\uFEFF/,''));
    console.log(JSON.stringify({ product: 'PhoneBridge', version: manifest.version??'0.6.0', platform:'windows-x64', runtime: process.version, existingOwnedConfig: existing, privateNetworks: localNetworks().length, dryRun: true })); return;
  }
  const clientIdentity = dashboardIdentity({ projectRoot: root, nodePath: process.execPath, source: await readFile(fileURLToPath(import.meta.url)) });
  const statePath = dashboardStatePath(path, clientIdentity);
  await mkdir(dirname(statePath), { recursive: true });
  try {
    const existing = JSON.parse(await readFile(statePath, 'utf8'));
    const url = await reusableDashboardUrl(existing, { ownerSid: sid, clientIdentity });
    if (url) { announceReady(args,url,{reusedClient:true}); return; }
  } catch (e) { if (e.message === 'Untrusted client state') throw e; }
  // An exclusive claim handles concurrent launch; dead claims are recovered without touching a live client.
  const claimPath = statePath + '.lock';
  try {
    // Publish a fully written PID with an atomic, exclusive hard-link creation.
    // A competing launcher can never observe an empty just-created claim.
    const temporary=claimPath+'.'+randomBytes(8).toString('hex')+'.tmp';
    try{await writeFile(temporary,String(process.pid),{flag:'wx'});await link(temporary,claimPath);}finally{await unlink(temporary).catch(()=>{});}
  }
  catch (e) {
    if (e.code !== 'EEXIST') throw e;
    let pid;try{pid=Number(await readFile(claimPath,'utf8'));}catch(error){if(error.code==='ENOENT')return main();throw error;}
    if(!Number.isInteger(pid)||pid<=0)throw new Error('Invalid client startup record.');
    try { process.kill(pid, 0); } catch (err) {
      if (err.code === 'ESRCH') {
        // A current-user OS mutex serializes the read/check/delete operation. A
        // second recovery can never delete the fresh claim created by a winner.
        const recovered=spawnSync(process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(root,'desktop','recover-client-claim.ps1'),'-ClaimPath',claimPath,'-OwnerSid',sid],{windowsHide:true,encoding:'utf8',timeout:15000});
        if(recovered.status!==0)throw new Error('Client startup recovery is busy or unavailable. Please retry.');
        return main();
      }
      throw err;
    }
    for (let attempt = 0; attempt < 50; attempt++) {
      await new Promise(r => setTimeout(r, 200));
      try {
        const record = JSON.parse(await readFile(statePath, 'utf8'));
        const url = await reusableDashboardUrl(record, { ownerSid: sid, clientIdentity, expectedPid: pid, timeout: 1000 });
        if (url) { announceReady(args,url,{reusedClient:true}); return; }
      } catch {}
    }
    throw new Error('PhoneBridge is already starting. Please try again.');
  }
  let supervisor, dashboard, stop, recovery, maintenance;
  try {
    let config;
    try { config = await readOwnedConfig(path, sid); }
    catch (e) { if (e.code !== 'ENOENT') throw e; const net = localNetworks()[0]; if (!net) throw new Error('Connect this computer to a private Wi-Fi or Ethernet network.'); config = { schema: 'phonebridge-desktop-v1', ownerSid: sid, projectRoot: root, nodePath: process.execPath, hostAddress: net.address, port: 8767, launcherPath: join(root, 'scripts', 'windows', 'run-desktop.ps1'), powershellPath: process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' }; await writeFile(path, JSON.stringify(config), { flag: 'wx' }); }
    // DPAPI helper uses Windows PowerShell; add only this OS directory, never require Node/npm on PATH.
    process.env.PATH = dirname(config.powershellPath) + ';' + (process.env.PATH ?? '');
    const { credentialPath, loadOrCreateSavedToken } = await import('../bridge/dist/credentials.js');
    const { pairingUri } = await import('../bridge/dist/pairing.js');
    const { default: QRCode } = await import('../bridge/node_modules/qrcode/lib/index.js');
    const savedCredentialFile = config.credentialFile ?? credentialPath();
    const token = await loadOrCreateSavedToken(savedCredentialFile);
    maintenance = startLauncherMaintenance(path, { readConfig: () => readOwnedConfig(path, sid) });
    const availableNetworks = () => {
      const networks = localNetworks();
      if (process.env.PHONEBRIDGE_DESKTOP_TEST === '1' && config.hostAddress === '127.0.0.1') networks.push({ address: '127.0.0.1', internal: true });
      return networks;
    };
    recovery = createNetworkRecovery({ config, networks: availableNetworks,
      readConfig: () => readOwnedConfig(path, sid),
      createCandidate: async next => {
        const { DesktopSupervisor } = await import('../bridge/dist/supervisor.js');
        const candidate = new DesktopSupervisor({ token, host: next.hostAddress, port: next.port, allowLan: true,
          logFile: process.env.PHONEBRIDGE_LOG_FILE ?? join(dirname(savedCredentialFile), 'operations.jsonl') });
        try { await candidate.start(); return candidate; }
        catch (error) { await candidate.close(); throw error; }
      },
      persist: (next, expected) => persistNetworkConfig(path, next, expected, { readConfig: () => readOwnedConfig(path, sid) }),
      onError: error => { startupError = error; },
      onReady: current => { supervisor = current; startupError = undefined; },
    });
    const refreshConfig = async () => { Object.assign(config, await readOwnedConfig(path, sid)); };
    const start = async () => {
      if (recovery.supervisor) { supervisor = await recovery.ensure(); return; }
      await refreshConfig();
      try { await authenticatedStatus(config, token); return; } catch {}
      // If a configured endpoint is occupied by another identity, listen fails closed; never rotate pairing.
      if (process.env.PHONEBRIDGE_DESKTOP_TEST !== '1') {
        const task = spawnSync(config.powershellPath, ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(root,'desktop','task-control.ps1'),'-ConfigurationPath',path], { windowsHide:true,encoding:'utf8',timeout:15000 });
        if (task.status !== 2) {
          if (task.status !== 0) throw new Error('Cannot start the existing managed task safely. Existing configuration was preserved.');
          for (let i=0;i<30;i++) { await new Promise(r=>setTimeout(r,300));try { await refreshConfig(); await authenticatedStatus(config,token);return; } catch {} }
          throw new Error('The managed desktop service is starting or unavailable. Try Start desktop service again.');
        }
      }
      supervisor = await recovery.ensure();
      recovery.watch();
    };
    let startupError, startupPromise;
    const startWithFeedback=()=>{
      if(startupPromise)return startupPromise;
      startupPromise=start().then(()=>{startupError=undefined;},e=>{startupError=e;throw e;}).finally(()=>{startupPromise=undefined;});
      return startupPromise;
    };
    let requestingLan=false;
    const allowLan=async()=>{
      if(requestingLan)throw new Error('Windows LAN permission is already awaiting approval.');
      requestingLan=true;
      try {
        await new Promise((done,reject)=>{
          const child=spawn(process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(config.projectRoot,'desktop','allow-lan.ps1'),'-ConfigurationPath',path,'-RequestElevation'],{windowsHide:true,stdio:'ignore'});
          child.once('error',reject);child.once('exit',code=>code===0?done():reject(new Error('Windows LAN permission was cancelled or could not be granted. Only the current owner can approve it; custom firewall policies require owner review.')));
        });
      } finally { requestingLan=false; }
    };
    dashboard = await createDashboard({ config, token, clientIdentity, networks: localNetworks, status: async () => { await refreshConfig(); return authenticatedStatus(config, token); }, startService: startWithFeedback, startupError:()=>startupError?.message,
      changeNetwork: serializeNetworkChange(async address => {
        if(startupPromise)throw new Error('The desktop service is starting. Please wait before changing networks.');
        if (!privateIPv4(address) || !localNetworks().some(a => a.address === address)) throw new Error('Select an active private network.');
        if (!supervisor) { try { await authenticatedStatus(config, token); throw new Error('An existing desktop service is running. Stop it before changing its network.'); } catch (e) { if (e.message.startsWith('An existing')) throw e; } }
        if (address === config.hostAddress) { await startWithFeedback(); return; }
        if (supervisor) { const status = await authenticatedStatus(config, token); if (status.connected) throw new Error('Disconnect your phone before changing networks.'); }
        supervisor = await recovery.change(address);
        recovery.watch();
        startupError=undefined;
      }), language: process.env.LANG?.startsWith('zh') || spawnSync(config.powershellPath, ['-NoProfile', '-Command', '(Get-UICulture).Name'], { encoding: 'utf8', windowsHide: true,timeout:10000 }).stdout?.trim().startsWith('zh') ? 'zh' : 'en',
      qr: () => QRCode.toDataURL(pairingUri(`ws://${config.hostAddress}:${config.port}/device`, token), { width: 360, margin: 3 }),
      mcpConfiguration:()=>createMcpConfiguration(config,savedCredentialFile),allowLan,
      testShutdown: process.env.PHONEBRIDGE_DESKTOP_TEST === '1' ? () => void stop() : undefined });
    await writeFile(statePath, JSON.stringify({ ownerSid: sid, pid: process.pid, url: dashboard.url, clientIdentity }));
    // The private URL is emitted only to an explicitly requested native-child pipe.
    announceReady(args,dashboard.url,{});
    let stopping = false; stop = async () => { if (stopping) return; stopping = true; await dashboard?.close(); await startupPromise?.catch(()=>{}); await recovery?.close(); await maintenance?.close(); await unlink(statePath).catch(() => {}); await unlink(claimPath).catch(() => {}); };
    process.on('SIGINT', () => void stop()); process.on('SIGTERM', () => void stop());
    void startWithFeedback().catch(()=>{});
  } catch (e) { await dashboard?.close(); await recovery?.close(); await maintenance?.close(); await unlink(claimPath).catch(() => {}); throw e; }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.error(e instanceof Error ? e.message : 'Client failed'); process.exitCode = 1; });
