import { networkInterfaces } from 'node:os';
import { spawnSync } from 'node:child_process';

export function privateIPv4(address) {
  if (typeof address !== 'string' || !/^\d+\.\d+\.\d+\.\d+$/.test(address)) return false;
  const n = address.split('.').map(Number);
  if (address.split('.').some((part, index) => String(n[index]) !== part)) return false;
  if (n.some(v => v < 0 || v > 255)) return false;
  return n[0] === 10 || (n[0] === 172 && n[1] >= 16 && n[1] <= 31) || (n[0] === 192 && n[1] === 168);
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

export function localNetworks() {
  const code = "$ErrorActionPreference='Stop'; $r=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0'); @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $a=Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue; [pscustomobject]@{address=$_.IPAddress;name=$_.InterfaceAlias;active=($a.Status -eq 'Up');physical=[bool]$a.HardwareInterface;defaultRoute=([bool]($r | Where-Object InterfaceIndex -eq $_.InterfaceIndex));metric=($r | Where-Object InterfaceIndex -eq $_.InterfaceIndex | Select-Object -First 1 -ExpandProperty RouteMetric)}}) | ConvertTo-Json -Compress";
  const r = spawnSync(process.env.SystemRoot + '\\System32\\WindowsPowerShell\\v1.0\\powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', code], { encoding: 'utf8', windowsHide: true, timeout: 10000 });
  if (r.status === 0) { try { const parsed = JSON.parse(r.stdout); return selectNetworks(Array.isArray(parsed) ? parsed : [parsed]); } catch {} }
  return selectNetworks(Object.entries(networkInterfaces()).flatMap(([name, values]) => (values ?? []).map(v => ({ name, address: v.address, internal: v.internal }))));
}
