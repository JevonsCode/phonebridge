param([Parameter(Mandatory=$true)][string]$ClaimPath,[Parameter(Mandatory=$true)][string]$OwnerSid)
$ErrorActionPreference='Stop'
$actualSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if($OwnerSid -ne $actualSid){throw 'Client recovery owner mismatch.'}
$absoluteClaim=[IO.Path]::GetFullPath($ClaimPath)
$digest=[Security.Cryptography.SHA256]::Create()
try{$key=[BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($actualSid+'|'+$absoluteClaim.ToLowerInvariant()))).Replace('-','')}finally{$digest.Dispose()}
$claimMutex=New-Object Threading.Mutex($false,('Local\PhoneBridgeClientRecovery-'+$key))
$locked=$false
try{
    try{$locked=$claimMutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$locked=$true}
    if(-not $locked){throw 'Client recovery is busy.'}
    if([IO.File]::Exists($absoluteClaim)){
        $recordPid=0
        if(-not [int]::TryParse([IO.File]::ReadAllText($absoluteClaim),[ref]$recordPid) -or $recordPid -le 0){throw 'Invalid client recovery record.'}
        $alive=$true
        try{$recordProcess=[Diagnostics.Process]::GetProcessById($recordPid);$recordProcess.Dispose()}catch [ArgumentException]{$alive=$false}
        if(-not $alive){[IO.File]::Delete($absoluteClaim)}
    }
}finally{if($locked){$claimMutex.ReleaseMutex()};$claimMutex.Dispose()}
