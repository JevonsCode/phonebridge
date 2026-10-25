#requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
    if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell 5.1 atomic configuration checks failed.' }
    return
}
. (Join-Path $PSScriptRoot 'atomic-config.ps1')
$fixture = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('phonebridge-atomic-config-' + [Guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($fixture)
$active = Join-Path $fixture 'desktop.json'
$temporary = Join-Path $fixture 'desktop.json.tmp'
$old = '{"version":"A","port":8767}'
$next = '{"version":"B","port":9876}'
function Assert-Content([string]$Path, [string]$Expected) {
    if ([IO.File]::ReadAllText($Path) -cne $Expected) { throw "Unexpected configuration content: $Path" }
}
try {
    # First install uses the same helper, with an absent destination.
    [IO.File]::WriteAllText($temporary, $old)
    Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active
    Assert-Content $active $old
    if ([IO.File]::Exists($temporary)) { throw 'First publication did not consume the temporary file.' }

    # Actual File.Replace execution in Windows PowerShell 5.1, not a mocked call.
    [IO.File]::WriteAllText($temporary, $next)
    Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active
    Assert-Content $active $next
    $backups = @(Get-ChildItem -LiteralPath $fixture -Filter '*.atomic-backup-*')
    if ($backups.Count -ne 1) { throw 'Expected the old configuration recovery copy.' }
    Assert-Content $backups[0].FullName $old

    # The installer's failed-registration path copies its backup then publishes
    # it through exactly the same primitive. Verify real rollback and recovery.
    [IO.File]::Copy($backups[0].FullName, $temporary, $false)
    Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active
    Assert-Content $active $old
    $backups = @(Get-ChildItem -LiteralPath $fixture -Filter '*.atomic-backup-*')
    if ($backups.Count -ne 2 -or -not ($backups | Where-Object { [IO.File]::ReadAllText($_.FullName) -ceq $next })) { throw 'Rollback failed to preserve the replaced version.' }

    # A real sharing violation must fail without changing the active file.
    [IO.File]::WriteAllText($temporary, $next)
    $held = [IO.File]::Open($active, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $failed = $false
    try { Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active }
    catch { $failed = $true }
    finally { $held.Dispose() }
    if (-not $failed) { throw 'Expected a sharing violation to reject atomic publication.' }
    Assert-Content $active $old
    Assert-Content $temporary $next
    # Real cross-process mutex contention is bounded; killing the owner releases
    # the OS mutex automatically, and the next publisher can recover it.
    $holderScript = Join-Path $fixture 'hold-lock.ps1'
    $ready = Join-Path $fixture 'lock-ready'
    @'
param($Helper,$Config,$Ready)
$ErrorActionPreference='Stop'
. $Helper
Invoke-PhoneBridgeConfigurationLock $Config { [IO.File]::WriteAllText($Ready,'held'); Start-Sleep -Seconds 30 }
'@ | Set-Content -LiteralPath $holderScript -Encoding UTF8
    $osPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" "{1}" "{2}" "{3}"' -f $holderScript,(Join-Path $PSScriptRoot 'atomic-config.ps1'),$active,$ready
    $holder = Start-Process -FilePath $osPowerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [IO.File]::Exists($ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        if (-not [IO.File]::Exists($ready)) { throw 'Fixture mutex holder did not become ready.' }
        $busy = $false
        try { Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active -ExpectedConfiguration ($old | ConvertFrom-Json) }
        catch { if ($_.Exception.Message -notmatch 'publication is busy') { throw }; $busy = $true }
        if (-not $busy) { throw 'Concurrent publisher bypassed the shared Windows mutex.' }
        Assert-Content $active $old
    } finally { if (-not $holder.HasExited) { $holder.Kill(); [void]$holder.WaitForExit(5000) }; $holder.Dispose() }
    Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active -ExpectedConfiguration ($old | ConvertFrom-Json)
    Assert-Content $active $next
    [IO.File]::WriteAllText($temporary, $old)
    $changed = $false
    try { Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $temporary -ConfigurationPath $active -ExpectedConfiguration ($old | ConvertFrom-Json) }
    catch { if ($_.Exception.Message -notmatch 'configuration changed') { throw }; $changed = $true }
    if (-not $changed) { throw 'A stale publisher overwrote a newer configuration.' }
    Assert-Content $active $next
    Write-Output "PowerShell $($PSVersionTable.PSVersion): real atomic first install, upgrade, rollback, and failed-publication preservation passed. No live configuration changed."
} finally {
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $fixture.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixture) -notlike 'phonebridge-atomic-config-*') { throw 'Unsafe test cleanup target.' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
