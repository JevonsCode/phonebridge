#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot, [switch]$ValidateOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).ProviderPath
$configPath = if ($env:PHONEBRIDGE_DESKTOP_CONFIG) { [IO.Path]::GetFullPath($env:PHONEBRIDGE_DESKTOP_CONFIG) } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phonebridge\desktop.json' }
. (Join-Path $PackageRoot 'scripts\windows\run-desktop.ps1') -LoadHelpers
. (Join-Path $PSScriptRoot 'setup-transaction.ps1')
$previous = $null
if (Test-Path -LiteralPath $configPath) { $previous = Read-PhoneBridgeDesktopConfiguration $configPath }
$task = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object TaskName -eq 'PhoneBridge Desktop')
if ($task.Count -gt 0) { Assert-PhoneBridgeTaskOwnership $task[0] $previous $configPath }
$address = if ($previous) { $previous.hostAddress } else { & (Join-Path $PackageRoot 'runtime\node.exe') (Join-Path $PackageRoot 'desktop\select-network.mjs'); if ($LASTEXITCODE -ne 0) { throw 'Connect this computer to a private Wi-Fi or Ethernet network before installing.' } }
if ($ValidateOnly) { [pscustomobject]@{ DryRun=$true; ExistingOwnedConfig=($null -ne $previous); ExistingOwnedTask=($task.Count -gt 0); PackageRoot=$PackageRoot }; return }
# Preserve owned configuration and the old task XML before migrating only installation paths.
$backup = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')"
if ($previous) { Copy-Item -LiteralPath $configPath -Destination $backup }
if ($task.Count -gt 0) { Export-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\' | Set-Content -LiteralPath "$backup.task.xml" -Encoding UTF8 }
Invoke-PhoneBridgeSetupTransaction -HadTask ($task.Count -gt 0) -Install {
    & (Join-Path $PackageRoot 'scripts\windows\install-desktop.ps1') -ProjectRoot $PackageRoot -NodePath (Join-Path $PackageRoot 'runtime\node.exe') -HostAddress $address -Port $(if ($previous) { $previous.port } else { 8767 }) -ConfigurationPath $configPath
} -CreateShortcut {
    & (Join-Path $PSScriptRoot 'shortcut.ps1') -PackageRoot $PackageRoot
} -RemoveNewTask {
    $newConfig = Read-PhoneBridgeDesktopConfiguration $configPath
    $newTask = Get-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\'
    Assert-PhoneBridgeTaskOwnership $newTask $newConfig $configPath
    Unregister-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\' -Confirm:$false
} -RestoreTask {
    [void](Register-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\' -Xml (Get-Content -LiteralPath "$backup.task.xml" -Raw) -Force)
} -RestoreConfiguration {
    if ($previous) { Copy-Item -LiteralPath $backup -Destination $configPath -Force }
    elseif (Test-Path -LiteralPath $configPath) {
        $newConfig = Read-PhoneBridgeDesktopConfiguration $configPath
        if ($newConfig.projectRoot -ne $PackageRoot) { throw 'Cannot remove configuration whose installation ownership changed.' }
        Remove-Item -LiteralPath $configPath
    }
}
# An already running service stays in place; the new paths apply at the next start.
Write-Output 'PhoneBridge current-user installation completed. Pairing identity was preserved.'
