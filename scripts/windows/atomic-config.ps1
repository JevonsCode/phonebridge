#requires -Version 5.1
function Publish-PhoneBridgeAtomicConfiguration {
    param([Parameter(Mandatory)][string]$TemporaryPath, [Parameter(Mandatory)][string]$ConfigurationPath)
    $temporary = [IO.Path]::GetFullPath($TemporaryPath)
    $destination = [IO.Path]::GetFullPath($ConfigurationPath)
    if ($temporary -eq $destination) { throw 'Atomic configuration publication requires a separate temporary file.' }
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
