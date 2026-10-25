#requires -Version 5.1
function New-PhoneBridgePackageArchive {
    param([Parameter(Mandatory)][string]$SourceDirectory, [Parameter(Mandatory)][string]$ArchivePath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $destination = [IO.Path]::GetFullPath($ArchivePath)
    $prefix = $source + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Directory]::Exists($source) -or $destination.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'The ZIP output must be outside the package source directory.' }
    $stream = $null; $archive = $null; $created = $false
    try {
        $stream = [IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); $created = $true
        $archive = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach ($item in @(Get-ChildItem -LiteralPath $source -Recurse -Force | Sort-Object FullName)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A package archive must not contain links.' }
            $name = $item.FullName.Substring($prefix.Length).Replace('\','/')
            if ($item.PSIsContainer) { [void]$archive.CreateEntry($name + '/') }
            else { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$item.FullName,$name,[IO.Compression.CompressionLevel]::Optimal) }
        }
        $archive.Dispose(); $archive = $null; $stream.Dispose(); $stream = $null
    } catch {
        if ($archive) { $archive.Dispose(); $archive = $null }; if ($stream) { $stream.Dispose(); $stream = $null }
        if ($created -and [IO.File]::Exists($destination)) { [IO.File]::Delete($destination) }
        throw
    } finally { if ($archive) { $archive.Dispose() }; if ($stream) { $stream.Dispose() } }
}

function Test-PhoneBridgeInstallerPackage {
    param([Parameter(Mandatory)][string]$InstallerPath, [Parameter(Mandatory)][string]$ReportPath, [Parameter(Mandatory)][string]$Version)
    $installer = [IO.Path]::GetFullPath($InstallerPath); $report = [IO.Path]::GetFullPath($ReportPath)
    if ($report -match '["\r\n]' -or [IO.File]::Exists($report)) { throw 'Choose a new safe installer diagnostic report path.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $installer; $start.Arguments = '--diagnose --report-path "{0}"' -f $report
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    try {
        [void]$process.Start(); $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'The installer read-only diagnostic timed out.' }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000)) { throw 'The installer diagnostic output did not close.' }
        if ($process.ExitCode -ne 0) { throw ('The actual installer rejected its embedded package: ' + $stderr.Result.Trim()) }
    } finally { $process.Dispose() }
    if (-not [IO.File]::Exists($report)) { throw 'The actual installer did not publish its diagnostic report.' }
    $result = Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.product -ne 'PhoneBridge' -or $result.version -ne $Version -or $result.platform -ne 'windows-x64' -or
        $result.dryRun -ne $true -or $result.embeddedPackageValid -ne $true -or $result.pathContainmentPassed -ne $true) { throw 'The actual installer diagnostic report is invalid.' }
    return $result
}
