#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigurationPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phonebridge\desktop.json'),
    [switch]$RemoveConfiguration,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'run-desktop.ps1') -LoadHelpers -ConfigurationPath $ConfigurationPath -ValidateOnly:$ValidateOnly
$ConfigurationPath = [IO.Path]::GetFullPath($ConfigurationPath)
$config = $null
if (Test-Path -LiteralPath $ConfigurationPath) { $config = Read-PhoneBridgeDesktopConfiguration $ConfigurationPath }
Import-Module ScheduledTasks -ErrorAction Stop
$existing = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object TaskName -eq 'PhoneBridge Desktop')
if ($existing.Count -gt 0) { Assert-PhoneBridgeTaskOwnership $existing[0] $config $ConfigurationPath }
if ($ValidateOnly -or $WhatIfPreference) {
    [pscustomobject]@{ TaskName = 'PhoneBridge Desktop'; ExistingOwnedTask = ($existing.Count -gt 0); RemoveConfiguration = [bool]$RemoveConfiguration; ConfigurationPath = $ConfigurationPath }
    return
}
if ($existing.Count -gt 0 -and $PSCmdlet.ShouldProcess('PhoneBridge Desktop', 'Stop and unregister current-user scheduled task')) {
    Stop-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\' -ErrorAction Stop
    Unregister-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\' -Confirm:$false -ErrorAction Stop
}
if ($RemoveConfiguration -and $null -ne $config -and $PSCmdlet.ShouldProcess($ConfigurationPath, 'Remove owned desktop runtime configuration')) {
    Remove-Item -LiteralPath $ConfigurationPath -Force
}
Write-Output 'PhoneBridge Desktop uninstall finished. Pairing credentials and configuration backups are preserved.'
