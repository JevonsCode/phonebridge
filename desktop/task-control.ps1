#requires -Version 5.1
param([Parameter(Mandatory)][string]$ConfigurationPath)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\run-desktop.ps1') -LoadHelpers
$config=Read-PhoneBridgeDesktopConfiguration $ConfigurationPath
$task=@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object TaskName -eq 'PhoneBridge Desktop')
if ($task.Count -eq 0) { exit 2 }
Assert-PhoneBridgeTaskOwnership $task[0] $config $ConfigurationPath
Start-ScheduledTask -TaskName 'PhoneBridge Desktop' -TaskPath '\'
exit 0
