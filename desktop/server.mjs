import http from 'node:http';
import { randomBytes, createHash } from 'node:crypto';
import { readFile, writeFile, mkdir, unlink, lstat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { localNetworks, privateIPv4, windowsIdentity } from './network.mjs';
import { serializeNetworkChange } from './network-transaction.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
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
export async function authenticatedStatus(config, token) {
  const response = await fetch(`http://${config.hostAddress}:${config.port}/status`, { headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(2500), redirect: 'error' });
  if (!response.ok) throw new Error('Existing endpoint cannot be authenticated.');
  const status = await response.json();
  if (typeof status.connected !== 'boolean') throw new Error('Unexpected endpoint identity.');
  return status;
}
export function createMcpConfiguration(config, credentialFile) {
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
export async function createDashboard({ config, token, status, startService, changeNetwork, networks, language = 'en', qr, testShutdown, mcpConfiguration, allowLan }) {
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
      if (req.method === 'GET' && req.url === `${base}/ping`) { send(200, { client: 'phonebridge-desktop', pid: process.pid }); return; }
      if (req.method === 'GET' && req.url === `${base}/status`) {
        let current; try { current = await status(); } catch { current = { connected: false, unavailable: true }; }
        send(200, { connected: current.connected, unavailable: !!current.unavailable, address: config.hostAddress, port: config.port, networks: networks().map(a => ({ name: a.name, address: a.address })), qr: await qr(), mcpConfiguration:mcpConfiguration?.(), name: process.env.COMPUTERNAME ?? 'PhoneBridge' }); return;
      }
      if (req.method === 'POST' && req.url === `${base}/start`) { req.resume(); await startService(); send(200, { ok: true }); return; }
      if (allowLan && req.method === 'POST' && req.url === `${base}/allow-lan`) { req.resume(); await allowLan(); send(200, { ok: true }); return; }
      if (testShutdown && req.method === 'POST' && req.url === `${base}/shutdown`) { req.resume(); send(200,{ok:true}); setImmediate(testShutdown); return; }
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
async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--self-test')) { const { runSelfTest } = await import('./self-test.mjs'); await runSelfTest(); return; }
  const sid = windowsIdentity(); const path = resolve(configPath());
  if (args.includes('--diagnose')) {
    let existing = false; try { await readOwnedConfig(path, sid); existing = true; } catch (e) { if (e.code !== 'ENOENT') throw e; }
    console.log(JSON.stringify({ product: 'PhoneBridge', version: '0.6.0', platform:'windows-x64', runtime: process.version, existingOwnedConfig: existing, privateNetworks: localNetworks().length, dryRun: true })); return;
  }
  const statePath = join(dirname(path), `client-${createHash('sha256').update(path.toLowerCase()).digest('hex').slice(0, 12)}.json`);
  await mkdir(dirname(statePath), { recursive: true });
  try {
    const existing = JSON.parse(await readFile(statePath, 'utf8'));
    const url = new URL(existing.url);
    if (existing.ownerSid !== sid || url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !/^\/session\/[A-Za-z0-9_-]{32}$/.test(url.pathname)) throw new Error('Untrusted client state');
    const probe = await fetch(`${url.href}/ping`, { signal: AbortSignal.timeout(1500), redirect: 'error' });
    const data = await probe.json();
    if (probe.ok && data.client === 'phonebridge-desktop' && data.pid === existing.pid) { if (!args.includes('--no-open')) openBrowser(url.href); console.log(JSON.stringify({ready:true,reusedClient:true,dashboardLoopback:true})); return; }
  } catch (e) { if (e.message === 'Untrusted client state') throw e; }
  // An exclusive claim handles concurrent launch; dead claims are recovered without touching a live client.
  const claimPath = statePath + '.lock';
  try { await writeFile(claimPath, String(process.pid), { flag: 'wx' }); }
  catch (e) {
    if (e.code !== 'EEXIST') throw e;
    const pid = Number(await readFile(claimPath, 'utf8'));
    try { process.kill(pid, 0); } catch (err) { if (err.code === 'ESRCH') { await unlink(claimPath); return main(); } throw err; }
    for (let attempt = 0; attempt < 50; attempt++) { await new Promise(r => setTimeout(r, 200)); try { const record = JSON.parse(await readFile(statePath, 'utf8')); const u = new URL(record.url); if (record.ownerSid === sid && u.protocol === 'http:' && u.hostname === '127.0.0.1' && /^\/session\/[A-Za-z0-9_-]{32}$/.test(u.pathname) && record.pid === pid) { const p = await fetch(`${u.href}/ping`, { signal: AbortSignal.timeout(1000),redirect:'error' }); const data = await p.json(); if (p.ok && data.client === 'phonebridge-desktop' && data.pid === pid) { if (!args.includes('--no-open')) openBrowser(u.href); console.log(JSON.stringify({ready:true,reusedClient:true,dashboardLoopback:true})); return; } } } catch {} }
    throw new Error('PhoneBridge is already starting. Please try again.');
  }
  let supervisor, dashboard, stop;
  try {
    let config;
    try { config = await readOwnedConfig(path, sid); }
    catch (e) { if (e.code !== 'ENOENT') throw e; const net = localNetworks()[0]; if (!net) throw new Error('Connect this computer to a private Wi-Fi or Ethernet network.'); config = { schema: 'phonebridge-desktop-v1', ownerSid: sid, projectRoot: root, nodePath: process.execPath, hostAddress: net.address, port: 8767, launcherPath: join(root, 'scripts', 'windows', 'run-desktop.ps1'), powershellPath: process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' }; await writeFile(path, JSON.stringify(config), { flag: 'wx' }); }
    // DPAPI helper uses Windows PowerShell; add only this OS directory, never require Node/npm on PATH.
    process.env.PATH = dirname(config.powershellPath) + ';' + (process.env.PATH ?? '');
    const { credentialPath, loadOrCreateSavedToken } = await import('../bridge/dist/credentials.js');
    const { pairingUri } = await import('../bridge/dist/pairing.js');
    const { default: QRCode } = await import('../bridge/node_modules/qrcode/lib/index.js');
    const token = await loadOrCreateSavedToken(credentialPath());
    const start = async () => {
      try { await authenticatedStatus(config, token); return; } catch {}
      if (!localNetworks().some(a => a.address === config.hostAddress) && !(process.env.PHONEBRIDGE_DESKTOP_TEST === '1' && config.hostAddress === '127.0.0.1')) throw new Error('The saved network is unavailable. Select your current private network.');
      // If a configured endpoint is occupied by another identity, listen fails closed; never rotate pairing.
      if (supervisor) { await supervisor.ensureRunning(); return; }
      if (process.env.PHONEBRIDGE_DESKTOP_TEST !== '1') {
        const task = spawnSync(config.powershellPath, ['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',join(root,'desktop','task-control.ps1'),'-ConfigurationPath',path], { windowsHide:true,encoding:'utf8',timeout:15000 });
        if (task.status !== 2) {
          if (task.status !== 0) throw new Error('Cannot start the existing managed task safely. Existing configuration was preserved.');
          for (let i=0;i<30;i++) { await new Promise(r=>setTimeout(r,300));try { await authenticatedStatus(config,token);return; } catch {} }
          throw new Error('The managed desktop service is starting or unavailable. Try Start desktop service again.');
        }
      }
      const { DesktopSupervisor } = await import('../bridge/dist/supervisor.js');
      const s = new DesktopSupervisor({ token, host: config.hostAddress, port: config.port, allowLan: true });
      try { await s.start(); supervisor = s; } catch { throw new Error('This port is occupied or the saved network is unavailable. Existing service was preserved.'); }
    };
    let startupError; try { await start(); } catch (e) { startupError = e; }
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
    dashboard = await createDashboard({ config, token, networks: localNetworks, status: () => authenticatedStatus(config, token), startService: start,
      changeNetwork: serializeNetworkChange(async address => {
        if (!privateIPv4(address) || !localNetworks().some(a => a.address === address)) throw new Error('Select an active private network.');
        if (!supervisor) { try { await authenticatedStatus(config, token); throw new Error('An existing desktop service is running. Stop it before changing its network.'); } catch (e) { if (e.message.startsWith('An existing')) throw e; } }
        if (address === config.hostAddress) { await start(); return; }
        if (supervisor) { const status = await authenticatedStatus(config, token); if (status.connected) throw new Error('Disconnect your phone before changing networks.'); }
        await replaceNetwork(config,address,{previous:supervisor,activate:candidate=>{supervisor=candidate},
          createCandidate: async next => { const { DesktopSupervisor }=await import('../bridge/dist/supervisor.js');const candidate=new DesktopSupervisor({token,host:next.hostAddress,port:next.port,allowLan:true});try{await candidate.start();if(!candidate.serviceRunning)throw new Error('New network service could not start.');return candidate;}catch(error){await candidate.close().catch(()=>{});throw error;} },
          persist:async next=>{await writeFile(path+'.backup-'+Date.now(),JSON.stringify(config),{flag:'wx'});const temporary=path+'.tmp-'+process.pid;try{await writeFile(temporary,JSON.stringify(next));const {rename}=await import('node:fs/promises');await rename(temporary,path);}finally{await unlink(temporary).catch(()=>{});}}
        });
      }), language: process.env.LANG?.startsWith('zh') || spawnSync(config.powershellPath, ['-NoProfile', '-Command', '(Get-UICulture).Name'], { encoding: 'utf8', windowsHide: true,timeout:10000 }).stdout?.trim().startsWith('zh') ? 'zh' : 'en',
      qr: () => QRCode.toDataURL(pairingUri(`ws://${config.hostAddress}:${config.port}/device`, token), { width: 360, margin: 3 }),
      mcpConfiguration:()=>createMcpConfiguration(config,credentialPath()),allowLan,
      testShutdown: process.env.PHONEBRIDGE_DESKTOP_TEST === '1' ? () => void stop() : undefined });
    await writeFile(statePath, JSON.stringify({ ownerSid: sid, pid: process.pid, url: dashboard.url }));
    if (!args.includes('--no-open')) openBrowser(dashboard.url);
    // Do not print pairing tokens or the private dashboard URL.
    console.log(JSON.stringify({ ready: true, reusedService: !supervisor && !startupError, dashboardLoopback: true }));
    let stopping = false; stop = async () => { if (stopping) return; stopping = true; await dashboard?.close(); await supervisor?.close(); await unlink(statePath).catch(() => {}); await unlink(claimPath).catch(() => {}); };
    process.on('SIGINT', () => void stop()); process.on('SIGTERM', () => void stop());
  } catch (e) { await dashboard?.close(); await supervisor?.close(); await unlink(claimPath).catch(() => {}); throw e; }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.error(e instanceof Error ? e.message : 'Client failed'); process.exitCode = 1; });
