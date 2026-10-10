#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'allow-lan.ps1') -LoadHelpers
function Assert($condition,[string]$message) { if(-not $condition){throw $message} }
function Reject([scriptblock]$operation) { $rejected=$false;try{& $operation | Out-Null}catch{$rejected=$true};Assert $rejected 'Unsafe firewall plan accepted.' }
$config=[pscustomobject]@{ownerSid='S-1-5-21-test';port=8767;nodePath='C:\PhoneBridge\runtime\node.exe'}
$empty=New-PhoneBridgeLanPlan $config @();Assert ($empty.Create -and $empty.RemoveNames.Count -eq 0) 'Fresh install must support no application rules.'
function Block([string]$protocol='TCP',[string]$program=$config.nodePath) {
    return [pscustomobject]@{Name="$protocol Query User{723EB43D-C4CB-41E3-BC40-DDC1A2D7018D}$program";Description='';Program=$program;Action='Block';Direction='Inbound';Enabled='True';Source='Local';Profile='Private, Public';Protocol=$protocol;LocalPort='Any';RemoteAddress='Any';LocalAddress='Any'}
}
$own=Block; $foreign=Block 'TCP' 'C:\Other\node.exe';$ownUdp=Block 'UDP'
$plan=New-PhoneBridgeLanPlan $config @($own,$foreign,$ownUdp)
Assert $plan.Create 'First approval should create rule.'
Assert ($plan.RemoveNames.Count -eq 1 -and $plan.RemoveNames[0] -eq $own.Name) 'Foreign runtime rule selected.'
Assert ($plan.RemoveNames -notcontains $ownUdp.Name) 'UDP block must remain untouched.'
$managed=[pscustomobject]@{Name=$plan.Name;Description=$plan.Description;Program='Any';Action='Allow';Direction='Inbound';Enabled='True';Source='Local';Profile='Private';Protocol='TCP';LocalPort='8767';RemoteAddress='LocalSubnet';LocalAddress='Any'}
Assert (-not (New-PhoneBridgeLanPlan $config @($managed)).Create) 'Idempotent approval created duplicate.'
foreach ($field in @('Description','Source','Profile','Protocol','LocalPort','RemoteAddress','Program')) {
    $modified=$managed.PSObject.Copy();$modified.$field='foreign'
    Reject { New-PhoneBridgeLanPlan $config @($modified) }
}
$custom=$own.PSObject.Copy();$custom.Name='Company policy';Reject {New-PhoneBridgeLanPlan $config @($custom)}
$policy=$own.PSObject.Copy();$policy.Source='GroupPolicy';Reject {New-PhoneBridgeLanPlan $config @($policy)}
$portBlock=$own.PSObject.Copy();$portBlock.LocalPort='443';Reject {New-PhoneBridgeLanPlan $config @($portBlock)}
$script:changes=New-Object 'System.Collections.Generic.List[string]'
Invoke-PhoneBridgeLanPlan $plan {param($p)$script:changes.Add("allow:$($p.Port)")} {param($n)$script:changes.Add("remove:$n")}
Assert ($changes.Count -eq 2 -and $changes[0] -eq 'allow:8767' -and $changes[1] -eq "remove:$($own.Name)") 'Plan did not establish narrow allow before exact deletion.'
$script:changes.Clear()
Reject {Invoke-PhoneBridgeLanPlan $plan {throw 'Access denied'} {param($n)$script:changes.Add($n)}}
Assert ($changes.Count -eq 0) 'Block removed after rule creation failed.'
# Exercise the full script entry point: dot-sourced task helpers also declare
# ConfigurationPath/ValidateOnly. Those parameters must not overwrite this mode.
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('PhoneBridge-firewall-'+[Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'desktop'),(Join-Path $fixture 'scripts\windows'),(Join-Path $fixture 'runtime') | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'allow-lan.ps1') -Destination (Join-Path $fixture 'desktop\allow-lan.ps1')
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\run-desktop.ps1') -Destination (Join-Path $fixture 'scripts\windows\run-desktop.ps1')
    Set-Content -LiteralPath (Join-Path $fixture 'runtime\node.exe') -Value 'dry-run fixture'
    @{product='PhoneBridge';platform='windows-x64'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $fixture 'package-manifest.json')
    $isolated=@{schema='phonebridge-desktop-v1';ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;projectRoot=$fixture;nodePath=Join-Path $fixture 'runtime\node.exe';hostAddress='192.168.1.20';port=48767;launcherPath=Join-Path $fixture 'scripts\windows\run-desktop.ps1';powershellPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'}
    $isolatedPath=Join-Path $fixture 'isolated config.json';$isolated|ConvertTo-Json|Set-Content -LiteralPath $isolatedPath -Encoding UTF8
    function Get-NetFirewallApplicationFilter { @() }
    function Get-NetFirewallRule { @() }
    function Start-Process { throw 'Dry run attempted elevation.' }
    function New-NetFirewallRule { throw 'Dry run attempted firewall mutation.' }
    function Remove-NetFirewallRule { throw 'Dry run attempted firewall mutation.' }
    $result=(& (Join-Path $fixture 'desktop\allow-lan.ps1') -ConfigurationPath $isolatedPath -ValidateOnly)|ConvertFrom-Json
    Assert ($result.Port -eq 48767 -and $result.Create -and $result.RemoveNames.Count -eq 0) 'CLI dry run lost its isolated config/mode.'
    $elevationCapture=New-Object 'System.Collections.Generic.List[object]'
    function Start-Process {
        param($FilePath,$ArgumentList,$Verb,$WindowStyle,[switch]$Wait,[switch]$PassThru)
        $elevationCapture.Add(@{Verb=$Verb;Wait=[bool]$Wait;PassThru=[bool]$PassThru;ArgumentList=$ArgumentList})
        return [pscustomobject]@{ExitCode=0}
    }
    & (Join-Path $fixture 'desktop\allow-lan.ps1') -ConfigurationPath $isolatedPath -RequestElevation | Out-Null
    Assert ($elevationCapture.Count -eq 1) 'Opt-in action did not request exactly one owner elevation.'
    $elevationParameters=$elevationCapture[0]
    Assert ($elevationParameters.Verb -eq 'RunAs' -and $elevationParameters.Wait -and $elevationParameters.PassThru -and $elevationParameters.ArgumentList.Contains(' -Apply') -and $elevationParameters.ArgumentList.Contains($isolatedPath)) ('Incorrect owner elevation request: '+($elevationParameters|ConvertTo-Json -Compress))
} finally {
    $absolute=[IO.Path]::GetFullPath($fixture);$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $absolute.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup.'}
    if(Test-Path -LiteralPath $absolute){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
Write-Output 'LAN firewall tests passed: exact runtime scope, foreign/policy collision rejection, Private/LocalSubnet port, idempotence, add-before-remove. No firewall changed.'
