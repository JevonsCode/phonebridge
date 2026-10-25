#requires -Version 5.1
[CmdletBinding()]
param([ValidatePattern('^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$')][string]$Version='0.6.2', [string]$OutputDirectory, [string]$NodeVersion='22.23.3', [string]$FlutterBuildDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project = Split-Path $PSScriptRoot -Parent
if (-not $FlutterBuildDirectory) {
  Push-Location -LiteralPath (Join-Path $project 'desktop_app')
  try {
    & flutter build windows --release --build-name $Version
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows compilation failed.' }
  } finally { Pop-Location }
  $FlutterBuildDirectory=Join-Path $project 'desktop_app\build\windows\x64\runner\Release'
}
$FlutterBuildDirectory=[IO.Path]::GetFullPath($FlutterBuildDirectory)
foreach ($required in @('PhoneBridge.exe','flutter_windows.dll','data\flutter_assets\AssetManifest.bin')) {
  if (-not (Test-Path -LiteralPath (Join-Path $FlutterBuildDirectory $required))) { throw "Missing Flutter release file: $required" }
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $project 'artifacts\desktop' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$stage=Join-Path $OutputDirectory "stage-$Version"
if (Test-Path -LiteralPath $stage) { throw "Packaging stage already exists: $stage. Choose a new output directory or remove this exact stage manually." }
[void](New-Item -ItemType Directory -Path $stage)
Get-ChildItem -LiteralPath $FlutterBuildDirectory | Copy-Item -Destination $stage -Recurse
# App-local CRT permits opening the Flutter window on a clean Windows machine.
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'Visual C++ redistributable location unavailable.' }
$redistVersion=(Get-Content -LiteralPath (Join-Path $vsRoot 'VC\Auxiliary\Build\Microsoft.VCRedistVersion.default.txt') -Raw).Trim()
$redistRoot=Join-Path $vsRoot "VC\Redist\MSVC\$redistVersion\x64"
$crt=@(Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object Name -Match '^Microsoft\.VC\d+\.CRT$')
if ($crt.Count -ne 1) { throw 'Matching x64 Visual C++ runtime not found.' }
Get-ChildItem -LiteralPath $crt[0].FullName -Filter '*.dll' -File | Copy-Item -Destination $stage
foreach ($required in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Missing C++ runtime: $required" }
}
[IO.File]::WriteAllText((Join-Path $stage 'THIRD-PARTY-NOTICES.txt'), "Includes Microsoft Visual C++ Runtime $redistVersion (x64), redistributed from Visual Studio. Copyright Microsoft Corporation. Noto Sans SC is distributed under the SIL Open Font License in data/flutter_assets/assets/fonts/OFL.txt.`n")
$cache=Join-Path $OutputDirectory 'node-cache'
[void](New-Item -ItemType Directory -Path $cache -Force)
if ($NodeVersion -notmatch '^22\.\d+\.\d+$') { throw 'Use a pinned official Node 22 version.' }
$archiveName="node-v$NodeVersion-win-x64.zip"
$sumsUrl="https://nodejs.org/dist/v$NodeVersion/SHASUMS256.txt"
$sums=Invoke-RestMethod -Uri $sumsUrl
$entry=@($sums -split "`n" | Where-Object { $_ -match "  $([regex]::Escape($archiveName))$" })
if ($entry.Count -ne 1) { throw 'Pinned Node archive missing from official SHA256 list.' }
$expected=($entry[0] -split '\s+')[0]
$archive=Join-Path $cache $archiveName
if (-not (Test-Path -LiteralPath $archive)) { Invoke-WebRequest -Uri "https://nodejs.org/dist/v$NodeVersion/$archiveName" -OutFile $archive }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Official Node archive hash mismatch.' }
$expanded=Join-Path $cache "node-v$NodeVersion-win-x64"
if (-not (Test-Path -LiteralPath $expanded)) { Expand-Archive -LiteralPath $archive -DestinationPath $cache }
[void](New-Item -ItemType Directory -Path (Join-Path $stage 'runtime'))
Copy-Item -LiteralPath (Join-Path $expanded 'node.exe') -Destination (Join-Path $stage 'runtime\node.exe')
Copy-Item -LiteralPath (Join-Path $expanded 'LICENSE') -Destination (Join-Path $stage 'runtime\LICENSE')
$node=Join-Path $expanded 'node.exe'; $npm=Join-Path $expanded 'node_modules\npm\bin\npm-cli.js'
Push-Location -LiteralPath (Join-Path $project 'bridge')
try { & $node $npm ci --ignore-scripts; if ($LASTEXITCODE -ne 0) { throw 'Bridge dependency installation failed.' }; & $node $npm run build; if ($LASTEXITCODE -ne 0) { throw 'Bridge compilation failed.' } } finally { Pop-Location }
[void](New-Item -ItemType Directory -Path (Join-Path $stage 'bridge'))
Copy-Item -LiteralPath (Join-Path $project 'bridge\dist') -Destination (Join-Path $stage 'bridge\dist') -Recurse
Copy-Item -LiteralPath (Join-Path $project 'bridge\package.json'),(Join-Path $project 'bridge\package-lock.json') -Destination (Join-Path $stage 'bridge')
Push-Location -LiteralPath (Join-Path $stage 'bridge')
try { & $node $npm ci --omit=dev --ignore-scripts; if ($LASTEXITCODE -ne 0) { throw 'Production dependencies failed.' } } finally { Pop-Location }
Copy-Item -LiteralPath (Join-Path $project 'desktop') -Destination (Join-Path $stage 'desktop') -Recurse
# Windows carries only its runtime sources; Mac code and protocol fixtures are development inputs.
$stageRoot=[IO.Path]::GetFullPath($stage).TrimEnd([IO.Path]::DirectorySeparatorChar)
foreach ($directory in @('macos','test')) {
  $stageChild=[IO.Path]::GetFullPath((Join-Path $stageRoot "desktop\$directory"))
  if (-not $stageChild.StartsWith($stageRoot + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($stageChild) -ne (Join-Path $stageRoot 'desktop')) { throw 'Unsafe Windows payload exclusion path.' }
  if (Test-Path -LiteralPath $stageChild) { Remove-Item -LiteralPath $stageChild -Recurse -Force }
}
[void](New-Item -ItemType Directory -Path (Join-Path $stage 'scripts'))
Copy-Item -LiteralPath (Join-Path $project 'scripts\windows') -Destination (Join-Path $stage 'scripts\windows') -Recurse
Copy-Item -LiteralPath (Join-Path $project 'LICENSE') -Destination $stage
$manifest=[ordered]@{product='PhoneBridge';version=$Version;platform='windows-x64';nodeVersion=$NodeVersion;nodeArchiveSHA256=$expected;nodeSource="https://nodejs.org/dist/v$NodeVersion/$archiveName"}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw 'Windows .NET Framework C# compiler missing.' }
& $csc /nologo /target:exe /optimize+ /reference:System.Web.Extensions.dll "/out:$(Join-Path $stage 'PhoneBridgeMcp.exe')" (Join-Path $project 'desktop\McpLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Stable MCP launcher compilation failed.' }
# No development source, test artifacts, private pairing, npm binary or TypeScript toolchain in the payload.
Get-ChildItem -LiteralPath (Join-Path $stage 'desktop') -File | Where-Object Extension -eq '.cs' | Remove-Item
Remove-Item -LiteralPath (Join-Path $stage 'desktop\integration-test.mjs')
Get-ChildItem -LiteralPath (Join-Path $stage 'desktop') -Filter 'test-*.ps1' -File | Remove-Item
$zip=Join-Path $OutputDirectory "phonebridge-$Version-windows-x64.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip,[IO.Compression.CompressionLevel]::Optimal,$false)
$installerSource=Join-Path $OutputDirectory 'Installer.generated.cs'
(Get-Content -LiteralPath (Join-Path $project 'desktop\Installer.cs') -Raw -Encoding UTF8).Replace('__VERSION__',$Version) | Set-Content -LiteralPath $installerSource -Encoding UTF8
$installer=Join-Path $OutputDirectory "phonebridge-$Version-windows-setup.exe"
& $csc /nologo /target:winexe /optimize+ /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "/win32icon:$(Join-Path $project 'assets\brand\phonebridge.ico')" "/resource:$zip,PhoneBridgePackage" "/out:$installer" $installerSource
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
foreach ($file in @($zip,$installer)) { $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant(); [IO.File]::WriteAllText("$file.sha256", "$hash  $([IO.Path]::GetFileName($file))`n", (New-Object Text.UTF8Encoding($false))) }
Write-Output $zip
Write-Output $installer
