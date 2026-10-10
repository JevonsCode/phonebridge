function Invoke-PhoneBridgeSetupTransaction {
    param([scriptblock]$Install, [scriptblock]$CreateShortcut, [scriptblock]$RestoreConfiguration,
          [scriptblock]$RestoreTask, [scriptblock]$RemoveNewTask, [bool]$HadTask)
    $installed = $false
    try { & $Install; $installed = $true; & $CreateShortcut }
    catch {
        $originalFailure = $_
        if ($installed -and -not $HadTask) { & $RemoveNewTask }
        if ($HadTask) { & $RestoreTask }
        & $RestoreConfiguration
        throw $originalFailure
    }
}
