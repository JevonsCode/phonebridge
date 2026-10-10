#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectRoot,
    [Parameter(Mandatory)][string]$HostAddress,
    [ValidateRange(1, 65535)][int]$Port = 8767,
    [string]$NodePath,
    [string]$ConfigurationPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phonebridge\desktop.json'),
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'run-desktop.ps1') -LoadHelpers -ConfigurationPath $ConfigurationPath -ValidateOnly:$ValidateOnly
$taskName = 'PhoneBridge Desktop'
$taskPath = '\'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).ProviderPath
$ConfigurationPath = [IO.Path]::GetFullPath($ConfigurationPath)
$launcher = Join-Path $ProjectRoot 'scripts\windows\run-desktop.ps1'
$entryPoint = Join-Path $ProjectRoot 'bridge\dist\supervisor-cli.js'
$jobHelper = Join-Path $ProjectRoot 'scripts\windows\desktop-job.cs'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($file in @($launcher, $entryPoint, $powershell, $jobHelper)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing desktop runtime file: $file. Run npm run build in bridge first." }
}
[void](Assert-PhoneBridgeAddress $HostAddress $Port)
if (-not $NodePath) { $NodePath = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
$NodePath = (Resolve-Path -LiteralPath $NodePath).ProviderPath
# Resolve NVM junctions now: future logins must use this exact installed runtime.
$resolvedNodePath = & $NodePath -p "require('node:fs').realpathSync(process.execPath)"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $resolvedNodePath -PathType Leaf)) { throw 'Cannot resolve the installed Node runtime.' }
$NodePath = [IO.Path]::GetFullPath([string]$resolvedNodePath)
$nodeVersion = & $NodePath -p 'process.versions.node'
if ($LASTEXITCODE -ne 0 -or [int]($nodeVersion -split '\.')[0] -lt 22) { throw 'PhoneBridge requires Node.js 22 or newer.' }
$sid = Get-PhoneBridgeUserSid
$oldConfig = $null
if (Test-Path -LiteralPath $ConfigurationPath) { $oldConfig = Read-PhoneBridgeDesktopConfiguration $ConfigurationPath }
Import-Module ScheduledTasks -ErrorAction Stop
try {
    # Enumerate this exact folder rather than hiding access-denied errors as a missing task.
    $existing = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction Stop | Where-Object TaskName -eq $taskName)
} catch { throw "Cannot inspect current-user scheduled tasks. Use a Windows account permitted to register its own limited logon task; this installer will not request admin rights. $($_.Exception.Message)" }
if ($existing.Count -gt 0) { Assert-PhoneBridgeTaskOwnership $existing[0] $oldConfig $ConfigurationPath }
$arguments = Get-PhoneBridgeTaskArguments $launcher $ConfigurationPath
$config = [ordered]@{ schema = 'phonebridge-desktop-v1'; ownerSid = $sid; projectRoot = $ProjectRoot; nodePath = $NodePath; hostAddress = $HostAddress; port = $Port; launcherPath = $launcher; powershellPath = $powershell }
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $ProjectRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
$principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "PhoneBridge Desktop managed task v1; owner=$sid"
if ($ValidateOnly -or $WhatIfPreference) {
    [pscustomobject]@{ ConfigurationPath = $ConfigurationPath; Configuration = [pscustomobject]$config; Task = $task; ExistingOwnedTask = ($existing.Count -gt 0) }
    return
}
if (-not $PSCmdlet.ShouldProcess("$taskPath$taskName and $ConfigurationPath", 'Install current-user PhoneBridge Desktop logon task')) { return }

$configDirectory = Split-Path $ConfigurationPath -Parent
[void](New-Item -ItemType Directory -Path $configDirectory -Force)
$backup = $null
if ($null -ne $oldConfig) {
    $backup = "$ConfigurationPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')"
    Copy-Item -LiteralPath $ConfigurationPath -Destination $backup -ErrorAction Stop
}
$temporaryConfig = "$ConfigurationPath.tmp-$([Guid]::NewGuid().ToString('N'))"
try {
    $json = $config | ConvertTo-Json
    [IO.File]::WriteAllText($temporaryConfig, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporaryConfig -Destination $ConfigurationPath -Force
    try {
        [void](Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -InputObject $task -Force -ErrorAction Stop)
    } catch {
        if ($backup) { Copy-Item -LiteralPath $backup -Destination $ConfigurationPath -Force }
        else { Remove-Item -LiteralPath $ConfigurationPath -Force }
        throw "Task registration failed; the previous desktop configuration was restored. This installer will not elevate privileges or create a system service. Check current-user Task Scheduler permission. $($_.Exception.Message)"
    }
} finally {
    if (Test-Path -LiteralPath $temporaryConfig) { Remove-Item -LiteralPath $temporaryConfig -Force }
}
Write-Output "Installed '$taskName' for the current user. It starts at the next login; use Start-ScheduledTask -TaskName '$taskName' to start now. Configuration: $ConfigurationPath"
if ($backup) { Write-Output "Previous desktop configuration backup: $backup" }
