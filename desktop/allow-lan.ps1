#requires -Version 5.1
[CmdletBinding()]
param([string]$ConfigurationPath, [switch]$RequestElevation, [switch]$Apply, [switch]$ValidateOnly, [switch]$LoadHelpers)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function New-PhoneBridgeLanPlan($Config, [array]$Rules) {
    $name="PhoneBridge-LAN-$($Config.ownerSid)-TCP-$($Config.port)"
    $marker="PhoneBridge LAN managed rule v1; owner=$($Config.ownerSid); port=$($Config.port)"
    $existing=@($Rules | Where-Object Name -eq $name)
    if ($existing.Count -gt 1) { throw 'Ambiguous PhoneBridge firewall rule.' }
    if ($existing.Count -eq 1) {
        $r=$existing[0]
        if ($r.Description -ne $marker -or $r.Action -ne 'Allow' -or $r.Direction -ne 'Inbound' -or
            $r.Source -ne 'Local' -or $r.Enabled -ne 'True' -or $r.Profile -ne 'Private' -or
            $r.Protocol -notin @('TCP','6') -or $r.LocalPort -ne [string]$Config.port -or
            $r.RemoteAddress -ne 'LocalSubnet' -or $r.LocalAddress -ne 'Any' -or $r.Program -ne 'Any') {
            throw 'A foreign or modified firewall rule uses the PhoneBridge name. Nothing was changed.'
        }
    }
    $blocks=@($Rules | Where-Object { $_.Program -eq $Config.nodePath -and $_.Action -eq 'Block' -and $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' -and $_.Protocol -in @('TCP','6','Any','256') })
    foreach ($r in $blocks) {
        # Only Windows' automatic application-prompt rules, never custom or policy-managed blocks.
        if ($r.Name -notmatch '^TCP Query User\{[0-9a-f-]{36}\}(.+)$' -or $Matches[1] -ne $Config.nodePath -or
            $r.Source -ne 'Local' -or $r.Profile -notin @('Private','Public','Private, Public') -or
            $r.Protocol -notin @('TCP','6') -or $r.LocalPort -ne 'Any' -or
            $r.RemoteAddress -ne 'Any' -or $r.LocalAddress -ne 'Any') {
            throw 'A custom or policy firewall block affects this runtime. Ask the Windows owner to review it; nothing was changed.'
        }
    }
    return [pscustomobject]@{Name=$name;Description=$marker;Port=[int]$Config.port;Create=($existing.Count -eq 0);RemoveNames=@($blocks | ForEach-Object Name)}
}
function Get-PhoneBridgeFirewallRows($Config) {
    $name="PhoneBridge-LAN-$($Config.ownerSid)-TCP-$($Config.port)"
    # -Program reports a CIM error when no application rules exist, which is normal
    # on first install. Enumerate once and then query only exact matching filters.
    $applications=@(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction Stop | Where-Object Program -eq $Config.nodePath)
    $relevant=@()
    if ($applications.Count -gt 0) { $relevant=@($applications | Get-NetFirewallRule -ErrorAction Stop) }
    $relevant+=@(Get-NetFirewallRule -PolicyStore ActiveStore -Name $name -ErrorAction SilentlyContinue)
    foreach ($rule in @($relevant | Sort-Object Name -Unique)) {
        $app=$rule | Get-NetFirewallApplicationFilter -ErrorAction Stop
        $port=$rule | Get-NetFirewallPortFilter -ErrorAction Stop
        $address=$rule | Get-NetFirewallAddressFilter -ErrorAction Stop
        [pscustomobject]@{Name=$rule.Name;Description=$rule.Description;Program=[string]$app.Program;Action=[string]$rule.Action;Direction=[string]$rule.Direction;
            Enabled=[string]$rule.Enabled;Source=[string]$rule.PolicyStoreSourceType;Profile=[string]$rule.Profile;Protocol=[string]$port.Protocol;
            LocalPort=([string[]]$port.LocalPort -join ',');RemoteAddress=([string[]]$address.RemoteAddress -join ',');LocalAddress=([string[]]$address.LocalAddress -join ',')}
    }
}
function Invoke-PhoneBridgeLanPlan($Plan, [scriptblock]$Add, [scriptblock]$Remove) {
    # Establish the narrow allow rule before removing any automatic block. A failure leaves
    # remaining blocks intact and reports failure; firewall policy is never disabled.
    if ($Plan.Create) { & $Add $Plan }
    foreach ($name in $Plan.RemoveNames) { & $Remove $name }
}
if ($LoadHelpers) { return }
if (@($RequestElevation,$Apply,$ValidateOnly).Where({$_}).Count -ne 1) { throw 'Choose RequestElevation, Apply or ValidateOnly.' }
$lanMode=if($RequestElevation){'RequestElevation'}elseif($ValidateOnly){'ValidateOnly'}else{'Apply'}
if (-not $ConfigurationPath -or $ConfigurationPath -match '["\r\n]') { throw 'A safe owned configuration path is required.' }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\run-desktop.ps1') -ConfigurationPath $ConfigurationPath -LoadHelpers
$ConfigurationPath=[IO.Path]::GetFullPath($ConfigurationPath)
$config=Read-PhoneBridgeDesktopConfiguration $ConfigurationPath
$packageRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
if ([IO.Path]::GetFullPath($config.projectRoot) -ne $packageRoot -or
    [IO.Path]::GetFullPath($config.nodePath) -ne (Join-Path $packageRoot 'runtime\node.exe') -or
    -not (Test-Path -LiteralPath $config.nodePath -PathType Leaf)) { throw 'LAN permission is available only for the current owned packaged runtime.' }
$manifest=Get-Content -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.product -ne 'PhoneBridge' -or $manifest.platform -ne 'windows-x64') { throw 'Invalid PhoneBridge package.' }
$osPowerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($lanMode -eq 'RequestElevation') {
    # No auto-elevation during installation/startup. This branch is only called by the explicit button.
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigurationPath "{1}" -Apply' -f $PSCommandPath,$ConfigurationPath
    try { $process=Start-Process -FilePath $osPowerShell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru }
    catch { throw 'Windows permission was cancelled or unavailable. No LAN permission was granted.' }
    if ($process.ExitCode -ne 0) { throw 'Windows could not grant the narrow LAN permission. A custom firewall policy or different administrator account may require owner review.' }
    Write-Output 'LAN permission granted: TCP, Private profile, LocalSubnet.'
    return
}
$plan=New-PhoneBridgeLanPlan $config @(Get-PhoneBridgeFirewallRows $config)
if ($lanMode -eq 'ValidateOnly') { $plan | ConvertTo-Json -Depth 4; return }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Owner-approved Windows elevation is required.' }
Invoke-PhoneBridgeLanPlan $plan {
    param($p)
    New-NetFirewallRule -PolicyStore PersistentStore -Name $p.Name -DisplayName "PhoneBridge LAN TCP $($p.Port)" -Description $p.Description -Direction Inbound -Action Allow -Enabled True -Protocol TCP -LocalPort $p.Port -Profile Private -RemoteAddress LocalSubnet -ErrorAction Stop | Out-Null
} {
    param($name)
    # Recheck the exact rule immediately before deletion to avoid touching a replacement rule.
    $fresh=New-PhoneBridgeLanPlan $config @(Get-PhoneBridgeFirewallRows $config)
    if ($fresh.RemoveNames -notcontains $name) { throw 'Firewall rules changed during approval. Retry the button.' }
    Remove-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction Stop
}
Write-Output 'LAN permission granted: TCP, Private profile, LocalSubnet.'
