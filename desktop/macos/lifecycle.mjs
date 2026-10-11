import { lstat, mkdir, readFile, writeFile, rename, unlink, realpath } from 'node:fs/promises';
import { join, dirname, resolve, isAbsolute } from 'node:path';
import { networkInterfaces, homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { privateIPv4, selectNetworks } from '../network.mjs';
import { installMcpLauncher } from './mcp-launcher.mjs';

export const agentLabel = 'dev.phonebridge.desktop';
export const macConfigPath = () => process.env.PHONEBRIDGE_DESKTOP_CONFIG ?? join(homedir(), '.phonebridge', 'desktop-macos.json');
export function validateMacConfig(value, uid = process.getuid?.(), { test = false } = {}) {
  if (!value || value.schema !== 'phonebridge-macos-desktop-v1' || value.ownerUid !== uid || !Number.isInteger(uid)) throw new Error('Unsupported desktop configuration or another owner.');
  if (!privateIPv4(value.hostAddress) && !(test && value.hostAddress === '127.0.0.1')) throw new Error('Select a private Wi-Fi or Ethernet network.');
  if (!Number.isInteger(value.port) || value.port < 1 || value.port > 65535) throw new Error('Invalid desktop port.');
  for (const key of ['projectRoot', 'nodePath']) if (typeof value[key] !== 'string' || !isAbsolute(value[key]) || /[\r\n\0]/.test(value[key])) throw new Error('Invalid desktop path.');
  if (value.nodePath !== join(value.projectRoot, 'runtime', 'node')) throw new Error('The desktop runtime must be inside the App.');
  return value;
}
export async function privateDirectory(path, uid = process.getuid?.()) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077) !== 0) throw new Error('PhoneBridge data must be in a private directory owned by you.');
}
export async function readPrivateFile(path, uid = process.getuid?.()) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077) !== 0 || stat.size > 32768) throw new Error('Invalid or foreign PhoneBridge file; existing data was preserved.');
  return readFile(path, 'utf8');
}
export async function readMacConfig(path, uid = process.getuid?.(), options) {
  return validateMacConfig(JSON.parse(await readPrivateFile(path, uid)), uid, options);
}
export async function writePrivateFile(path, data, uid = process.getuid?.()) {
  const parent = await lstat(dirname(path));
  if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== uid) throw new Error('Invalid destination owner.');
  try { await readPrivateFile(path, uid); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const temp = path + '.tmp-' + randomBytes(6).toString('hex');
  try { await writeFile(temp, data, { flag: 'wx', mode: 0o600 }); await rename(temp, path); }
  finally { await unlink(temp).catch(() => {}); }
}
export function macNetworks(interfaces = networkInterfaces(), defaultInterface) {
  if (defaultInterface === undefined && process.platform === 'darwin') {
    const route = spawnSync('/sbin/route', ['-n', 'get', 'default'], { encoding: 'utf8', timeout: 1000 });
    defaultInterface = /interface:\s*(\S+)/.exec(route.stdout ?? '')?.[1];
  }
  return selectNetworks(Object.entries(interfaces).flatMap(([name, items]) => (items ?? []).filter(item => item.family === 'IPv4').map(item => ({ ...item, name, physical: /^en\d+$/.test(name), defaultRoute: name === defaultInterface }))));
}
const xml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c]);
export function launchAgent(config, home = homedir()) {
  const logDirectory = join(home, '.phonebridge');
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>
<key>Label</key><string>${agentLabel}</string>
<key>ProgramArguments</key><array><string>${xml(config.nodePath)}</string><string>${xml(join(config.projectRoot, 'desktop', 'macos', 'service.mjs'))}</string><string>--config</string><string>${xml(config.configFile)}</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer><key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${xml(join(logDirectory, 'macos-service.stdout.log'))}</string><key>StandardErrorPath</key><string>${xml(join(logDirectory, 'macos-service.stderr.log'))}</string>
</dict></plist>\n`;
}
export async function validateInstalledApp(resources, home = homedir()) {
  const absolute = resolve(resources);
  const app = dirname(dirname(absolute));
  if (dirname(absolute).split(/[\\/]/).pop() !== 'Contents' || absolute.split(/[\\/]/).pop() !== 'Resources' || !app.endsWith('.app') || ![ '/Applications', join(home, 'Applications') ].includes(dirname(app))) throw new Error('Copy PhoneBridge.app to Applications before starting the service.');
  if (await realpath(absolute) !== absolute) throw new Error('Install the App in a stable Applications location.');
  const manifest = JSON.parse(await readFile(join(absolute, 'package-manifest.json'), 'utf8'));
  if (manifest.product !== 'PhoneBridge' || !/^darwin-(arm64|x64)$/.test(manifest.platform)) throw new Error('Invalid PhoneBridge App bundle.');
  return absolute;
}
export function runLaunchctl(args) {
  const result = spawnSync('/bin/launchctl', args, { encoding: 'utf8', timeout: 15000, maxBuffer: 131072 });
  return { status: result.status, stdout: result.stdout ?? '', error: !!result.error };
}
function requireSuccess(result) { if (result.status !== 0 || result.error) throw new Error('macOS could not start the user service. Existing setup was preserved.'); }
export function ownsLoadedJob(output, config, configFile, plistPath) {
  const lines=output.split('\n').map(line=>line.trim());
  const argumentsBlock=/\barguments = \{\s*\n([\s\S]*?)\n\s*\}/.exec(output)?.[1];
  const args=argumentsBlock?.split('\n').map(line=>line.trim()).filter(Boolean);
  const expected=[config.nodePath,join(config.projectRoot,'desktop','macos','service.mjs'),'--config',configFile];
  return lines.includes(`path = ${plistPath}`) && lines.includes(`program = ${config.nodePath}`) && !!args && args.length===expected.length && args.every((value,index)=>value===expected[index]);
}
export async function privateLog(path, uid=process.getuid?.()) {
  try {
    const stat=await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid!==uid || (stat.mode & 0o077)!==0) throw new Error('A service log is not a private file owned by you. It was preserved.');
  } catch(error) { if(error.code!=='ENOENT') throw error; await writeFile(path,'',{mode:0o600,flag:'wx'}); }
}

/** Modifies only our exact current-user job, restoring old config/job on failure. */
export async function installService({ config, previous, configFile, home = homedir(), uid = process.getuid?.(), run = runLaunchctl, probe, attempts = 24, delay = 350 }) {
  validateMacConfig(config, uid);
  const directory = join(home, 'Library', 'LaunchAgents');
  await mkdir(directory, { recursive: true });
  const dirInfo = await lstat(directory);
  if (!dirInfo.isDirectory() || dirInfo.isSymbolicLink() || dirInfo.uid !== uid) throw new Error('The LaunchAgents directory is not owned by you.');
  const plistPath = join(directory, agentLabel + '.plist');
  const domain = `gui/${uid}`, job = `${domain}/${agentLabel}`;
  let oldPlist;
  try { oldPlist = await readPrivateFile(plistPath, uid); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const expectedOld = previous ? launchAgent({ ...previous, configFile }, home) : launchAgent({ ...config, configFile }, home);
  if (oldPlist !== undefined && oldPlist !== expectedOld) throw new Error('A different or modified PhoneBridge LaunchAgent exists. It was preserved.');
  const loaded = run(['print', job]);
  if (loaded.status === 0 && (!oldPlist || !ownsLoadedJob(loaded.stdout,previous??config,configFile,plistPath))) throw new Error('A foreign service uses the PhoneBridge name. It was preserved.');
  await privateDirectory(join(home,'.phonebridge'),uid);
  const mcpLauncherPath = await installMcpLauncher(dirname(configFile), uid);
  config = { ...config, mcpLauncherPath };
  for (const name of ['macos-service.stdout.log','macos-service.stderr.log']) await privateLog(join(home,'.phonebridge',name),uid);
  const nextPlist = launchAgent({ ...config, configFile }, home);
  const oldConfigText = await readPrivateFile(configFile, uid).catch(e => { if (e.code === 'ENOENT') return undefined; throw e; });
  const unchanged = oldPlist === nextPlist && oldConfigText === JSON.stringify(config);
  let bootedOut = false, installed = false;
  try {
    if (loaded.status === 0 && !unchanged) { requireSuccess(run(['bootout', job])); bootedOut = true; }
    if (!unchanged) {
      if (oldConfigText !== undefined) await writePrivateFile(configFile + '.backup', oldConfigText, uid);
      await writePrivateFile(configFile, JSON.stringify(config), uid);
      await writePrivateFile(plistPath, nextPlist, uid);
    }
    if (loaded.status !== 0 || bootedOut) { requireSuccess(run(['bootstrap', domain, plistPath])); installed = true; }
    requireSuccess(run(['kickstart', job]));
    for (let i = 0; i < attempts; i++) { try { const status = await probe(config); if (typeof status.connected === 'boolean') return status; } catch {} await new Promise(r => setTimeout(r, delay)); }
    throw new Error('The desktop service did not become ready. Check the network and try Start service again.');
  } catch (error) {
    if (installed) run(['bootout', job]);
    if (!unchanged) {
      if (oldConfigText === undefined) await unlink(configFile).catch(() => {}); else await writePrivateFile(configFile, oldConfigText, uid);
      if (oldPlist === undefined) await unlink(plistPath).catch(() => {}); else await writePrivateFile(plistPath, oldPlist, uid);
      if (bootedOut && oldPlist) { run(['bootstrap', domain, plistPath]); run(['kickstart', job]); }
    }
    throw error;
  }
}
export async function uninstallService({ config, configFile, home=homedir(), uid=process.getuid?.(), run=runLaunchctl }) {
  validateMacConfig(config,uid);
  const plistPath=join(home,'Library','LaunchAgents',agentLabel+'.plist'),job=`gui/${uid}/${agentLabel}`;
  const content=await readPrivateFile(plistPath,uid);
  if(content!==launchAgent({...config,configFile},home))throw new Error('The LaunchAgent was modified. It was preserved.');
  const loaded=run(['print',job]);
  if(loaded.status===0){if(!ownsLoadedJob(loaded.stdout,config,configFile,plistPath))throw new Error('A foreign loaded service was preserved.');requireSuccess(run(['bootout',job]));}
  await unlink(plistPath);
  return {removed:true,pairingPreserved:true};
}
