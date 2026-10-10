#requires -Version 5.1
[CmdletBinding()]
param([string]$NodePath = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source)

# Isolated regression: no scheduled task, pairing, network port, or runtime config.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'desktop-job.cs'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PhoneBridge job test ' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$fixture = Join-Path $testRoot 'supervisor fixture.cjs'
$wrapperPath = Join-Path $testRoot 'wrapper.ps1'
$record = Join-Path $testRoot 'processes.jsonl'
$exitFixture = Join-Path $testRoot 'exit fixture.cjs'
$wrapper = $null
$children = @()
$job = $null
$process = $null
$previousRecord = [Environment]::GetEnvironmentVariable('PHONEBRIDGE_JOB_TEST_RECORD', 'Process')
try {
    @'
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const child = process.argv[2] === 'child';
if (!child) spawn(process.execPath, [__filename, 'child'], { stdio: 'ignore' });
fs.appendFileSync(process.env.PHONEBRIDGE_JOB_TEST_RECORD, JSON.stringify({ role: child ? 'grandchild' : 'supervisor', pid: process.pid }) + '\n');
setInterval(() => {}, 1000);
'@ | Set-Content -LiteralPath $fixture -Encoding ASCII
    @'
param([string]$HelperPath, [string]$NodePath, [string]$FixturePath, [string]$WorkingDirectory)
$ErrorActionPreference='Stop'
Add-Type -Path $HelperPath
$job=New-Object PhoneBridge.Desktop.KillOnCloseJob
try {
    $child=$job.StartSupervisor($NodePath,$FixturePath,$WorkingDirectory)
    try { [void]$child.WaitForExit() } finally { $child.Dispose() }
} finally { $job.Dispose() }
'@ | Set-Content -LiteralPath $wrapperPath -Encoding ASCII
    'process.exit(7);' | Set-Content -LiteralPath $exitFixture -Encoding ASCII
    $env:PHONEBRIDGE_JOB_TEST_RECORD = $record
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -HelperPath "{1}" -NodePath "{2}" -FixturePath "{3}" -WorkingDirectory "{4}"' -f $wrapperPath, $helper, $NodePath, $fixture, $testRoot
    $wrapper = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
    [void]$wrapper.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $rows = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $record) { $rows = @(Get-Content -LiteralPath $record | ForEach-Object { $_ | ConvertFrom-Json }) }
        if ($rows.Count -ge 2) { break }
        if ($wrapper.HasExited) { throw "Isolated wrapper exited before fixture readiness ($($wrapper.ExitCode))." }
        Start-Sleep -Milliseconds 100
    }
    if ($rows.Count -ne 2) { throw 'Fixture supervisor and grandchild did not become ready.' }
    foreach ($row in $rows) {
        $child = [Diagnostics.Process]::GetProcessById([int]$row.pid)
        [void]$child.Handle
        $children += $child
    }
    $wrapper.Kill()
    if (-not $wrapper.WaitForExit(5000)) { throw 'Isolated wrapper did not terminate.' }
    foreach ($child in $children) {
        if (-not $child.WaitForExit(5000)) { throw "Job left fixture process $($child.Id) running." }
    }
    Write-Output 'PASS: forced PowerShell termination killed Supervisor and grandchild; paths with spaces work.'

    if (-not ('PhoneBridge.Desktop.KillOnCloseJob' -as [type])) { Add-Type -Path $helper }
    $job = New-Object PhoneBridge.Desktop.KillOnCloseJob
    $process = $job.StartSupervisor($NodePath, $exitFixture, $testRoot)
    $code = $process.WaitForExit()
    if ($code -ne 7) { throw "Child exit code was $code instead of 7." }
    Write-Output 'PASS: native child exit code 7 is preserved for retry decisions.'
} finally {
    if ($null -ne $process) { $process.Dispose() }
    if ($null -ne $job) { $job.Dispose() }
    if ($null -ne $wrapper) {
        if (-not $wrapper.HasExited) { $wrapper.Kill(); [void]$wrapper.WaitForExit(5000) }
        $wrapper.Dispose()
    }
    foreach ($child in $children) {
        if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
        $child.Dispose()
    }
    [Environment]::SetEnvironmentVariable('PHONEBRIDGE_JOB_TEST_RECORD', $previousRecord, 'Process')
    # Delete only this test's exact files, never a recursively computed target.
    foreach ($file in @($fixture, $wrapperPath, $record, $exitFixture)) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $testRoot
}
