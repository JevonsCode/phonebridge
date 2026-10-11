#requires -Version 5.1
function Assert-PhoneBridgeMcpBootstrap {
    param([Parameter(Mandatory)][string]$Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $owner = [IO.File]::GetAccessControl($Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne $sid) { throw 'The stable MCP launcher belongs to another user.' }
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
function Install-PhoneBridgeMcpLauncher {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$StateDirectory)
    $ErrorActionPreference = 'Stop'
    $directory = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'bin'
    [void][IO.Directory]::CreateDirectory($directory)
    if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The stable MCP directory must not be a link.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ([IO.Directory]::GetAccessControl($directory).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid) { throw 'The stable MCP directory belongs to another user.' }
    $destination = Join-Path $directory 'PhoneBridgeMcp.exe'
    if (Test-Path -LiteralPath $destination) {
        if ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The stable MCP launcher must not be a link.' }
        Assert-PhoneBridgeMcpBootstrap $destination
        return $destination # Never replace a running executable, including on upgrades.
    }
    $temporary = Join-Path $directory ('mcp-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        Assert-PhoneBridgeMcpBootstrap $temporary
        [IO.File]::Move($temporary, $destination) # Atomic and exclusive; never overwrite.
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    return $destination
}
