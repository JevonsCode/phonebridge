param([string]$Serial = 'emulator-5580', [int]$Port = 8766)
$ErrorActionPreference = 'Stop'
if ($Serial -notmatch '^emulator-\d+$') { throw 'This helper only configures isolated emulator devices, never physical phones.' }
if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid test port.' }
$projectRoot = Split-Path $PSScriptRoot -Parent
$adbPath = (Get-Command adb).Source
$nodePath = (Get-Command node).Source
$hubProcess = $null
$watcher = $null
$previousToken = $env:PHONEBRIDGE_TOKEN
$previousPort = $env:PHONEBRIDGE_PORT
$previousHost = $env:PHONEBRIDGE_HOST
$previousNdk = $env:PHONEBRIDGE_NDK_PATH
$artifactDir = Join-Path $projectRoot 'artifacts'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
Push-Location $projectRoot
try {
    & npm --prefix bridge run build
    if ($LASTEXITCODE -ne 0) { throw 'Bridge build failed.' }
    & $adbPath -s $Serial reverse "tcp:$Port" "tcp:$Port"
    if ($LASTEXITCODE -ne 0) { throw 'Emulator USB reverse failed.' }
    $watcher = Start-Job -ArgumentList $adbPath, $Serial -ScriptBlock {
        param($adb, $device)
        for ($attempt = 0; $attempt -lt 300; $attempt++) {
            $installed = & $adb -s $device shell pm path dev.phonebridge.phonebridge 2>$null
            if ($installed) {
                $enabled = & $adb -s $device shell settings get secure enabled_accessibility_services
                if ($enabled -notmatch 'phonebridge') {
                    & $adb -s $device shell settings put secure enabled_accessibility_services dev.phonebridge.phonebridge/dev.phonebridge.phonebridge.PhoneAccessibilityService
                    & $adb -s $device shell settings put secure accessibility_enabled 1
                }
            }
            Start-Sleep -Seconds 2
        }
    }
    $env:PHONEBRIDGE_TOKEN = & $nodePath -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
    $env:PHONEBRIDGE_PORT = "$Port"
    $env:PHONEBRIDGE_HOST = '127.0.0.1'
    $localNdk = Join-Path $artifactDir 'android-sdk/ndk/28.2.13676358'
    if (Test-Path "$localNdk/source.properties") { $env:PHONEBRIDGE_NDK_PATH = $localNdk }
    $hubProcess = Start-Process -FilePath $nodePath -ArgumentList "`"$projectRoot/bridge/dist/cli.js`"" -WindowStyle Hidden -RedirectStandardOutput "$artifactDir/hub-test.stdout.log" -RedirectStandardError "$artifactDir/hub-test.stderr.log" -PassThru
    Set-Location (Join-Path $projectRoot 'mobile')
    & flutter test integration_test/native_bridge_test.dart -d $Serial "--dart-define=PHONEBRIDGE_TEST_TOKEN=$env:PHONEBRIDGE_TOKEN" "--dart-define=PHONEBRIDGE_TEST_PORT=$Port"
    if ($LASTEXITCODE -ne 0) { throw 'Android integration test failed. See the test output.' }
} finally {
    if ($hubProcess -and -not $hubProcess.HasExited) { Stop-Process -Id $hubProcess.Id }
    if ($watcher) { Stop-Job $watcher; Remove-Job $watcher }
    & $adbPath -s $Serial reverse --remove "tcp:$Port"
    $env:PHONEBRIDGE_TOKEN = $previousToken
    $env:PHONEBRIDGE_PORT = $previousPort
    $env:PHONEBRIDGE_HOST = $previousHost
    $env:PHONEBRIDGE_NDK_PATH = $previousNdk
    Pop-Location
}
