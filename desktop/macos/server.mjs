import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import { writeFile, lstat, readFile } from 'node:fs/promises';
import { createDashboard, createMcpConfiguration, authenticatedStatus, nativeReady } from '../server.mjs';
import { serializeNetworkChange } from '../network-transaction.mjs';
import { macConfigPath, macNetworks, macRuntimeRevision, privateDirectory, readMacConfig, validateInstalledApp, installService, uninstallService } from './lifecycle.mjs';
import { loadOrCreateSavedToken, credentialPath } from '../../bridge/dist/credentials.js';
import { pairingUri } from '../../bridge/dist/pairing.js';
import QRCode from '../../bridge/node_modules/qrcode/lib/index.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export async function main(args = process.argv.slice(2)) {
  if (args.includes('--report-path') && !args.includes('--diagnose')) throw new Error('--report-path requires --diagnose.');
  if (args.includes('--self-test')) {
    const result = spawnSync(process.execPath, ['--test', join(root, 'desktop', 'test', 'macos.test.mjs')], { encoding: 'utf8', timeout: 60000, maxBuffer: 1048576 });
    if (result.status !== 0) throw new Error('Isolated desktop self-test failed.');
    console.log(JSON.stringify({ passed: true, isolated: true, platform: `darwin-${process.arch}` })); return;
  }
  if (process.platform !== 'darwin') throw new Error('This client requires macOS.');
  const path = resolve(macConfigPath()), uid = process.getuid();
  let config; try { config = await readMacConfig(path, uid); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  if(args.includes('--uninstall-service')) { if(!config)throw new Error('No owned Mac service configuration exists.');console.log(JSON.stringify(await uninstallService({config,configFile:path,uid})));return; }
  if (args.includes('--diagnose')) {
    const manifest=JSON.parse(await readFile(join(root,'package-manifest.json'),'utf8').catch(e=>{if(e.code==='ENOENT')return '{}';throw e;}));
    const report=JSON.stringify({ product:'PhoneBridge', version:manifest.version??'0.6.2-preview', platform:`darwin-${process.arch}`, runtime:process.version, existingOwnedConfig:!!config, privateNetworks:macNetworks().length, dryRun:true });
    if (args.includes('--report-path')) { const destination=args[args.indexOf('--report-path')+1];if(!destination || resolve(destination)!==destination)throw new Error('Use an absolute report path.');const info=await lstat(destination).catch(e=>{if(e.code==='ENOENT')return undefined;throw e;});if(info && (!info.isFile()||info.isSymbolicLink()))throw new Error('Invalid diagnostic report file.');await writeFile(destination,report+'\n',{mode:0o600}); }
    console.log(report);return;
  }
  await validateInstalledApp(root);
  await privateDirectory(dirname(path), uid);
  await privateDirectory(join(homedir(), '.phonebridge'), uid);
  let saved = config;
  if (!config) { const network = macNetworks()[0]; if (!network) throw new Error('Connect to a private Wi-Fi or Ethernet network.'); config = {schema:'phonebridge-macos-desktop-v1',ownerUid:uid,projectRoot:root,nodePath:process.execPath,hostAddress:network.address,port:8767}; }
  // Upgrading the App keeps the credential and logs; only our owned job can be refreshed.
  config = { ...config, projectRoot: root, nodePath: process.execPath, credentialFile: config.credentialFile ?? credentialPath(), runtimeRevision: await macRuntimeRevision(root) };
  const token = await loadOrCreateSavedToken(config.credentialFile);
  let errorMessage, starting;
  const start = () => {
    if (starting) return starting;
    starting = (async () => {
      if (!macNetworks().some(net => net.address === config.hostAddress)) throw new Error('The saved network is unavailable. Select your current network.');
      // A non-owned/occupied endpoint is never stopped. Registration checks exact job ownership.
      const current = await authenticatedStatus(config, token).catch(() => undefined);
      if (current?.connected && saved && (saved.projectRoot !== config.projectRoot || saved.nodePath !== config.nodePath || saved.runtimeRevision !== config.runtimeRevision)) throw new Error('Disconnect the phone before moving or upgrading the desktop App.');
      const result = await installService({ config, previous:saved, configFile:path, probe: next => authenticatedStatus(next,token) });
      config.mcpLauncherPath = join(dirname(path), 'bin', 'phonebridge-mcp');
      saved = { ...config }; errorMessage = undefined; return result;
    })().catch(error => { errorMessage=error.message; throw error; }).finally(() => { starting=undefined; });
    return starting;
  };
  const dashboard = await createDashboard({ config, token, networks:macNetworks, status:()=>authenticatedStatus(config,token), startService:start,
    changeNetwork:serializeNetworkChange(async address => {
      if (!macNetworks().some(net => net.address === address)) throw new Error('Select an active private network.');
      if (address === config.hostAddress) { await start(); return; }
      if (starting) throw new Error('The service is starting. Please wait.');
      const current = await authenticatedStatus(config,token).catch(()=>undefined);
      if (current?.connected) throw new Error('Disconnect the phone before changing networks.');
      const previousAddress = config.hostAddress; config.hostAddress=address;
      try { await start(); } catch(error) {config.hostAddress=previousAddress;throw error;}
    }), language:process.env.LANG?.startsWith('zh')?'zh':'en',
    qr:()=>QRCode.toDataURL(pairingUri(`ws://${config.hostAddress}:${config.port}/device`,token),{width:360,margin:3}),
    mcpConfiguration:()=>createMcpConfiguration(config,config.credentialFile),startupError:()=>errorMessage });
  if (!args.includes('--native-window') && !args.includes('--no-open')) spawn('/usr/bin/open',[dashboard.url],{stdio:'ignore'}).unref();
  console.log(JSON.stringify(nativeReady(args,dashboard.url)));
  void start().catch(()=>{});
  let stopping=false;
  const stop=async()=>{if(stopping)return;stopping=true;await dashboard.close();};
  process.on('SIGINT',()=>void stop());process.on('SIGTERM',()=>void stop());
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(error => {
  // The native frontend consumes stdout; stderr alone leaves it with a generic EOF error.
  if (process.argv.includes('--native-window')) console.log(JSON.stringify({ ready: false, error: error.message }));
  console.error(error.message);
  process.exitCode = 1;
});
