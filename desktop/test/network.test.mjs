import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const networkModule = process.env.PHONEBRIDGE_TEST_PACKAGE
  ? pathToFileURL(join(resolve(process.env.PHONEBRIDGE_TEST_PACKAGE), 'desktop', 'network.mjs'))
  : new URL('../network.mjs', import.meta.url);
const { localNetworks, privateIPv4, selectNetworks } = await import(networkModule.href);

const windows = process.platform === 'win32';
const powershell = process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

test('assigned shared VPN addresses are selectable and physical LAN keeps first priority', () => {
  for (const address of ['100.64.0.0', '100.95.4.7', '100.127.255.255']) {
    assert.equal(privateIPv4(address), true, address);
  }
  for (const address of ['100.63.255.255', '100.128.0.0', '100.064.0.1', '100.64.0.256', '0.0.0.0']) {
    assert.equal(privateIPv4(address), false, address);
  }
  const vpn = { name: 'VPN', address: '100.95.4.7', physical: false, defaultRoute: true };
  const lan = { name: 'Wi-Fi', address: '192.168.1.24', physical: true };
  const other = [{ ...vpn, active: false }, { ...vpn, internal: true }, { ...vpn, address: '100.128.0.1' }];
  assert.deepEqual(selectNetworks([vpn, lan, ...other]).map(n => n.address), [lan.address, vpn.address]);
  assert.deepEqual(selectNetworks([vpn, ...other]).map(n => n.address), [vpn.address]);
});

test('Windows installer and scheduled task validate the same private address ranges', { skip: !windows }, () => {
  const helper = fileURLToPath(new URL('../scripts/windows/run-desktop.ps1', networkModule));
  const candidates = ['192.168.1.2', '10.0.0.1', '172.16.0.1', '100.64.0.0', '100.127.255.255',
    '0.0.0.0', '8.8.8.8', '100.63.255.255', '100.128.0.0', '100.0100.0.1', '10.1', '127.0.0.1', '::1'];
  const command = `$ErrorActionPreference='Stop'
    . $env:PHONEBRIDGE_ADDRESS_HELPER -LoadHelpers
    $accepted = foreach ($address in (ConvertFrom-Json $env:PHONEBRIDGE_TEST_ADDRESSES)) {
      try { (Assert-PhoneBridgeAddress $address 8767).ToString() } catch {}
    }
    ConvertTo-Json -InputObject @($accepted) -Compress`;
  const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-Command', command], {
    encoding: 'utf8', windowsHide: true,
    env: { ...process.env, PHONEBRIDGE_ADDRESS_HELPER: helper, PHONEBRIDGE_DESKTOP_TEST: '0',
      PHONEBRIDGE_TEST_ADDRESSES: JSON.stringify(candidates) },
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  assert.deepEqual(JSON.parse(result.stdout), candidates.slice(0, 5));
});

test('Windows enumerates connected VPN interfaces that have no visible NetAdapter', { skip: !windows }, () => {
  const fixture = `function Get-NetRoute { @() }
    function Get-NetIPAddress {
      [pscustomobject]@{InterfaceIndex=3; IPAddress='100.64.8.1'; InterfaceAlias='VPN'; AddressState='Preferred'}
      [pscustomobject]@{InterfaceIndex=4; IPAddress='100.64.8.2'; InterfaceAlias='Old VPN'; AddressState='Preferred'}
    }
    function Get-NetAdapter { }
    function Get-NetIPInterface { param($InterfaceIndex) [pscustomobject]@{ConnectionState=if ($InterfaceIndex -eq 3) {'Connected'} else {'Disconnected'}} }
    `;
  const networks = localNetworks({ run(command, args, options) {
    const result = spawnSync(command, [...args.slice(0, -1), fixture + args.at(-1)], options);
    assert.equal(result.status, 0, result.stderr);
    return result;
  } });
  assert.deepEqual(networks.map(n => n.address), ['100.64.8.1']);
});

test('Windows PowerShell 5.1 transports non-ASCII aliases as UTF-8 even from a legacy console code page', { skip: !windows }, () => {
  const name = '以太网（测试） 🚀';
  const characters = name.split('').map(character => character.charCodeAt(0)).join(',');
  const fixture = `[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(936); function Get-NetRoute { [pscustomobject]@{ InterfaceIndex=7; RouteMetric=5 } }; function Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex=7; IPAddress='192.168.7.8'; AddressState='Preferred'; InterfaceAlias=([char[]]@(${characters}) -join '') } }; function Get-NetAdapter { [pscustomobject]@{ Status='Up'; HardwareInterface=$true } }; `;
  const networks = localNetworks({ run(command, args, options) {
    const actual = spawnSync(command, [...args.slice(0, -1), fixture + args.at(-1)], options);
    assert.equal(actual.status, 0, actual.stderr);
    return actual;
  } });
  assert.equal(networks.length, 1);
  assert.equal(networks[0].name, name);
  assert.equal(networks[0].address, '192.168.7.8');
  assert.equal(networks[0].physical, true);
  assert.equal(networks[0].defaultRoute, true);
});

test('Windows network enumeration preserves actual system adapter names through its stdout boundary', { skip: !windows }, () => {
  // This independent oracle transports UTF-16 JSON as ASCII base64, so it does
  // not share or depend on the UTF-8 stdout fix under test.
  const code = "$ErrorActionPreference='Stop'; $json=@(Get-NetIPAddress -AddressFamily IPv4 | Select-Object IPAddress,InterfaceAlias) | ConvertTo-Json -Compress; [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($json))";
  const result = spawnSync(powershell, ['-NoProfile', '-NonInteractive', '-Command', code], { encoding: 'utf8', windowsHide: true, timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
  const system = JSON.parse(Buffer.from(result.stdout.trim(), 'base64').toString('utf16le'));
  const networks = localNetworks();
  for (const network of networks) {
    const aliases = system.filter(item => item.IPAddress === network.address).map(item => item.InterfaceAlias);
    assert.ok(aliases.includes(network.name), `Adapter ${network.address}: expected ${JSON.stringify(aliases)}, received ${JSON.stringify(network.name)}`);
  }
});
