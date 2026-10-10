#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'setup-transaction.ps1')
foreach($hadConfig in @($false,$true)) {
    foreach($hadTask in @($false,$true)) {
        if($hadTask -and -not $hadConfig){continue}
        $script:testConfiguration=if($hadConfig){'old-config'}else{$null}
        $script:testTask=if($hadTask){'old-task'}else{$null}
        $failed=$false
        try {
            Invoke-PhoneBridgeSetupTransaction -HadTask $hadTask -Install {$script:testConfiguration='new-config';$script:testTask='new-task'} -CreateShortcut {throw 'Simulated shortcut write failure'} -RemoveNewTask {$script:testTask=$null} -RestoreTask {$script:testTask='old-task'} -RestoreConfiguration {$script:testConfiguration=if($hadConfig){'old-config'}else{$null}}
        } catch { $failed=$true }
        if(-not $failed){throw 'Expected installation failure was not propagated'}
        $expectedConfig=if($hadConfig){'old-config'}else{$null};$expectedTask=if($hadTask){'old-task'}else{$null}
        if($script:testConfiguration -ne $expectedConfig -or $script:testTask -ne $expectedTask){throw 'Setup rollback left configuration/task ownership mismatched'}
    }
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) "phonebridge-shortcut-test-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $fixture)
try {
    [IO.File]::WriteAllText((Join-Path $fixture 'PhoneBridge.exe'),'test fixture, never executed')
    . (Join-Path $PSScriptRoot 'shortcut.ps1') -PackageRoot $fixture -LoadHelpers
    $owned=Join-Path $fixture 'owned.lnk'
    Set-PhoneBridgeOwnedShortcut $owned
    Set-PhoneBridgeOwnedShortcut $owned
    $shell=New-Object -ComObject WScript.Shell
    if($shell.CreateShortcut($owned).TargetPath -ne (Join-Path $fixture 'PhoneBridge.exe')){throw 'Owned shortcut not idempotent'}
    $foreign=Join-Path $fixture 'foreign.lnk';$link=$shell.CreateShortcut($foreign);$link.TargetPath=Join-Path $fixture 'foreign.exe';$link.Description='Owner created this shortcut';$link.Save()
    $before=(Get-FileHash -LiteralPath $foreign).Hash;$refused=$false
    try { Set-PhoneBridgeOwnedShortcut $foreign } catch { $refused=$true }
    if(-not $refused -or (Get-FileHash -LiteralPath $foreign).Hash -ne $before){throw 'Foreign shortcut was overwritten'}
    $versions=Join-Path $fixture 'versions';$oldBundle=Join-Path $versions '0.6.0\bundle-8d1901127603';$newBundle=Join-Path $versions '0.6.0\bundle-c06a02a4852d'
    [void](New-Item -ItemType Directory -Path $oldBundle,$newBundle)
    foreach($bundle in @($oldBundle,$newBundle)){[IO.File]::WriteAllText((Join-Path $bundle 'PhoneBridge.exe'),'shortcut migration fixture, never executed')}
    . (Join-Path $PSScriptRoot 'shortcut.ps1') -PackageRoot $oldBundle -LoadHelpers
    $upgradeLink=Join-Path $fixture 'upgrade.lnk';Set-PhoneBridgeOwnedShortcut $upgradeLink -ManagedVersionRoots @($versions)
    $marker=$shell.CreateShortcut($upgradeLink).Description
    . (Join-Path $PSScriptRoot 'shortcut.ps1') -PackageRoot $newBundle -LoadHelpers
    Set-PhoneBridgeOwnedShortcut $upgradeLink -ManagedVersionRoots @($versions)
    $upgraded=$shell.CreateShortcut($upgradeLink)
    if($upgraded.TargetPath -ne (Join-Path $newBundle 'PhoneBridge.exe') -or $upgraded.Description -ne $marker){throw 'Prior managed bundle shortcut did not migrate to current bundle'}
    # A copied owner marker alone never authorizes a path outside managed versions.
    $copied=Join-Path $fixture 'copied-marker.lnk';$link=$shell.CreateShortcut($copied);$link.TargetPath=Join-Path $fixture 'PhoneBridge.exe';$link.Description=$marker;$link.Save()
    $before=(Get-FileHash -LiteralPath $copied).Hash;$refused=$false
    try {Set-PhoneBridgeOwnedShortcut $copied -ManagedVersionRoots @($versions)}catch{$refused=$true}
    if(-not $refused -or (Get-FileHash -LiteralPath $copied).Hash -ne $before){throw 'Marker copy allowed a foreign shortcut target'}
} finally {
    $resolvedFixture=[IO.Path]::GetFullPath($fixture)
    $safeParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolvedFixture.StartsWith($safeParent,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
}
Write-Output 'Setup rollback matrix, native-owned shortcut idempotence, old-bundle upgrade and foreign marker-copy refusal passed. No live tasks or configuration changed.'
