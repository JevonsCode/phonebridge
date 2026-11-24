import { isIPv4 } from 'node:net';
import { networkInterfaces } from 'node:os';
import { spawnSync } from 'node:child_process';

export function privateIPv4(address) {
  if (typeof address !== 'string' || !isIPv4(address)) return false;
  const [first, second] = address.split('.').map(Number);
  return first === 10 || (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168) || (first === 100 && second >= 64 && second <= 127);
}

export function selectNetworks(adapters) {
  return adapters.filter(a => !a.internal && a.active !== false && privateIPv4(a.address))
    .map(a => ({ ...a, score: (a.physical ? 100 : 0) + (a.defaultRoute ? 50 : 0) - (/vpn|tailscale|wireguard|tap|tun|virtual|vethernet|docker|hyper-v/i.test(a.name) ? 200 : 0) - Math.min(Number(a.metric) || 0, 20) }))
    .sort((a, b) => b.score - a.score || a.address.localeCompare(b.address));
}

export function windowsIdentity() {
  const r = spawnSync(process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', '[Security.Principal.WindowsIdentity]::GetCurrent().User.Value'], { encoding: 'utf8', windowsHide: true });
  if (r.status !== 0 || !/^S-1-\d+(?:-\d+)+$/.test(r.stdout.trim())) throw new Error('Cannot establish current Windows user ownership.');
  return r.stdout.trim();
}

export function localNetworks({ run = spawnSync } = {}) {
  // Windows PowerShell 5.1 otherwise encodes redirected stdout with the active
  // console code page. Node's UTF-8 decoder cannot recover localized aliases.
  const code = `$ErrorActionPreference='Stop'
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object {
      $ip = $_
      $adapter = Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex -IncludeHidden -ErrorAction SilentlyContinue
      $up = if ($adapter) { $adapter.Status -eq 'Up' } else {
        (Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue).ConnectionState -eq 'Connected'
      }
      $route = $routes | Where-Object InterfaceIndex -eq $ip.InterfaceIndex | Sort-Object RouteMetric | Select-Object -First 1
      [pscustomobject]@{ address=$ip.IPAddress; name=$ip.InterfaceAlias; active=($up -and $ip.AddressState -eq 'Preferred')
        physical=[bool]$adapter.HardwareInterface; defaultRoute=[bool]$route; metric=$route.RouteMetric }
    }) | ConvertTo-Json -Compress`;
  const r = run(process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', code], { encoding: 'utf8', windowsHide: true, timeout: 10000 });
  if (r.status === 0) { try { const parsed = JSON.parse(r.stdout); return selectNetworks(Array.isArray(parsed) ? parsed : [parsed]); } catch {} }
  return selectNetworks(Object.entries(networkInterfaces()).flatMap(([name, values]) => (values ?? []).map(v => ({ name, address: v.address, internal: v.internal }))));
}
