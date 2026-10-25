#requires -Version 5.1
function Invoke-PhoneBridgeConfigurationLock {
    param([Alias('ConfigurationPath')][Parameter(Mandatory)][string]$LockConfigurationPath, [Parameter(Mandatory)][scriptblock]$Operation, [int]$TimeoutMs = 1500)
    $canonical = [IO.Path]::GetFullPath($LockConfigurationPath).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object Threading.Mutex($false, "Local\PhoneBridgeConfig-v1-$sid-$key")
    $held = $false
    try {
        try { $held = $mutex.WaitOne($TimeoutMs) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Configuration publication is busy. It will be retried.' }
        & $Operation
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function ConvertTo-PhoneBridgeCanonicalJsonValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $ordered = [ordered]@{}
        $keys = if ($Value -is [Collections.IDictionary]) { @($Value.Keys | Sort-Object) } else { @($Value.PSObject.Properties.Name | Sort-Object) }
        foreach ($key in $keys) { $ordered[$key] = ConvertTo-PhoneBridgeCanonicalJsonValue $Value.$key }
        return $ordered
    }
    if ($Value -is [array]) { $items = @($Value | ForEach-Object { ConvertTo-PhoneBridgeCanonicalJsonValue $_ }); return ,$items }
    return $Value
}
function Assert-PhoneBridgeExpectedConfiguration {
    param([string]$ConfigurationPath, $ExpectedConfiguration, [switch]$RequireAbsent)
    if ($RequireAbsent) { if ([IO.File]::Exists($ConfigurationPath)) { throw 'Desktop configuration changed. The newer configuration was preserved.' }; return }
    if (-not [IO.File]::Exists($ConfigurationPath)) { throw 'Desktop configuration changed. The newer configuration was preserved.' }
    $item = Get-Item -LiteralPath $ConfigurationPath -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt 32768) { throw 'Invalid desktop configuration file.' }
    $current = [IO.File]::ReadAllText($ConfigurationPath) | ConvertFrom-Json
    $a = ConvertTo-PhoneBridgeCanonicalJsonValue $current | ConvertTo-Json -Depth 100 -Compress
    $b = ConvertTo-PhoneBridgeCanonicalJsonValue $ExpectedConfiguration | ConvertTo-Json -Depth 100 -Compress
    if ($a -cne $b) { throw 'Desktop configuration changed. The newer configuration was preserved.' }
}
function Publish-PhoneBridgeAtomicConfiguration {
    param([Parameter(Mandatory)][string]$TemporaryPath, [Parameter(Mandatory)][string]$ConfigurationPath, $ExpectedConfiguration, [switch]$RequireAbsent)
    $temporary = [IO.Path]::GetFullPath($TemporaryPath)
    $destination = [IO.Path]::GetFullPath($ConfigurationPath)
    if ($temporary -eq $destination) { throw 'Atomic configuration publication requires a separate temporary file.' }
    $compare = $PSBoundParameters.ContainsKey('ExpectedConfiguration') -or $RequireAbsent
    Invoke-PhoneBridgeConfigurationLock $destination {
      if ($compare) { Assert-PhoneBridgeExpectedConfiguration $destination $ExpectedConfiguration -RequireAbsent:$RequireAbsent }
      if ([IO.File]::Exists($destination)) {
        # Windows PowerShell 5.1 binds $null to an empty string for this .NET
        # overload, which File.Replace rejects. Use a real, unique backup path.
        # Keep this recovery copy; publication and rollback use the same primitive.
        $recovery = "$destination.atomic-backup-$([Guid]::NewGuid().ToString('N'))"
        [IO.File]::Replace($temporary, $destination, $recovery)
      } else {
        [IO.File]::Move($temporary, $destination)
      }
    }
}
function Remove-PhoneBridgeAtomicConfiguration {
    param([Parameter(Mandatory)][string]$ConfigurationPath, [Parameter(Mandatory)]$ExpectedConfiguration)
    Invoke-PhoneBridgeConfigurationLock $ConfigurationPath {
        Assert-PhoneBridgeExpectedConfiguration $ConfigurationPath $ExpectedConfiguration
        [IO.File]::Delete($ConfigurationPath)
    }
}
# No script-level param block: dot-sourcing this helper must not replace the caller's config variables.
if ($MyInvocation.InvocationName -ne '.' -and $args.Count -gt 0) {
    $ErrorActionPreference = 'Stop'
    if ($args.Count -ne 4 -or $args[0] -ne '--publish') { throw 'Invalid atomic configuration helper arguments.' }
    if ($args[3] -eq '--absent') { Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $args[1] -ConfigurationPath $args[2] -RequireAbsent }
    else {
        $expected = [IO.File]::ReadAllText([IO.Path]::GetFullPath($args[3])) | ConvertFrom-Json
        Publish-PhoneBridgeAtomicConfiguration -TemporaryPath $args[1] -ConfigurationPath $args[2] -ExpectedConfiguration $expected
    }
}
