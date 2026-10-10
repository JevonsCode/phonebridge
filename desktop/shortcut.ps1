#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot, [switch]$StartupRepair, [switch]$ValidateOnly, [switch]$LoadHelpers)
$ErrorActionPreference='Stop'
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot)
$launcher=Join-Path $PackageRoot 'PhoneBridge.exe'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'PhoneBridge launcher missing.' }
if (-not ('PhoneBridge.ShortcutPaths' -as [type])) {
Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
namespace PhoneBridge { public static class ShortcutPaths {
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string p,uint access,uint share,IntPtr sec,uint mode,uint flags,IntPtr template);
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(IntPtr h,StringBuilder b,uint size,uint flags);
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
public static string Physical(string p){var h=CreateFile(p,128,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);if(h==new IntPtr(-1))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());try{var b=new StringBuilder(32768);if(GetFinalPathNameByHandle(h,b,32768,0)==0)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());return b.ToString().Replace(@"\\?\","");}finally{CloseHandle(h);}}
}}
'@
}
function Get-PhoneBridgePathOwnerSid([string]$Path) {
    # Read the SID directly through .NET, avoiding Get-Acl module autoload when
    # Windows PowerShell inherits a PowerShell 7 PSModulePath from an Agent.
    $security=[Security.AccessControl.FileSecurity]::new($Path,[Security.AccessControl.AccessControlSections]::Owner)
    return $security.GetOwner([Security.Principal.SecurityIdentifier]).Value
}
function Set-PhoneBridgeOwnedShortcut([string]$Path, [string[]]$ManagedVersionRoots=@(
    (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phonebridge\app\versions'),
    (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PhoneBridge\versions'))) {
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut($Path)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ownerMarker="PhoneBridge managed shortcut v1; owner=$sid"
    if (Test-Path -LiteralPath $Path) {
        $physicalLink=[PhoneBridge.ShortcutPaths]::Physical($Path)
        $target=[IO.Path]::GetFullPath($link.TargetPath)
        $managedTarget=($target -eq $launcher)
        foreach($versionRoot in $ManagedVersionRoots) {
            $prefix=[IO.Path]::GetFullPath($versionRoot).TrimEnd('\')+'\'
            if($target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
                $relative=$target.Substring($prefix.Length)
                if($relative -match '^\d+\.\d+\.\d+(?:\\bundle-[0-9a-f]{12})?\\PhoneBridge\.exe$'){$managedTarget=$true}
            }
        }
        if ($physicalLink -ne [IO.Path]::GetFullPath($Path) -or $link.Description -ne $ownerMarker -or
            $link.Arguments -ne '' -or [IO.Path]::GetFileName($target) -ne 'PhoneBridge.exe' -or -not $managedTarget -or
            (Get-PhoneBridgePathOwnerSid $physicalLink) -ne $sid -or -not (Test-Path -LiteralPath $target -PathType Leaf) -or
            (Get-PhoneBridgePathOwnerSid ([PhoneBridge.ShortcutPaths]::Physical($target))) -ne $sid) { throw 'Refusing to overwrite an existing foreign PhoneBridge shortcut.' }
    }
    $link.TargetPath=$launcher;$link.WorkingDirectory=$PackageRoot;$link.Description=$ownerMarker;$link.Save()
}
if ($LoadHelpers) { return }
$programs=[Environment]::GetFolderPath('Programs')
$physicalPrograms=[PhoneBridge.ShortcutPaths]::Physical($programs)
$menu=Join-Path $programs 'PhoneBridge'
$physicalMenu=if(Test-Path -LiteralPath $menu){[PhoneBridge.ShortcutPaths]::Physical($menu)}else{$null}
$menuLink=Join-Path $menu 'PhoneBridge.lnk'
$physicalMenuLink=if(Test-Path -LiteralPath $menuLink){[PhoneBridge.ShortcutPaths]::Physical($menuLink)}else{$null}
# A real Programs directory may contain an MSIX-shadowed .lnk. Check the existing
# link before COM reads/writes it; leave that shadow untouched and use Desktop.
$visible=([IO.Path]::GetFullPath($programs).TrimEnd('\') -eq $physicalPrograms.TrimEnd('\')) -and (-not $physicalMenu -or $physicalMenu.TrimEnd('\') -eq $menu.TrimEnd('\')) -and (-not $physicalMenuLink -or $physicalMenuLink -eq $menuLink)
if ($visible -and -not $ValidateOnly) {
    [void](New-Item -ItemType Directory -Path $menu -Force)
    # Existing shared Programs may be real while newly created child directories are virtualized.
    $visible=([PhoneBridge.ShortcutPaths]::Physical($menu).TrimEnd('\') -eq $menu.TrimEnd('\'))
}
if ($visible) {
    if ($ValidateOnly) { [pscustomobject]@{Mode='StartMenu';PhysicalDirectory=$physicalPrograms;DryRun=$true};return }
    $ownedLink=Join-Path $menu 'PhoneBridge.lnk'
    Set-PhoneBridgeOwnedShortcut $ownedLink
    $physicalLink=[PhoneBridge.ShortcutPaths]::Physical($ownedLink)
    if ($physicalLink -ne $ownedLink) { throw 'Start-menu shortcut was redirected unexpectedly.' }
    if ($StartupRepair) {
        $record=[ordered]@{schema='phonebridge-shortcut-v1';ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;physicalPath=$physicalLink;targetPath=$launcher;shortcutSHA256=(Get-FileHash -LiteralPath $ownedLink -Algorithm SHA256).Hash;repairedByProcessId=$PID}
        $report=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.phonebridge\shortcut-status.json'
        [IO.File]::WriteAllText($report,($record | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    }
} elseif (-not $StartupRepair) {
    # MSIX redirects AppData writes. A profile Desktop shortcut is physically visible immediately.
    $desktop=[Environment]::GetFolderPath('DesktopDirectory')
    $physicalDesktop=[PhoneBridge.ShortcutPaths]::Physical($desktop)
    if ($physicalDesktop -match '\\AppData\\Local\\Packages\\[^\\]+\\LocalCache\\') { throw 'Cannot establish a physically visible current-user shortcut directory.' }
    if ($ValidateOnly) { [pscustomobject]@{Mode='DesktopFallback';PhysicalDirectory=$physicalDesktop;DryRun=$true};return }
    Set-PhoneBridgeOwnedShortcut (Join-Path $physicalDesktop 'PhoneBridge.lnk')
}
