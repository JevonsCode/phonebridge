#requires -Version 5.1
function Get-PhoneBridgeMcpBootstrapHash {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($hash.ComputeHash($stream)) } finally { $hash.Dispose(); $stream.Dispose() }
}
function Test-PhoneBridgeMcpBootstrapRunning {
    param([Parameter(Mandatory)][string]$Path)
    $busy = $false
    foreach ($candidate in [Diagnostics.Process]::GetProcessesByName('PhoneBridgeMcp')) {
        try { if ($candidate.MainModule.FileName -eq $Path) { $busy = $true } } catch {} finally { $candidate.Dispose() }
    }
    return $busy
}
function Assert-PhoneBridgeMcpBootstrap {
    param([Parameter(Mandatory)][string]$Path)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    $owner = [IO.File]::GetAccessControl($Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $sid -and $owner -ne $identity.Owner.Value) { throw 'The stable MCP launcher belongs to another user.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Path
    $start.Arguments = '--launcher-version'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) { $process.Kill(); throw 'MCP bootstrap validation timed out.' }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000) -or $process.ExitCode -ne 0 -or $stdout.Result.Trim() -cne 'PhoneBridge MCP bootstrap v1' -or $stderr.Result) { throw 'An unrecognized stable MCP launcher was preserved.' }
    } finally { $process.Dispose() }
}
function Remove-PhoneBridgePendingMcpLauncher {
    param([string]$Directory)
    foreach ($name in @('PhoneBridgeMcp.pending.exe','PhoneBridgeMcp.pending.json')) {
        $path = Join-Path $Directory $name
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'An unrecognized pending MCP file was preserved.' }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $owner = [IO.File]::GetAccessControl($path).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -ne $identity.User.Value -and $owner -ne $identity.Owner.Value) { throw 'A foreign pending MCP file was preserved.' }
            [IO.File]::Delete($path)
        }
    }
}
function Save-PhoneBridgePendingMcpLauncher {
    param([string]$Source, [string]$Directory)
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $payload = Join-Path $Directory 'PhoneBridgeMcp.pending.exe'
    $metadata = Join-Path $Directory 'PhoneBridgeMcp.pending.json'
    $temporary = Join-Path $Directory ('mcp-pending-' + [Guid]::NewGuid().ToString('N') + '.exe')
    $recordTemporary = "$metadata.tmp-$([Guid]::NewGuid().ToString('N'))"
    $backups = @()
    try {
        [IO.File]::Copy($sourcePath, $temporary, $false)
        Assert-PhoneBridgeMcpBootstrap $temporary
        $hash = Get-PhoneBridgeMcpBootstrapHash $temporary
        $record = @{schema='phonebridge-mcp-pending-v1';source=$sourcePath;sourceSha256=$hash}
        [IO.File]::WriteAllText($recordTemporary, ($record | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        foreach ($pair in @(@($temporary,$payload),@($recordTemporary,$metadata))) {
            if ([IO.File]::Exists($pair[1])) {
                if ((Get-Item -LiteralPath $pair[1]).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'An unrecognized pending MCP file was preserved.' }
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $owner = [IO.File]::GetAccessControl($pair[1]).GetOwner([Security.Principal.SecurityIdentifier]).Value
                if ($owner -ne $identity.User.Value -and $owner -ne $identity.Owner.Value) { throw 'A foreign pending MCP file was preserved.' }
                $backup = "$($pair[1]).backup-$([Guid]::NewGuid().ToString('N'))"; $backups += $backup
                [IO.File]::Replace($pair[0], $pair[1], $backup)
            } else { [IO.File]::Move($pair[0], $pair[1]) }
        }
    } finally {
        foreach ($path in @($temporary,$recordTemporary) + $backups) { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    }
}
function Install-PhoneBridgeMcpLauncherCore {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$StateDirectory, [switch]$NoMaintenance)
    $ErrorActionPreference = 'Stop'
    $directory = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'bin'
    [void][IO.Directory]::CreateDirectory($directory)
    if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The stable MCP directory must not be a link.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $owner = [IO.Directory]::GetAccessControl($directory).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $identity.User.Value -and $owner -ne $identity.Owner.Value) { throw 'The stable MCP directory belongs to another user.' }
    $destination = Join-Path $directory 'PhoneBridgeMcp.exe'
    $exists = Test-Path -LiteralPath $destination
    if ($exists) {
        if ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The stable MCP launcher must not be a link.' }
        Assert-PhoneBridgeMcpBootstrap $destination
        if ((Get-PhoneBridgeMcpBootstrapHash $destination) -eq (Get-PhoneBridgeMcpBootstrapHash $Source)) { Remove-PhoneBridgePendingMcpLauncher $directory; return $destination }
    }
    $temporary = Join-Path $directory ('mcp-' + [Guid]::NewGuid().ToString('N') + '.exe')
    $backup = Join-Path $directory ('mcp-old-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        Assert-PhoneBridgeMcpBootstrap $temporary
        if ($exists) {
            # v1 is a stable protocol identity, including earlier installed builds.
            # Preserve live MCP sessions and defer launcher enhancements until an
            # idle installation; new sessions still resolve the active payload.
            if (Test-PhoneBridgeMcpBootstrapRunning $destination) {
                Save-PhoneBridgePendingMcpLauncher $Source $directory
                if (-not $NoMaintenance) { Start-PhoneBridgePendingMcpMaintenance $StateDirectory }
                Write-Warning 'The running MCP launcher was preserved. Its pending update will be applied automatically when idle.'
                return $destination
            }
            try { [IO.File]::Replace($temporary, $destination, $backup) }
            catch {
                $cause = $_.Exception
                while ($cause.InnerException) { $cause = $cause.InnerException }
                $nativeCode = $cause.HResult -band 0xffff
                if ($nativeCode -in @(32,33) -or ($nativeCode -eq 5 -and (Test-PhoneBridgeMcpBootstrapRunning $destination))) {
                    Save-PhoneBridgePendingMcpLauncher $Source $directory
                    if (-not $NoMaintenance) { Start-PhoneBridgePendingMcpMaintenance $StateDirectory }
                    Write-Warning 'The busy MCP launcher was preserved. Its pending update will be applied automatically when idle.'
                    return $destination
                }
                throw
            }
        } else { [IO.File]::Move($temporary, $destination) } # Atomic exclusive publication.
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup }
    }
    Remove-PhoneBridgePendingMcpLauncher $directory
    return $destination
}
function Install-PhoneBridgeMcpLauncher {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$StateDirectory)
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\atomic-config.ps1')
    $configuration = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'desktop.json'
    Invoke-PhoneBridgeConfigurationLock $configuration { Install-PhoneBridgeMcpLauncherCore $Source $StateDirectory }
}
function Resume-PhoneBridgeMcpLauncher {
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\atomic-config.ps1')
    Invoke-PhoneBridgeConfigurationLock $ConfigurationPath {
        $directory = Join-Path (Split-Path ([IO.Path]::GetFullPath($ConfigurationPath)) -Parent) 'bin'
        $metadata = Join-Path $directory 'PhoneBridgeMcp.pending.json'
        $payload = Join-Path $directory 'PhoneBridgeMcp.pending.exe'
        if (-not [IO.File]::Exists($metadata) -or -not [IO.File]::Exists($payload)) { return $false }
        foreach ($path in @($metadata,$payload)) {
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'An unrecognized pending MCP file was preserved.' }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $owner = [IO.File]::GetAccessControl($path).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -ne $identity.User.Value -and $owner -ne $identity.Owner.Value) { throw 'A foreign pending MCP file was preserved.' }
        }
        if ((Get-Item -LiteralPath $metadata).Length -gt 32768) { throw 'Invalid pending MCP metadata.' }
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\run-desktop.ps1') -ConfigurationPath $ConfigurationPath -LoadHelpers
        $config = Read-PhoneBridgeDesktopConfiguration $ConfigurationPath
        $record = [IO.File]::ReadAllText($metadata) | ConvertFrom-Json
        $source = Join-Path $config.projectRoot 'PhoneBridgeMcp.exe'
        if ($record.schema -ne 'phonebridge-mcp-pending-v1' -or $record.source -ine $source) { return $false }
        if ((Get-PhoneBridgeMcpBootstrapHash $payload) -cne $record.sourceSha256) { throw 'A modified pending MCP payload was preserved.' }
        $manifest = Get-Content -LiteralPath (Join-Path $config.projectRoot 'package-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.product -ne 'PhoneBridge' -or $manifest.platform -ne 'windows-x64') { throw 'The current MCP update package is unavailable.' }
        # The active owned package wins over an older in-place pending payload.
        Assert-PhoneBridgeMcpBootstrap $source
        if (Test-PhoneBridgeMcpBootstrapRunning (Join-Path $directory 'PhoneBridgeMcp.exe')) { return $false }
        [void](Install-PhoneBridgeMcpLauncherCore $source (Split-Path ([IO.Path]::GetFullPath($ConfigurationPath)) -Parent) -NoMaintenance)
        return (-not [IO.File]::Exists($metadata))
    }
}
function Start-PhoneBridgePendingMcpMaintenance {
    param([Parameter(Mandatory)][string]$StateDirectory)
    $helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'install-mcp-launcher.ps1'))
    $configuration = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'desktop.json'
    if ($helper -match '["\r\n]' -or $configuration -match '["\r\n]') { throw 'Invalid MCP maintenance path.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $owner = [IO.File]::GetAccessControl($helper).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ((Get-Item -LiteralPath $helper).Attributes -band [IO.FileAttributes]::ReparsePoint -or
        ($owner -ne $identity.User.Value -and $owner -ne $identity.Owner.Value)) { throw 'A foreign MCP maintenance helper was preserved.' }
    $osPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" --watch "{1}"' -f $helper,$configuration
    $child = Start-Process -FilePath $osPowerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $child.Dispose()
}
function Watch-PhoneBridgePendingMcpLauncher {
    param([Parameter(Mandatory)][string]$ConfigurationPath)
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\atomic-config.ps1')
    $marker = Join-Path (Split-Path $ConfigurationPath -Parent) 'bin\PhoneBridgeMcp.pending.json'
    $workerRecord = Join-Path (Split-Path $ConfigurationPath -Parent) 'bin\PhoneBridgeMcp.maintenance.json'
    try {
        Invoke-PhoneBridgeConfigurationLock ($ConfigurationPath + '.mcp-maintenance') -TimeoutMs 0 {
            if ([IO.File]::Exists($workerRecord)) {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $owner = [IO.File]::GetAccessControl($workerRecord).GetOwner([Security.Principal.SecurityIdentifier]).Value
                if ((Get-Item -LiteralPath $workerRecord).Attributes -band [IO.FileAttributes]::ReparsePoint -or
                    ($owner -ne $identity.User.Value -and $owner -ne $identity.Owner.Value)) { throw 'A foreign MCP maintenance record was preserved.' }
            }
            $workerIdentity = @{pid=$PID;nonce=[Guid]::NewGuid().ToString('N')}
            $workerText = $workerIdentity | ConvertTo-Json -Compress
            [IO.File]::WriteAllText($workerRecord, $workerText, (New-Object Text.UTF8Encoding($false)))
            try {
                # A legacy service need not be restarted for its pending upgrade.
                # The helper is temporary; a failed attempt retains the durable
                # record for the next startup/GUI pass, with no new OS task.
                $deadline = [DateTime]::UtcNow.AddHours(24)
                while ([IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline) {
                    try { if (Resume-PhoneBridgeMcpLauncher $ConfigurationPath) { break } } catch { }
                    Start-Sleep -Seconds 30
                }
            } finally { if ([IO.File]::Exists($workerRecord) -and [IO.File]::ReadAllText($workerRecord) -ceq $workerText) { [IO.File]::Delete($workerRecord) } }
        }
    } catch {
        # Another temporary helper already owns this exact per-user instance.
        if ($_.Exception.Message -notmatch 'publication is busy') { throw }
    }
}
if ($MyInvocation.InvocationName -ne '.' -and $args.Count -gt 0) {
    $ErrorActionPreference = 'Stop'
    if ($args.Count -ne 2 -or $args[0] -notin @('--resume','--watch')) { throw 'Invalid MCP maintenance arguments.' }
    if ($args[0] -eq '--watch') { Watch-PhoneBridgePendingMcpLauncher -ConfigurationPath $args[1] }
    else { [void](Resume-PhoneBridgeMcpLauncher -ConfigurationPath $args[1]) }
}
