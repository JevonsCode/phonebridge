#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigurationPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phonebridge\desktop.json'),
    [switch]$ValidateOnly,
    [switch]$LoadHelpers
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PhoneBridgeUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-PhoneBridgeTaskArguments([string]$LauncherPath, [string]$ConfigPath) {
    foreach ($path in @($LauncherPath, $ConfigPath)) {
        if ($path -match '["\r\n]') { throw 'Desktop paths must not contain quotes or line breaks.' }
    }
    return '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigurationPath "{1}"' -f $LauncherPath, $ConfigPath
}

function Assert-PhoneBridgeAddress([string]$Address, [int]$ListenPort) {
    $parsedAddress = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsedAddress) -or
        $parsedAddress.Equals([Net.IPAddress]::Any) -or $parsedAddress.Equals([Net.IPAddress]::IPv6Any)) {
        throw 'HostAddress must be a fixed local IPv4/IPv6 address, not a hostname or wildcard.'
    }
    if ($ListenPort -lt 1 -or $ListenPort -gt 65535) { throw 'Port must be between 1 and 65535.' }
    return $parsedAddress
}

function Read-PhoneBridgeDesktopConfiguration([string]$Path) {
    $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($field in @('schema', 'ownerSid', 'projectRoot', 'nodePath', 'hostAddress', 'port', 'launcherPath', 'powershellPath')) {
        if (-not ($config.PSObject.Properties.Name -contains $field)) { throw "Desktop configuration is missing '$field'." }
    }
    if ($config.schema -ne 'phonebridge-desktop-v1' -or $config.ownerSid -ne (Get-PhoneBridgeUserSid)) {
        throw 'Refusing desktop configuration not owned by the current PhoneBridge user.'
    }
    if ($config.port -isnot [int] -and $config.port -isnot [long]) { throw 'Desktop configuration port must be an integer.' }
    [void](Assert-PhoneBridgeAddress $config.hostAddress $config.port)
    foreach ($field in @('projectRoot', 'nodePath', 'launcherPath', 'powershellPath')) {
        if (-not [IO.Path]::IsPathRooted($config.$field) -or $config.$field -match '["\r\n]') {
            throw "Desktop configuration '$field' must be a safe absolute path."
        }
    }
    return $config
}

function Assert-PhoneBridgeTaskOwnership($Task, $Config, [string]$ConfigPath) {
    $sid = Get-PhoneBridgeUserSid
    if ($null -eq $Config -or $Task.Description -ne "PhoneBridge Desktop managed task v1; owner=$sid") {
        throw 'Refusing to overwrite or remove a foreign PhoneBridge Desktop scheduled task.'
    }
    $principalSid = $Task.Principal.UserId
    if ($principalSid -ne $sid) {
        try { $principalSid = ([Security.Principal.NTAccount]$principalSid).Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw 'Cannot establish scheduled-task user ownership.' }
    }
    $actions = @($Task.Actions)
    if ($principalSid -ne $sid -or [string]$Task.Principal.RunLevel -notin @('Limited', '0') -or
        [string]$Task.Principal.LogonType -notin @('Interactive', '3') -or
        $actions.Count -ne 1 -or $actions[0].Execute -ne $Config.powershellPath -or
        $actions[0].Arguments -ne (Get-PhoneBridgeTaskArguments $Config.launcherPath $ConfigPath) -or
        $actions[0].WorkingDirectory -ne $Config.projectRoot) {
        throw 'Refusing a scheduled task whose user, privilege, or launch action is not owned by PhoneBridge.'
    }
}

if ($LoadHelpers) { return }

$ConfigurationPath = [IO.Path]::GetFullPath($ConfigurationPath)
$config = Read-PhoneBridgeDesktopConfiguration $ConfigurationPath
$entryPoint = Join-Path $config.projectRoot 'bridge\dist\supervisor-cli.js'
foreach ($file in @($config.nodePath, $entryPoint)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing desktop runtime file: $file. Build bridge and reinstall the desktop task." }
}
$nodeVersion = & $config.nodePath -p 'process.versions.node'
if ($LASTEXITCODE -ne 0 -or [int]($nodeVersion -split '\.')[0] -lt 22) { throw 'PhoneBridge requires Node.js 22 or newer.' }
if ($ValidateOnly -or $WhatIfPreference) {
    [pscustomobject]@{ ConfigurationPath = $ConfigurationPath; NodePath = $config.nodePath; EntryPoint = $entryPoint; HostAddress = $config.hostAddress; Port = $config.port }
    return
}
if (-not $PSCmdlet.ShouldProcess("$($config.hostAddress):$($config.port)", 'Run PhoneBridge Supervisor as current user')) { return }

$mutex = New-Object Threading.Mutex($false, "Local\PhoneBridgeDesktop-$(Get-PhoneBridgeUserSid)")
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'PhoneBridge Desktop is already running for this user. Stop its scheduled task before launching another instance.' }
    $listener = New-Object Net.Sockets.TcpListener((Assert-PhoneBridgeAddress $config.hostAddress $config.port), [int]$config.port)
    try {
        $listener.Start()
    } catch {
        throw "Cannot listen on $($config.hostAddress):$($config.port). Confirm this IP belongs to this computer and stop the old Hub or other process using the port. $($_.Exception.Message)"
    } finally { $listener.Stop() }

    $previousHost = [Environment]::GetEnvironmentVariable('PHONEBRIDGE_HOST', 'Process')
    $previousPort = [Environment]::GetEnvironmentVariable('PHONEBRIDGE_PORT', 'Process')
    try {
        $env:PHONEBRIDGE_HOST = [string]$config.hostAddress
        $env:PHONEBRIDGE_PORT = [string]$config.port
        Push-Location -LiteralPath $config.projectRoot
        try {
            # Keep ownership across crashes; Task Scheduler remains a fallback for wrapper failures.
            # A deliberate task stop kills this wrapper, including any pending retry.
            $retryDelaySeconds = 2
            while ($true) {
                $runDuration = [Diagnostics.Stopwatch]::StartNew()
                try {
                    & $config.nodePath $entryPoint --allow-lan --remember-pairing
                    $supervisorExitCode = $LASTEXITCODE
                } catch {
                    # A failed process launch is recoverable too; never log pairing data.
                    $supervisorExitCode = -1
                } finally { $runDuration.Stop() }
                if ($supervisorExitCode -eq 0) { break }
                if ($runDuration.Elapsed.TotalSeconds -ge 30) { $retryDelaySeconds = 2 }
                Write-Warning "PhoneBridge Supervisor exited ($supervisorExitCode); retrying in $retryDelaySeconds seconds."
                Start-Sleep -Seconds $retryDelaySeconds
                $retryDelaySeconds = [Math]::Min(30, $retryDelaySeconds * 2)
            }
        } finally { Pop-Location }
    } finally {
        [Environment]::SetEnvironmentVariable('PHONEBRIDGE_HOST', $previousHost, 'Process')
        [Environment]::SetEnvironmentVariable('PHONEBRIDGE_PORT', $previousPort, 'Process')
    }
    exit $supervisorExitCode
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
