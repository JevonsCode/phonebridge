import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, chmod, symlink, rm, realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { validateMacConfig, macNetworks, launchAgent, installService, readMacConfig, privateDirectory, readPrivateFile, validateInstalledApp, uninstallService } from '../macos/lifecycle.mjs';
import { nativeReady, createDashboard, authenticatedStatus, createMcpConfiguration } from '../server.mjs';
import { DesktopSupervisor } from '../../bridge/dist/supervisor.js';

const uid = process.getuid?.() ?? 501;
const configFor = root => ({schema:'phonebridge-macos-desktop-v1',ownerUid:uid,projectRoot:root,nodePath:join(root,'runtime','node'),hostAddress:'192.168.1.2',port:8767});
const posix = {skip:process.platform==='win32'};
async function fixture(t) {
  const home=await realpath(await mkdtemp(join(tmpdir(),'phonebridge-mac-')));
  t.after(()=>rm(home,{recursive:true,force:true}));
  await privateDirectory(join(home,'.phonebridge'),uid);
  return {home,configFile:join(home,'.phonebridge','desktop-macos.json'),config:configFor(join(home,'Applications','PhoneBridge.app','Contents','Resources'))};
}
function fakeLaunchctl() {
  let loaded=false,path,argv; const calls=[];
  return { calls, run(args) { calls.push(args); if(args[0]==='print')return {status:loaded?0:113,stdout:loaded?`job {\n path = ${path}\n program = ${argv[0]}\n arguments = {\n${argv.join('\n')}\n }\n}`:''};
    if(args[0]==='bootstrap'){loaded=true;path=args[2];const block=/<key>ProgramArguments<\/key><array>(.*?)<\/array>/.exec(readFileSync(path,'utf8'))[1];argv=[...block.matchAll(/<string>(.*?)<\/string>/g)].map(m=>m[1].replaceAll('&amp;','&').replaceAll('&lt;','<').replaceAll('&gt;','>').replaceAll('&quot;','"').replaceAll('&apos;',"'"));} if(args[0]==='bootout')loaded=false;return {status:0,stdout:''}; } };
}
test('native readiness includes URL only for native pipe, with strict session identity',()=>{
  const url='http://127.0.0.1:4567/session/'+ 'a'.repeat(32);
  for(const fields of [{reusedClient:true},{reusedService:true},{}]){
    assert.equal(nativeReady(['--native-window'],url,fields).dashboardUrl,url);
    assert.equal('dashboardUrl' in nativeReady(['--no-open'],url,fields),false);
  }
  for(const bad of [url+'?x=1',url+'#x',url.replace('127.0.0.1','localhost'),url.replace('http:','https:'),url.replace('127.0.0.1','evil.com'),url.replace('/session/','/other/'),'http://a@127.0.0.1:4567/session/'+'a'.repeat(32)])assert.throws(()=>nativeReady(['--native-window'],bad));
});
test('macOS network selection prefers active physical LAN and avoids VPN',()=>{
  const item=address=>({address,family:'IPv4',internal:false});
  const selected=macNetworks({utun2:[item('10.0.0.1')],en0:[item('192.168.1.4')],lo0:[{...item('127.0.0.1'),internal:true}],en1:[item('8.8.8.8')]},'utun2');
  assert.equal(selected[0].name,'en0');assert.equal(selected.length,2);
});
test('Mac configuration enforces UID, LAN address, bundled runtime; plist escapes paths',()=>{
  const config=configFor('/Applications/PhoneBridge.app/Contents/Resources');
  assert.equal(validateMacConfig(config,uid),config);
  for(const changed of [{ownerUid:uid+1},{hostAddress:'8.8.8.8'},{nodePath:'/tmp/node'},{projectRoot:'relative'},{port:0}])assert.throws(()=>validateMacConfig({...config,...changed},uid));
  const plist=launchAgent({...config,configFile:'/Users/a&b/.phonebridge/desktop-macos.json'},'/Users/a&b');
  assert.match(plist,/a&amp;b/); assert.match(plist,/<key>KeepAlive<\/key><true\/>/);assert.doesNotMatch(plist,/Bearer|token|pairing/);
  const mcp=JSON.stringify(createMcpConfiguration(config,'/Users/a/.phonebridge/pairing.json'));
  assert.match(mcp,/PHONEBRIDGE_CREDENTIAL_FILE/);assert.doesNotMatch(mcp,/PHONEBRIDGE_TOKEN/);
});
test('private state refuses foreign permissions and symlinks, reads same UID only',posix,async t=>{
  const f=await fixture(t);await writeFile(f.configFile,JSON.stringify(f.config),{mode:0o600});
  assert.deepEqual(await readMacConfig(f.configFile,uid),f.config);
  await chmod(f.configFile,0o644);await assert.rejects(readMacConfig(f.configFile,uid));
  await chmod(f.configFile,0o600);await symlink(f.configFile,f.configFile+'.link');await assert.rejects(readPrivateFile(f.configFile+'.link',uid));
  await assert.rejects(readMacConfig(f.configFile,uid+1));
});
test('production App location validator reads the same package manifest as packaging',posix,async t=>{
  const f=await fixture(t),resources=f.config.projectRoot;await mkdir(resources,{recursive:true});
  await writeFile(join(resources,'package-manifest.json'),JSON.stringify({product:'PhoneBridge',platform:'darwin-arm64'}));
  assert.equal(await validateInstalledApp(resources,f.home),resources);
  await assert.rejects(validateInstalledApp(join(f.home,'Downloads','PhoneBridge.app','Contents','Resources'),f.home),/Applications/);
  await writeFile(join(resources,'package-manifest.json'),JSON.stringify({product:'Foreign',platform:'darwin-arm64'}));await assert.rejects(validateInstalledApp(resources,f.home),/Invalid/);
});
test('first registration and repeat opening retain configuration and owned job',posix,async t=>{
  const f=await fixture(t),ctl=fakeLaunchctl();
  await installService({...f,uid,run:ctl.run,probe:async()=>({connected:false}),attempts:1,delay:0});
  const before=await readFile(f.configFile,'utf8');
  await installService({...f,previous:f.config,uid,run:ctl.run,probe:async()=>({connected:false}),attempts:1,delay:0});
  assert.equal(await readFile(f.configFile,'utf8'),before);
  assert.equal(ctl.calls.filter(a=>a[0]==='bootstrap').length,1);
  assert.equal(ctl.calls.some(a=>a[0]==='bootout'),false);
});
test('modified plist and foreign loaded job are never changed or stopped',posix,async t=>{
  const f=await fixture(t);await mkdir(join(f.home,'Library','LaunchAgents'),{recursive:true});
  const plist=join(f.home,'Library','LaunchAgents','dev.phonebridge.desktop.plist');await writeFile(plist,'foreign',{mode:0o600});
  const ctl=fakeLaunchctl();await assert.rejects(installService({...f,uid,run:ctl.run,probe:async()=>({connected:false})}),/modified/);
  assert.equal(await readFile(plist,'utf8'),'foreign');assert.equal(ctl.calls.length,0);
  await rm(plist);const calls=[];const run=args=>{calls.push(args);return {status:0,stdout:'path = /some/other/job.plist'};};
  await assert.rejects(installService({...f,uid,run,probe:async()=>({connected:false})}),/foreign/);assert.deepEqual(calls.map(a=>a[0]),['print']);
  await writeFile(plist,launchAgent({...f.config,configFile:f.configFile},f.home),{mode:0o600});
  const samePathCalls=[],foreign=args=>{samePathCalls.push(args);return {status:0,stdout:`path = ${plist}\nprogram = /foreign/node\narguments = {\n/foreign/node\n}`};};
  await assert.rejects(installService({...f,uid,run:foreign,probe:async()=>({connected:false})}),/foreign/);assert.deepEqual(samePathCalls.map(a=>a[0]),['print']);
});
test('existing symlink logs are preserved before starting any job',posix,async t=>{
  const f=await fixture(t),target=join(f.home,'preserved');await writeFile(target,'original',{mode:0o600});await symlink(target,join(f.home,'.phonebridge','macos-service.stderr.log'));
  const ctl=fakeLaunchctl();await assert.rejects(installService({...f,uid,run:ctl.run,probe:async()=>({connected:false})}),/private file/);assert.equal(await readFile(target,'utf8'),'original');assert.deepEqual(ctl.calls.map(a=>a[0]),['print']);
});
test('failed network update restores old configuration and loaded LaunchAgent',posix,async t=>{
  const f=await fixture(t),ctl=fakeLaunchctl();await installService({...f,uid,run:ctl.run,probe:async()=>({connected:false}),attempts:1,delay:0});
  const old=await readFile(f.configFile,'utf8');const next={...f.config,hostAddress:'192.168.1.9'};
  await assert.rejects(installService({...f,config:next,previous:f.config,uid,run:ctl.run,probe:async()=>{throw new Error('occupied');},attempts:1,delay:0}),/did not become ready/);
  assert.equal(await readFile(f.configFile,'utf8'),old);
  assert.equal(await readFile(join(f.home,'Library','LaunchAgents','dev.phonebridge.desktop.plist'),'utf8'),launchAgent({...f.config,configFile:f.configFile},f.home));
  assert.equal(ctl.calls.filter(a=>a[0]==='bootstrap').length,3);
});
test('unchanged files with unloaded job roll back a failed bootstrap',posix,async t=>{
  const f=await fixture(t);await mkdir(join(f.home,'Library','LaunchAgents'),{recursive:true});
  const plist=join(f.home,'Library','LaunchAgents','dev.phonebridge.desktop.plist');
  const configText=JSON.stringify(f.config),plistText=launchAgent({...f.config,configFile:f.configFile},f.home);
  await writeFile(f.configFile,configText,{mode:0o600});await writeFile(plist,plistText,{mode:0o600});
  const ctl=fakeLaunchctl();await assert.rejects(installService({...f,previous:f.config,uid,run:ctl.run,probe:async()=>{throw new Error('not ready');},attempts:1,delay:0}));
  assert.deepEqual(ctl.calls.filter(a=>['bootstrap','bootout'].includes(a[0])).map(a=>a[0]),['bootstrap','bootout']);
  assert.equal(await readFile(f.configFile,'utf8'),configText);assert.equal(await readFile(plist,'utf8'),plistText);
});
test('uninstall removes only the verified owned job and preserves config and pairing',posix,async t=>{
  const f=await fixture(t),ctl=fakeLaunchctl();await installService({...f,uid,run:ctl.run,probe:async()=>({connected:false}),attempts:1,delay:0});
  const pairing=join(f.home,'.phonebridge','pairing.json');await writeFile(pairing,'preserved',{mode:0o600});const before=await readFile(f.configFile,'utf8');
  assert.equal((await uninstallService({...f,uid,run:ctl.run})).pairingPreserved,true);
  assert.equal(await readFile(pairing,'utf8'),'preserved');assert.equal(await readFile(f.configFile,'utf8'),before);
  await assert.rejects(readFile(join(f.home,'Library','LaunchAgents','dev.phonebridge.desktop.plist')),/ENOENT/);
});
test('native dashboard actual HTTP contract refuses mutation without CSRF and keeps service independent',async t=>{
  const config={...configFor('/Applications/PhoneBridge.app/Contents/Resources'),hostAddress:'127.0.0.1'};
  let starts=0;const dash=await createDashboard({config,networks:()=>[{name:'en0',address:'192.168.1.3'}],status:async()=>({connected:false}),startService:async()=>{starts++;},changeNetwork:async()=>{},qr:async()=> 'data:image/png;base64,fixture',mcpConfiguration:()=>createMcpConfiguration(config,'/tmp/pairing.json'),startupError:()=> 'Select network'});
  t.after(()=>dash.close()); const status=await (await fetch(dash.url+'/status')).json();assert.equal(status.error,'Select network');assert.equal(status.networks[0].name,'en0');
  assert.equal((await fetch(dash.url+'/start',{method:'POST'})).status,403);
  assert.equal((await fetch(dash.url+'/start',{method:'POST',headers:{Origin:new URL(dash.url).origin,'X-PhoneBridge-CSRF':dash.secret}})).status,200);assert.equal(starts,1);
});
test('isolated real Supervisor remains ready after dashboard closes and rejects occupied port',async t=>{
  const listener=createServer();await new Promise(r=>listener.listen(0,'127.0.0.1',r));const port=listener.address().port;await new Promise(r=>listener.close(r));
  const token=randomBytes(32).toString('base64url'),config={hostAddress:'127.0.0.1',port};const service=new DesktopSupervisor({token,host:'127.0.0.1',port,allowLan:true});
  await service.start();t.after(()=>service.close());assert.equal(service.serviceRunning,true);
  const status=await authenticatedStatus(config,token);assert.equal(status.connected,false);
  const dash=await createDashboard({config,networks:()=>[],status:()=>authenticatedStatus(config,token),startService:async()=>{},changeNetwork:async()=>{},qr:async()=>''});await dash.close();assert.equal((await authenticatedStatus(config,token)).connected,false);
  const other=new DesktopSupervisor({token,host:'127.0.0.1',port,allowLan:true});await assert.rejects(other.start(),/EADDRINUSE/);
});
