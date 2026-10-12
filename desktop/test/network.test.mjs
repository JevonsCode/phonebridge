import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const networkModule = process.env.PHONEBRIDGE_TEST_PACKAGE
  ? pathToFileURL(join(resolve(process.env.PHONEBRIDGE_TEST_PACKAGE), 'desktop', 'network.mjs'))
  : new URL('../network.mjs', import.meta.url);
const { localNetworks } = await import(networkModule.href);

const windows = process.platform === 'win32';
const powershell = process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

test('Windows PowerShell 5.1 transports non-ASCII aliases as UTF-8 even from a legacy console code page', { skip: !windows }, () => {
  const name = '以太网（测试） 🚀';
  const characters = name.split('').map(character => character.charCodeAt(0)).join(',');
  const fixture = `[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(936); function Get-NetRoute { [pscustomobject]@{ InterfaceIndex=7; RouteMetric=5 } }; function Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex=7; IPAddress='192.168.7.8'; InterfaceAlias=([char[]]@(${characters}) -join '') } }; function Get-NetAdapter { [pscustomobject]@{ Status='Up'; HardwareInterface=$true } }; `;
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
