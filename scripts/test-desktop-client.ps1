#requires -Version 5.1
[CmdletBinding()]
param([string]$PackageDirectory, [string]$Version='0.6.0')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Exercise the same Windows PowerShell 5.1 host used by the installer and task,
# including an inherited PowerShell 7 environment when invoked from pwsh.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $native=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Version',$Version)
    if($PackageDirectory){$arguments+=@('-PackageDirectory',$PackageDirectory)}
    & $native @arguments
    if($LASTEXITCODE -ne 0){throw 'Native Windows PowerShell desktop checks failed.'}
    return
}
$project=Split-Path $PSScriptRoot -Parent
& (Join-Path $project 'desktop\test-setup-transaction.ps1')
& (Join-Path $project 'desktop\test-allow-lan.ps1')
if ($PackageDirectory) { $runtime=Join-Path $PackageDirectory 'runtime\node.exe'; $entry=Join-Path $PackageDirectory 'desktop\server.mjs' } else { $runtime=(Get-Command node.exe -CommandType Application | Select-Object -First 1).Source; $entry=Join-Path $project 'desktop\server.mjs' }
& $runtime $entry --self-test
if ($LASTEXITCODE -ne 0) { throw 'Desktop self-test failed.' }
if ($PackageDirectory) {
    $priorPath=$env:PATH
    try { $env:PATH=Join-Path $env:SystemRoot 'System32'; & $runtime $entry --diagnose; if ($LASTEXITCODE -ne 0) { throw 'PATH-independent diagnostics failed.' }; $p=Start-Process -FilePath (Join-Path $PackageDirectory 'PhoneBridge.exe') -ArgumentList '--diagnose' -WindowStyle Hidden -Wait -PassThru; if ($p.ExitCode -ne 0) { throw 'Portable launcher diagnostics failed.' } } finally { $env:PATH=$priorPath }
    & $runtime (Join-Path $project 'desktop\integration-test.mjs') $PackageDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Isolated desktop integration failed.' }
}
Write-Output 'PhoneBridge desktop checks passed; no live service or configuration changes.'
