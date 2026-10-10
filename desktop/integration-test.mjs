import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { windowsIdentity } from './network.mjs';
const root=process.argv[2] ? resolve(process.argv[2]) : resolve(dirname(fileURLToPath(import.meta.url)),'..');
const temp=await mkdtemp(join(tmpdir(),'phonebridge-client-test-'));
const reserve=createServer();await new Promise(r=>reserve.listen(0,'127.0.0.1',r));const port=reserve.address().port;await new Promise(r=>reserve.close(r));
const path=join(temp,'desktop.json');const config={schema:'phonebridge-desktop-v1',ownerSid:windowsIdentity(),projectRoot:root,nodePath:process.execPath,hostAddress:'127.0.0.1',port,launcherPath:join(root,'scripts','windows','run-desktop.ps1'),powershellPath:process.env.SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'};
await writeFile(path,JSON.stringify(config));
const env={...process.env,PATH:join(process.env.SystemRoot,'System32'),PHONEBRIDGE_DESKTOP_CONFIG:path,PHONEBRIDGE_CREDENTIAL_FILE:join(temp,'pairing.json'),PHONEBRIDGE_DESKTOP_TEST:'1',PHONEBRIDGE_TOKEN:undefined};
const launch=()=>spawn(process.execPath,[join(root,'desktop','server.mjs'),'--no-open'],{env,stdio:['ignore','pipe','pipe'],windowsHide:true});
const ready=child=>new Promise((resolve,reject)=>{let out='',err='';const timer=setTimeout(()=>reject(new Error('Isolated client startup timed out')),30000);child.stdout.on('data',chunk=>{out+=chunk;if(out.includes('\n')){clearTimeout(timer);resolve(JSON.parse(out.trim().split('\n')[0]))}});child.stderr.on('data',chunk=>err+=chunk);child.once('exit',code=>{if(!out){clearTimeout(timer);reject(new Error('Isolated client startup failed: '+err))}})});
let first,url;
try {
  first=launch();assert.equal((await ready(first)).ready,true);
  const configBefore=await readFile(path,'utf8');const pairingBefore=await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8');
  const stateFile=(await readdir(temp)).find(n=>/^client-.*\.json$/.test(n));const state=JSON.parse(await readFile(join(temp,stateFile),'utf8'));url=new URL(state.url);
  const status=await (await fetch(url+'/status')).json();assert.equal(status.unavailable,false);assert.equal(status.connected,false);
  const launcher=spawn(join(root,'PhoneBridge.exe'),['--no-open'],{env,windowsHide:true,stdio:'ignore'});assert.equal(await new Promise(r=>launcher.once('exit',r)),0);assert.equal(JSON.parse(await readFile(join(temp,stateFile),'utf8')).pid,state.pid);
  const second=launch();assert.equal((await ready(second)).reusedClient,true);await new Promise(r=>second.once('exit',r));
  assert.equal(await readFile(path,'utf8'),configBefore);assert.equal(await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8'),pairingBefore);
  // A stale state is replaceable only when the original client is no longer alive.
  const shutdown=await fetch(url+'/shutdown',{method:'POST',headers:{Origin:url.origin,'X-PhoneBridge-CSRF':url.pathname.split('/').pop()}});assert.equal(shutdown.status,200);
  await new Promise(r=>first.once('exit',r));first=undefined;
  await writeFile(join(temp,stateFile),JSON.stringify({...state,pid:2147483647}));await writeFile(join(temp,stateFile+'.lock'),'2147483647');
  first=launch();assert.equal((await ready(first)).ready,true);
  const fresh=JSON.parse(await readFile(join(temp,stateFile),'utf8'));assert.notEqual(fresh.pid,state.pid);url=new URL(fresh.url);
  assert.equal(await readFile(path,'utf8'),configBefore);assert.equal(await readFile(env.PHONEBRIDGE_CREDENTIAL_FILE,'utf8'),pairingBefore);
  console.log('Isolated Windows client integration passed: PATH without Node/PowerShell, existing config and DPAPI identity retained, live supervisor, duplicate launch reuse, stale state recovery.');
} finally {
  if(first&&url){try{await fetch(url+'/shutdown',{method:'POST',headers:{Origin:url.origin,'X-PhoneBridge-CSRF':url.pathname.split('/').pop()}});await new Promise(r=>first.once('exit',r));}catch{}}
  await rm(temp,{recursive:true,force:true});
}
