import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { windowsIdentity, localNetworks } from './network.mjs';
const root=process.argv[2] ? resolve(process.argv[2]) : resolve(dirname(fileURLToPath(import.meta.url)),'..');
const temp=await mkdtemp(join(tmpdir(),'phonebridge-client-test-'));
const reserve=createServer();await new Promise(r=>reserve.listen(0,'127.0.0.1',r));const port=reserve.address().port;await new Promise(r=>reserve.close(r));
const path=join(temp,'desktop.json');const config={schema:'phonebridge-desktop-v1',ownerSid:windowsIdentity(),projectRoot:root,nodePath:process.execPath,hostAddress:'127.0.0.1',port,launcherPath:join(root,'scripts','windows','run-desktop.ps1'),powershellPath:process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'};
await writeFile(path,JSON.stringify(config));
const env={...process.env,PATH:join(process.env.SystemRoot,'System32'),PHONEBRIDGE_DESKTOP_CONFIG:path,PHONEBRIDGE_CREDENTIAL_FILE:join(temp,'pairing.json'),PHONEBRIDGE_LOG_FILE:join(temp,'operations.jsonl'),PHONEBRIDGE_DESKTOP_TEST:'1',PHONEBRIDGE_TOKEN:undefined};
const children=new Set();
const launch=(native=false,launchEnv=env)=>{const child=spawn(process.execPath,[join(root,'desktop','server.mjs'),native?'--native-window':'--no-open'],{env:launchEnv,stdio:['ignore','pipe','pipe'],windowsHide:true});children.add(child);return child;};
const exited=child=>child.exitCode!==null||child.signalCode!==null?Promise.resolve(child.exitCode):new Promise(r=>child.once('exit',r));
const ready=child=>new Promise((resolve,reject)=>{let out='',err='';const timer=setTimeout(()=>reject(new Error('Isolated client startup timed out')),30000);child.stdout.on('data',chunk=>{out+=chunk;if(out.includes('\n')){clearTimeout(timer);resolve(JSON.parse(out.trim().split('\n')[0]))}});child.stderr.on('data',chunk=>err+=chunk);child.once('exit',code=>{if(!out){clearTimeout(timer);reject(new Error('Isolated client startup failed: '+err))}})});
let first,url;
try {
  first=launch(true);const initial=await ready(first);assert.equal(initial.ready,true);assert.match(initial.dashboardUrl,/^http:\/\/127\.0\.0\.1:\d+\/session\/[A-Za-z0-9_-]{32}$/);
  const configBefore=await readFile(path,'utf8');const pairingBefore=await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8');
  const stateFile=(await readdir(temp)).find(n=>/^client-.*\.json$/.test(n));const state=JSON.parse(await readFile(join(temp,stateFile),'utf8'));url=new URL(state.url);
  let status;for(let attempt=0;attempt<50;attempt++){status=await (await fetch(url+'/status')).json();if(!status.unavailable)break;await new Promise(r=>setTimeout(r,200));}assert.equal(status.unavailable,false);assert.equal(status.connected,false);
  const launcher=spawn(join(root,'PhoneBridge.exe'),['--no-open'],{env,windowsHide:true,stdio:'ignore'});assert.equal(await new Promise(r=>launcher.once('exit',r)),0);assert.equal(JSON.parse(await readFile(join(temp,stateFile),'utf8')).pid,state.pid);
  const second=launch();const standard=await ready(second);assert.equal(standard.reusedClient,true);assert.equal('dashboardUrl' in standard,false);await exited(second);
  const native=launch(true);const reused=await ready(native);assert.equal(reused.reusedClient,true);assert.equal(reused.dashboardUrl,initial.dashboardUrl);await exited(native);
  assert.equal((await fetch(url+'/status')).status,200);
  assert.equal(await readFile(path,'utf8'),configBefore);assert.equal(await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8'),pairingBefore);
  // A stale state is replaceable only when the original client is no longer alive.
  const shutdown=await fetch(url+'/shutdown',{method:'POST',headers:{Origin:url.origin,'X-PhoneBridge-CSRF':url.pathname.split('/').pop()}});assert.equal(shutdown.status,200);
  await exited(first);first=undefined;
  await writeFile(join(temp,stateFile),JSON.stringify({...state,pid:2147483647}));await writeFile(join(temp,stateFile+'.lock'),'2147483647');
  const racers=[launch(true),launch(true)];const results=await Promise.all(racers.map(ready));assert.equal(results.every(r=>r.ready&&r.dashboardUrl),true);assert.equal(results.filter(r=>r.reusedClient).length,1);assert.equal(results[0].dashboardUrl,results[1].dashboardUrl);
  first=racers[results.findIndex(r=>!r.reusedClient)];await exited(racers.find(child=>child!==first));
  const fresh=JSON.parse(await readFile(join(temp,stateFile),'utf8'));assert.notEqual(fresh.pid,state.pid);url=new URL(fresh.url);
  assert.equal(await readFile(path,'utf8'),configBefore);assert.equal(await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8'),pairingBefore);
  // Real LAN listeners on random ports trigger Windows firewall consent for each
  // new package path. Keep ordinary local validation on loopback; CI or an
  // explicitly requested LAN check can opt in without changing firewall policy.
  const testLan=process.env.PHONEBRIDGE_TEST_LAN==='1';
  const active=testLan?localNetworks().find(network=>network.physical===true&&!/vpn|tailscale|wireguard|tap|tun|virtual|vethernet|docker|hyper-v/i.test(network.name)):undefined;
  if(active){
    await fetch(url+'/shutdown',{method:'POST',headers:{Origin:url.origin,'X-PhoneBridge-CSRF':url.pathname.split('/').pop()}});await exited(first);first=undefined;
    const recoveryPath=join(temp,'network-recovery.json'),unavailable=localNetworks().some(n=>n.address==='192.168.254.254')?'10.253.254.254':'192.168.254.254';
    const recoveryConfig={...config,hostAddress:unavailable};await writeFile(recoveryPath,JSON.stringify(recoveryConfig));
    first=launch(true,{...env,PHONEBRIDGE_DESKTOP_CONFIG:recoveryPath});url=new URL((await ready(first)).dashboardUrl);
    // A saved address which left this computer recovers without a network-selection request.
    // Wait for both a working listener and the committed configuration, then verify
    // that every field apart from the address and the remembered pairing survived.
    let recovered;const deadline=Date.now()+30000;
    while(Date.now()<deadline){recovered=await(await fetch(url+'/status')).json();if(!recovered.unavailable&&recovered.address===active.address)break;await new Promise(r=>setTimeout(r,200));}
    assert.equal(recovered.unavailable,false,`Automatic network recovery failed: ${recovered.error??'service unavailable'}`);assert.equal(recovered.error,undefined);assert.equal(recovered.address,active.address);
    assert.deepEqual(JSON.parse(await readFile(recoveryPath,'utf8')),{...recoveryConfig,hostAddress:active.address});assert.equal(recovered.port,config.port);assert.equal(await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8'),pairingBefore);
  }
  console.log('LAN network recovery: '+(active?'automatic recovery passed':testLan?'skipped (no physical private adapter)':'skipped (opt in with PHONEBRIDGE_TEST_LAN=1)'));
  console.log('Isolated Windows client integration passed: preserved identity, live supervisor, fresh/reused/concurrent native ready, no URL in ordinary output, stale state recovery.');
} finally {
  if(first&&url){try{await fetch(url+'/shutdown',{method:'POST',headers:{Origin:url.origin,'X-PhoneBridge-CSRF':url.pathname.split('/').pop()}});await exited(first);}catch{}}
  for(const child of children){if(child.exitCode===null&&child.signalCode===null){child.kill();await exited(child);}}
  await rm(temp,{recursive:true,force:true});
}
