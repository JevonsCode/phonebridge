import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, copyFile, symlink } from 'node:fs/promises';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir, networkInterfaces } from 'node:os';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { windowsIdentity, privateIPv4 } from '../network.mjs';
import { createMcpConfiguration } from '../server.mjs';
import { installMcpLauncher } from '../macos/mcp-launcher.mjs';
import { mcpTarget } from '../mcp-bootstrap.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const windows = process.platform === 'win32';
const uid = process.getuid?.();
const powershell = join(process.env.SystemRoot ?? '', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
const sessions = new WeakMap();
async function fixture(t) {
  const state = await mkdtemp(join(tmpdir(), 'phonebridge-mcp-'));
  sessions.set(t, []);
  t.after(async () => {
    for (const session of sessions.get(t)) { session.child.stdin.end(); try { await boundedExit(session); } finally { if (session.child.exitCode === null) session.child.kill(); } }
    await rm(state, { recursive: true, force: true });
  });
  await mkdir(join(state, 'bin'), { mode: 0o700 });
  const configFile = join(state, windows ? 'desktop.json' : 'desktop-macos.json');
  let launcher;
  if (windows) {
    launcher = join(state, 'bin', 'PhoneBridgeMcp.exe');
    if (process.env.PHONEBRIDGE_TEST_PACKAGE) await copyFile(join(process.env.PHONEBRIDGE_TEST_PACKAGE, 'PhoneBridgeMcp.exe'), launcher);
    else execFileSync(join(process.env.SystemRoot, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe'), ['/nologo', '/target:exe', '/reference:System.Web.Extensions.dll', '/out:' + launcher, join(root, 'desktop', 'McpLauncher.cs')], { windowsHide: true });
  } else launcher = await installMcpLauncher(state, uid);
  const config = { schema: windows ? 'phonebridge-desktop-v1' : 'phonebridge-macos-desktop-v1', ...(windows ? { ownerSid: windowsIdentity() } : { ownerUid: uid }), projectRoot: root, nodePath: process.execPath, hostAddress: '192.168.1.2', port: 8767, mcpLauncherPath: launcher };
  const save = value => writeFile(configFile, JSON.stringify(value), { mode: 0o600 });
  return { state, launcher, configFile, config, save };
}
function session(t, launcher) {
  const child = windows ? spawn(launcher, [], { stdio: 'pipe', windowsHide: true }) : spawn('/bin/sh', [launcher], { stdio: 'pipe' });
  let stderr = ''; child.stderr.on('data', data => { stderr += data; });
  const pending = new Map();
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => { let value; try { value = JSON.parse(line); } catch { assert.fail('Unexpected stdout: ' + line); } pending.get(value.id)?.(value); });
  const exit = new Promise(resolve => child.once('exit', (code, signal) => resolve({ code, signal })));
  sessions.get(t).push({child,exit});
  return { child, stderr: () => stderr, exit, async request(value) {
    let timer;
    try { return await Promise.race([new Promise(resolve => { pending.set(value.id, resolve); child.stdin.write(JSON.stringify(value) + '\n'); }), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('MCP response timed out; ' + stderr)), 10000); })]); }
    finally { clearTimeout(timer); pending.delete(value.id); }
  } };
}
async function boundedExit(s) { let timer;try {return await Promise.race([s.exit,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('MCP did not exit')),5000);})]);}finally{clearTimeout(timer);} }
async function fakePackage(state, name) {
  const folder = join(state, name); await mkdir(join(folder, 'bridge', 'dist'), { recursive: true });
  await writeFile(join(folder, 'bridge', 'dist', 'mcp.js'), `const readline=require('node:readline'); const label=${JSON.stringify(name)}; readline.createInterface({input:process.stdin}).on('line',line=>{const req=JSON.parse(line);if(req.method==='exit'){process.exit(23);}console.log(JSON.stringify({id:req.id,label,url:process.env.PHONEBRIDGE_URL,credential:process.env.PHONEBRIDGE_CREDENTIAL_FILE,tokenPresent:!!process.env.PHONEBRIDGE_TOKEN}));});`);
  if (!windows) { await mkdir(join(folder, 'runtime')); await copyFile(process.execPath, join(folder, 'runtime', 'node')); await mkdir(join(folder, 'desktop', 'macos'), { recursive: true }); for (const name of ['mcp-bootstrap.mjs','network.mjs']) await copyFile(join(root,'desktop',name),join(folder,'desktop',name)); for(const name of ['lifecycle.mjs','mcp-launcher.mjs'])await copyFile(join(root,'desktop','macos',name),join(folder,'desktop','macos',name)); }
  return folder;
}
test('stable launch selects current A/B target, endpoint and credential on reconnect; live A survives; stdio exit code propagates', { skip: !windows && process.platform !== 'darwin', timeout: 30000 }, async t => {
  const f = await fixture(t), a = await fakePackage(f.state, 'A'), b = await fakePackage(f.state, 'B');
  const configA = { ...f.config, projectRoot: a, nodePath: windows ? process.execPath : join(a,'runtime','node') };
  await f.save(configA);
  const first = session(t, f.launcher);
  assert.deepEqual(await first.request({id:1}), {id:1,label:'A',url:'http://192.168.1.2:8767',credential:join(f.state,'pairing.json'),tokenPresent:false});
  const configB = { ...configA, projectRoot: b, nodePath: windows ? process.execPath : join(b,'runtime','node'), hostAddress:'10.0.0.9',port:9876,credentialFile:join(f.state,'other-pairing.json') };
  await f.save(configB);
  const second=session(t,f.launcher);
  const result=await second.request({id:2});assert.equal(result.label,'B');assert.equal(result.url,'http://10.0.0.9:9876');assert.equal(result.credential,configB.credentialFile);
  assert.equal((await first.request({id:3})).label,'A');
  second.child.stdin.write(JSON.stringify({method:'exit'})+'\n');assert.equal((await boundedExit(second)).code,23);
  first.child.stdin.end();assert.equal((await boundedExit(first)).code,0);assert.equal(first.stderr(),'');assert.equal(second.stderr(),'');
  const copied=createMcpConfiguration(configB,configB.credentialFile,{configFile:f.configFile}).mcpServers.phonebridge;
  assert.equal(copied.command,windows?f.launcher:'/bin/sh');assert.equal('env' in copied,false);assert.doesNotMatch(JSON.stringify(copied),/versions|9876|TOKEN/);
});
test('invalid, missing and foreign owned config fail without stdout protocol noise', {skip:!windows && process.platform!=='darwin',timeout:30000},async t=>{
  const f=await fixture(t);
  for (const config of [undefined,{...f.config,port:0},{...f.config,hostAddress:'8.8.8.8'},{...f.config,...(windows?{ownerSid:'S-1-0-0'}:{ownerUid:uid+1})},{...f.config,nodePath:'relative'}]) {
    if(config)await f.save(config);
    const child=windows?spawn(f.launcher,[],{stdio:'pipe',windowsHide:true}):spawn('/bin/sh',[f.launcher],{stdio:'pipe'});
    let stdout='';child.stdout.on('data',b=>stdout+=b);const result=await new Promise(resolve=>child.on('exit',code=>resolve(code)));assert.equal(result,1);assert.equal(stdout,'');
  }
});
test('stable config is emitted only for an installed regular launcher; portable fallback remains explicit',async t=>{
  const f=await fixture(t);const config={...f.config};
  assert.equal(createMcpConfiguration(config,join(f.state,'pairing.json'),{configFile:f.configFile}).mcpServers.phonebridge.command,windows?f.launcher:'/bin/sh');
  assert.equal(createMcpConfiguration(config,join(f.state,'override.json'),{configFile:f.configFile}).mcpServers.phonebridge.command,config.nodePath);
  await rm(f.launcher);
  assert.equal(createMcpConfiguration(config,'/tmp/pairing.json',{configFile:f.configFile}).mcpServers.phonebridge.command,config.nodePath);
});
test('both platform configurations use direct runtime for custom config basenames', async t => {
  const f = await fixture(t), credential = join(f.state, 'pairing.json');
  for (const platform of ['win32', 'darwin']) {
    const launcher = join(f.state, 'bin', platform === 'darwin' ? 'phonebridge-mcp' : 'PhoneBridgeMcp.exe');
    if (launcher !== f.launcher) await writeFile(launcher, 'fixture');
    const config = { ...f.config, mcpLauncherPath: launcher };
    const canonicalName = platform === 'darwin' ? 'desktop-macos.json' : 'desktop.json';
    const canonical = createMcpConfiguration(config, credential, { platform, configFile: join(f.state, canonicalName) }).mcpServers.phonebridge;
    assert.equal(canonical.command, platform === 'darwin' ? '/bin/sh' : launcher);
    const custom = createMcpConfiguration(config, credential, { platform, configFile: join(f.state, 'custom-' + canonicalName) }).mcpServers.phonebridge;
    assert.equal(custom.command, config.nodePath);
    assert.deepEqual(custom.args, [join(config.projectRoot, 'bridge', 'dist', 'mcp.js')]);
    assert.equal(custom.env.PHONEBRIDGE_CREDENTIAL_FILE, credential);
    assert.equal(custom.env.PHONEBRIDGE_URL, `http://${config.hostAddress}:${config.port}`);
  }
});
test('Windows publication reuses a busy bootstrap; invalid new payload fails atomically', {skip:!windows,timeout:30000},async t=>{
  const f=await fixture(t),source=join(f.state,'source.exe');await copyFile(f.launcher,source);
  const a=await fakePackage(f.state,'A');await f.save({...f.config,projectRoot:a});const running=session(t,f.launcher);await running.request({id:1});
  const before=await readFile(f.launcher);
  const script=join(f.state,'publish.ps1');await writeFile(script,`param($Source,$State)\n$ErrorActionPreference='Stop'\n. '${join(root,'desktop','install-mcp-launcher.ps1').replaceAll("'","''")}'\nInstall-PhoneBridgeMcpLauncher -Source $Source -StateDirectory $State\n`);
  execFileSync(powershell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,source,f.state],{windowsHide:true});assert.deepEqual(await readFile(f.launcher),before);assert.equal((await running.request({id:2})).label,'A');
  const empty=join(f.state,'empty');await mkdir(empty);const oldConfig=await readFile(f.configFile);await writeFile(join(empty,'desktop.json'),oldConfig);const bad=join(f.state,'bad.exe');await writeFile(bad,'invalid');
  assert.throws(()=>execFileSync(powershell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',script,bad,empty],{windowsHide:true,stdio:'pipe'}));await assert.rejects(readFile(join(empty,'bin','PhoneBridgeMcp.exe')),/ENOENT/);assert.deepEqual(await readFile(f.launcher),before);
  assert.deepEqual(await readFile(join(empty,'desktop.json')),oldConfig);assert.equal((await running.request({id:3})).label,'A');
  running.child.stdin.end();await boundedExit(running);
});
test('real packaged MCP initialize and tools/list survive active config upgrade', {skip:!windows && process.platform!=='darwin',timeout:30000},async t=>{
  const f=await fixture(t),packageRoot=resolve(process.env.PHONEBRIDGE_TEST_PACKAGE??root);
  const { loadOrCreateSavedToken }=await import(new URL('../../bridge/dist/credentials.js',import.meta.url));
  await loadOrCreateSavedToken(join(f.state,'pairing.json'));
  const host=Object.values(networkInterfaces()).flat().find(net=>net.family==='IPv4'&&privateIPv4(net.address))?.address;
  assert.ok(host,'A local private address is needed by the real MCP adapter');
  const nodePath=process.env.PHONEBRIDGE_TEST_PACKAGE?join(packageRoot,'runtime',windows?'node.exe':'node'):process.execPath;
  // Two installation roots reference the same verified runtime payload; neither touches live state.
  const a=join(f.state,'package-A'),b=join(f.state,'package-B');
  for(const folder of [a,b]) { await mkdir(folder);await symlink(join(packageRoot,'bridge'),join(folder,'bridge'),windows?'junction':'dir');if(!windows){await mkdir(join(folder,'runtime'));await copyFile(nodePath,join(folder,'runtime','node'));await symlink(join(packageRoot,'desktop'),join(folder,'desktop'),'dir');} }
  const config={...f.config,projectRoot:a,nodePath:windows?nodePath:join(a,'runtime','node'),hostAddress:host};await f.save(config);
  const first=session(t,f.launcher);const initialize={jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'isolated-test',version:'1'}}};
  assert.equal((await first.request(initialize)).result.serverInfo.name,'phonebridge');
  await f.save({...config,projectRoot:b,nodePath:windows?nodePath:join(b,'runtime','node'),port:9876});
  const second=session(t,f.launcher);assert.equal((await second.request(initialize)).result.serverInfo.name,'phonebridge');
  for(const s of [first,second]) { const list=await s.request({jsonrpc:'2.0',id:2,method:'tools/list',params:{}});assert.ok(list.result.tools.some(tool=>tool.name==='phone_state'));s.child.stdin.end();assert.equal((await boundedExit(s)).code,0);assert.equal(s.stderr(),''); }
});
test('POSIX launcher publication is idempotent and refuses modified scripts; bootstrap validates current config', {skip:windows},async t=>{
  const f=await fixture(t),a=await fakePackage(f.state,'A');const config={...f.config,projectRoot:a,nodePath:join(a,'runtime','node')};await f.save(config);
  assert.equal(await installMcpLauncher(f.state,uid),f.launcher);assert.equal((await mcpTarget(f.configFile,uid)).env.PHONEBRIDGE_URL,'http://192.168.1.2:8767');
  await writeFile(f.launcher,'foreign',{mode:0o700});await assert.rejects(installMcpLauncher(f.state,uid),/unrecognized/);assert.equal(await readFile(f.launcher,'utf8'),'foreign');
});
