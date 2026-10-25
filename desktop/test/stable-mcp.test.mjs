import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, copyFile, cp, symlink, realpath } from 'node:fs/promises';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir, networkInterfaces } from 'node:os';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
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
  const state = await realpath(await mkdtemp(join(tmpdir(), 'phonebridge-mcp-')));
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
  const save = async value => {
    await writeFile(configFile, JSON.stringify(value), { mode: 0o600 });
    if (windows && process.env.CI) {
      const probe = `param($Path) $i=[Security.Principal.WindowsIdentity]::GetCurrent(); $owner=[IO.File]::GetAccessControl($Path).GetOwner([Security.Principal.SecurityIdentifier]).Value; @{fileOwnerMatchesUser=($owner -eq $i.User.Value);fileOwnerMatchesDefaultTokenOwner=($owner -eq $i.Owner.Value);defaultOwnerIsUser=($i.Owner.Value -eq $i.User.Value)} | ConvertTo-Json -Compress`;
      const probeFile = join(state, 'owner-probe.ps1'); await writeFile(probeFile, probe);
      t.diagnostic('Windows fixture ownership: ' + execFileSync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', probeFile, configFile], { encoding: 'utf8', windowsHide: true }).trim());
    }
  };
  return { state, launcher, configFile, config, save };
}
function session(t, launcher) {
  const child = windows ? spawn(launcher, [], { stdio: 'pipe', windowsHide: true }) : spawn('/bin/sh', [launcher], { stdio: 'pipe' });
  let stderr = ''; child.stderr.on('data', data => { stderr += data; });
  const pending = new Map();
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => { let value; try { value = JSON.parse(line); } catch { assert.fail('Unexpected stdout: ' + line); } pending.get(value.id)?.(value); });
  const exit = new Promise(resolve => child.once('close', (code, signal) => resolve({ code, signal })));
  sessions.get(t).push({child,exit});
  return { child, stderr: () => stderr, exit, async request(value) {
    let timer;
    try { return await Promise.race([new Promise(resolve => { pending.set(value.id, resolve); child.stdin.write(JSON.stringify(value) + '\n'); }), exit.then(({code,signal}) => { throw new Error(`MCP exited before response (code=${code}, signal=${signal}); ${stderr}`); }), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('MCP response timed out; ' + stderr)), 10000); })]); }
    finally { clearTimeout(timer); pending.delete(value.id); }
  } };
}
async function boundedExit(s) { let timer;try {return await Promise.race([s.exit,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('MCP did not exit')),5000);})]);}finally{clearTimeout(timer);} }
async function fakePackage(state, name) {
  const folder = join(state, name); await mkdir(join(folder, 'bridge', 'dist'), { recursive: true });
  await writeFile(join(folder, 'bridge', 'dist', 'mcp.js'), `const readline=require('node:readline'); const label=${JSON.stringify(name)}; readline.createInterface({input:process.stdin}).on('line',line=>{const req=JSON.parse(line);if(req.method==='exit'){process.exit(23);}console.log(JSON.stringify({id:req.id,label,url:process.env.PHONEBRIDGE_URL,credential:process.env.PHONEBRIDGE_CREDENTIAL_FILE,tokenPresent:!!process.env.PHONEBRIDGE_TOKEN}));});`);
  if (!windows) { await mkdir(join(folder, 'runtime')); await copyFile(process.execPath, join(folder, 'runtime', 'node')); await mkdir(join(folder, 'desktop', 'macos'), { recursive: true }); for (const name of ['mcp-bootstrap.mjs','network.mjs','configuration-lock.mjs']) await copyFile(join(root,'desktop',name),join(folder,'desktop',name)); for(const name of ['lifecycle.mjs','mcp-launcher.mjs'])await copyFile(join(root,'desktop','macos',name),join(folder,'desktop','macos',name)); }
  return folder;
}
test('bootstrap runs through a symlinked installation path instead of silently exiting', async t => {
  const f = await fixture(t), alias = join(f.state, 'desktop-alias');
  await symlink(join(root, 'desktop'), alias, windows ? 'junction' : 'dir');
  const result = spawnSync(process.execPath, [join(alias, 'mcp-bootstrap.mjs'), join(f.state, 'missing-config.json')], { encoding: 'utf8', timeout: 5000, windowsHide: true });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /PhoneBridge MCP could not start/);
});
test('Windows accepts only its user or exact default token owner and validates an actual newly created file', { skip: !windows }, async t => {
  const f = await fixture(t); await f.save(f.config);
  const script = join(f.state, 'check-owner.ps1');
  await writeFile(script, `param($AssemblyPath,$ConfigurationPath)
$ErrorActionPreference='Stop'
$type=[Reflection.Assembly]::LoadFile($AssemblyPath).GetType('McpLauncher')
$flags=[Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic
$matches=$type.GetMethod('OwnerMatches',$flags)
if (-not $matches.Invoke($null,[object[]]@('user','user','default-group'))) { throw 'Current user owner rejected.' }
if (-not $matches.Invoke($null,[object[]]@('default-group','user','default-group'))) { throw 'Current default token owner rejected.' }
if ($matches.Invoke($null,[object[]]@('foreign-group','user','default-group'))) { throw 'Foreign group owner accepted.' }
if ($matches.Invoke($null,[object[]]@('foreign-user','user','default-group'))) { throw 'Foreign user owner accepted.' }
$ownedFile=$type.GetMethod('OwnedFile',$flags)
[void]$ownedFile.Invoke($null,[object[]]@($ConfigurationPath,[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
'Current-token ownership checks passed.'
`);
  assert.match(execFileSync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, f.launcher, f.configFile], { encoding: 'utf8', windowsHide: true }), /ownership checks passed/);
});

test('Windows launcher help and unknown options do not misreport installation damage; App version follows the active manifest', { skip: !windows }, async t => {
  const f = await fixture(t);
  const help = spawnSync(f.launcher, ['--help'], { encoding: 'utf8', windowsHide: true });
  assert.equal(help.status, 0); assert.match(help.stdout, /Usage: PhoneBridgeMcp.exe/); assert.equal(help.stderr, '');
  const unknown = spawnSync(f.launcher, ['--unknown'], { encoding: 'utf8', windowsHide: true });
  assert.equal(unknown.status, 2); assert.match(unknown.stderr, /Unknown.*arguments/); assert.match(unknown.stderr, /Usage:/); assert.doesNotMatch(unknown.stderr, /could not start|installation/);
  const a = await fakePackage(f.state, 'version-A'), b = await fakePackage(f.state, 'version-B');
  for (const [projectRoot, version] of [[a, '7.8.9'], [b, '8.9.0-beta.1']]) {
    await writeFile(join(projectRoot, 'package-manifest.json'), '\uFEFF' + JSON.stringify({ product: 'PhoneBridge', version }));
    await f.save({ ...f.config, projectRoot });
    const result = spawnSync(f.launcher, ['--version'], { encoding: 'utf8', windowsHide: true });
    assert.equal(result.status, 0, result.stderr); assert.match(result.stdout, new RegExp(`PhoneBridge App ${version.replaceAll('.', '\\.')}`)); assert.match(result.stdout, /MCP launcher: PhoneBridge MCP bootstrap v1/); assert.equal(result.stderr, '');
  }
});

test('Windows defers a busy legacy v1 launcher and its temporary helper applies the pending update without a new GUI or service', { skip: !windows, timeout: 60000 }, async t => {
  const f = await fixture(t), a = await fakePackage(f.state, 'legacy-A'), source = join(a, 'PhoneBridgeMcp.exe'); await copyFile(f.launcher, source);
  await writeFile(join(a, 'package-manifest.json'), JSON.stringify({ product: 'PhoneBridge', platform: 'windows-x64' }));
  await mkdir(join(a, 'desktop')); await mkdir(join(a, 'scripts', 'windows'), { recursive: true });
  const removal = 'function Remove-PhoneBridgePendingMcpLauncher {\n    param([string]$Directory)';
  const helperSource = (await readFile(join(root, 'desktop', 'install-mcp-launcher.ps1'), 'utf8')).replaceAll('\r\n', '\n');
  assert.ok(helperSource.includes(removal));
  // Make the real File.Replace -> pending cleanup window observable even on a
  // fast machine. Only this disposable package's helper is delayed.
  await writeFile(join(a, 'desktop', 'install-mcp-launcher.ps1'), helperSource.replace(removal, removal + '\n    Start-Sleep -Milliseconds 250'));
  for (const name of ['atomic-config.ps1', 'run-desktop.ps1']) await copyFile(join(root, 'scripts', 'windows', name), join(a, 'scripts', 'windows', name));
  const legacySource = join(f.state, 'LegacyLauncher.cs');
  const code = (await readFile(join(root, 'desktop', 'McpLauncher.cs'), 'utf8'))
    .replace('if(args.Length==1 && (args[0]=="--help" || args[0]=="-h"))', 'if(false)')
    .replace('bool showVersion=args.Length==1 && args[0]=="--version";', 'bool showVersion=false;');
  await writeFile(legacySource, code);
  execFileSync(join(process.env.SystemRoot, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe'), ['/nologo', '/target:exe', '/reference:System.Web.Extensions.dll', '/out:' + f.launcher, legacySource], { windowsHide: true });
  await f.save({ ...f.config, projectRoot: a, launcherPath: join(a, 'scripts', 'windows', 'run-desktop.ps1'), powershellPath: powershell });
  const running = session(t, f.launcher); assert.equal((await running.request({ id: 1 })).label, 'legacy-A');
  const before = await readFile(f.launcher);
  const script = join(f.state, 'upgrade.ps1'); await writeFile(script, `param($Source,$State)\n$ErrorActionPreference='Stop'\n. '${join(a, 'desktop', 'install-mcp-launcher.ps1').replaceAll("'", "''")}'\nInstall-PhoneBridgeMcpLauncher -Source $Source -StateDirectory $State\n`);
  const upgrade = () => execFileSync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script, source, f.state], { encoding: 'utf8', windowsHide: true });
  assert.match(upgrade(), /running MCP launcher was preserved/); assert.deepEqual(await readFile(f.launcher), before); assert.equal((await running.request({ id: 2 })).label, 'legacy-A');
  assert.equal(JSON.parse(await readFile(join(f.state, 'bin', 'PhoneBridgeMcp.pending.json'), 'utf8')).source, source);
  running.child.stdin.end(); assert.equal((await boundedExit(running)).code, 0);
  // No new GUI/service loop is started: this is the legacy-running-bundle case.
  const pendingRecord = join(f.state, 'bin', 'PhoneBridgeMcp.pending.json'), workerRecord = join(f.state, 'bin', 'PhoneBridgeMcp.maintenance.json');
  const missing = async path => { try { await readFile(path); return false; } catch (error) { if (error.code === 'ENOENT') return true; throw error; } };
  // File.Replace publishes the new binary before the helper clears its pending
  // and worker records. Observe the complete terminal state, not that first step.
  for (let attempt = 0; attempt < 900; attempt++) {
    if ((await readFile(f.launcher)).equals(await readFile(source)) && await missing(pendingRecord) && await missing(workerRecord)) break;
    await new Promise(resolve => setTimeout(resolve, 40));
  }
  assert.ok((await readFile(f.launcher)).equals(await readFile(source)), 'The temporary idle helper must publish the queued launcher');
  await assert.rejects(readFile(pendingRecord), /ENOENT/);
  await assert.rejects(readFile(workerRecord), /ENOENT/);
  assert.equal(spawnSync(f.launcher, ['--help'], { windowsHide: true }).status, 0);
});
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

test('pending maintenance cannot apply another package or downgrade the current source to older queued bytes', { skip: !windows }, async t => {
  const f = await fixture(t), a = await fakePackage(f.state, 'older-package'), b = await fakePackage(f.state, 'current-package');
  const source = join(b, 'PhoneBridgeMcp.exe'), payload = join(f.state, 'bin', 'PhoneBridgeMcp.pending.exe');
  const current = await readFile(f.launcher), queued = Buffer.concat([current, Buffer.from('older-queued-build')]);
  await copyFile(f.launcher, source); await writeFile(payload, queued);
  await writeFile(join(b, 'package-manifest.json'), JSON.stringify({ product: 'PhoneBridge', platform: 'windows-x64' }));
  await f.save({ ...f.config, projectRoot: b, launcherPath: join(root, 'scripts', 'windows', 'run-desktop.ps1'), powershellPath: powershell });
  const marker = join(f.state, 'bin', 'PhoneBridgeMcp.pending.json');
  const record = { schema: 'phonebridge-mcp-pending-v1', source: join(a, 'PhoneBridgeMcp.exe'), sourceSha256: createHash('sha256').update(queued).digest('base64') };
  await writeFile(marker, JSON.stringify(record));
  const resume = () => execFileSync(powershell, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', join(root, 'desktop', 'install-mcp-launcher.ps1'), '--resume', f.configFile], { windowsHide: true });
  resume(); assert.deepEqual(await readFile(f.launcher), current); assert.deepEqual(await readFile(payload), queued);
  await writeFile(marker, JSON.stringify({ ...record, source }));
  resume(); assert.deepEqual(await readFile(f.launcher), current);
  await assert.rejects(readFile(marker), /ENOENT/);
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
  // Two independent payloads exercise installed manifest precedence and old/new sessions.
  const a=join(f.state,'package-A'),b=join(f.state,'package-B');
  for(const [folder,version] of [[a,'9.8.7'],[b,'9.8.8']]) { await mkdir(join(folder,'bridge'),{recursive:true});await cp(join(packageRoot,'bridge','dist'),join(folder,'bridge','dist'),{recursive:true});await copyFile(join(packageRoot,'bridge','package.json'),join(folder,'bridge','package.json'));await symlink(join(packageRoot,'bridge','node_modules'),join(folder,'bridge','node_modules'),windows?'junction':'dir');await writeFile(join(folder,'package-manifest.json'),'\uFEFF'+JSON.stringify({product:'PhoneBridge',version}));if(!windows){await mkdir(join(folder,'runtime'));await copyFile(nodePath,join(folder,'runtime','node'));await symlink(join(packageRoot,'desktop'),join(folder,'desktop'),'dir');} }
  const config={...f.config,projectRoot:a,nodePath:windows?nodePath:join(a,'runtime','node'),hostAddress:host};await f.save(config);
  const first=session(t,f.launcher);const initialize={jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'isolated-test',version:'1'}}};
  const initial=await first.request(initialize);assert.equal(initial.result.serverInfo.name,'phonebridge');assert.equal(initial.result.serverInfo.version,'9.8.7');
  await f.save({...config,projectRoot:b,nodePath:windows?nodePath:join(b,'runtime','node'),port:9876});
  const second=session(t,f.launcher);const upgraded=await second.request(initialize);assert.equal(upgraded.result.serverInfo.name,'phonebridge');assert.equal(upgraded.result.serverInfo.version,'9.8.8');
  for(const s of [first,second]) { const list=await s.request({jsonrpc:'2.0',id:2,method:'tools/list',params:{}});assert.ok(list.result.tools.some(tool=>tool.name==='phone_state'));for(const tool of list.result.tools){assert.equal(tool.inputSchema.type,'object');assert.doesNotMatch(JSON.stringify(tool.inputSchema),/"\$ref"\s*:/);for(const key of ['anyOf','oneOf','allOf'])assert.equal(key in tool.inputSchema,false);}s.child.stdin.end();assert.equal((await boundedExit(s)).code,0);assert.equal(s.stderr(),''); }
});
test('POSIX launcher publication is idempotent and refuses modified scripts; bootstrap validates current config', {skip:windows},async t=>{
  const f=await fixture(t),a=await fakePackage(f.state,'A');const config={...f.config,projectRoot:a,nodePath:join(a,'runtime','node')};await f.save(config);
  assert.equal(await installMcpLauncher(f.state,uid),f.launcher);assert.equal((await mcpTarget(f.configFile,uid)).env.PHONEBRIDGE_URL,'http://192.168.1.2:8767');
  await writeFile(f.launcher,'foreign',{mode:0o700});await assert.rejects(installMcpLauncher(f.state,uid),/unrecognized/);assert.equal(await readFile(f.launcher,'utf8'),'foreign');
});
