<#
=======================================================================
 OESU-Freeze.ps1
 Version 1.1  (2026-09-19)

 1.1  Prefer drivefs-results-<stamp>.csv over the transcript as the
      verification source. Sync-SharedDrives writes that CSV as the last
      thing it does, after the verify pass, so a CSV carrying this run's
      stamp is proof the run finished. The 17:15 run on 2026-09-19 copied
      all 498 files and wrote its results, but its transcript was still
      sitting unflushed in an open PowerShell window, which is
      indistinguishable from a run still in progress. v1.0 refused, which
      was the right call on the evidence it had. This version reads the
      better evidence.

 Freezes migrated server folders read only, running as SYSTEM through
 the OESU - Run Script launcher. No console session, no RDP.

 WHY THIS EXISTS AND HOW IT DIFFERS FROM Freeze-Migration.ps1
 Freeze-Migration.ps1 verifies each folder against its Shared Drive
 before freezing it. That needs to read Google Drive, and Drive for
 desktop mounts its filesystem for ONE user token. Tested on OESU2019
 on 2026-09-19: SYSTEM gets "Access is denied" on D:\Shared drives, not
 "not found". The volume is visible; the contents are not. So that
 script cannot run from Datto, ever.

 This script does the half that does not need Drive, and refuses to
 invent the half that does. It does not verify anything itself. It
 reads the verification Sync-SharedDrives.ps1 already wrote into its
 transcript, and freezes ONLY folders that reported zero differences
 in that run.

 THE SAFETY RULES, IN ORDER
   1. It finds the NEWEST drivefs-sync-*-transcript.txt and takes that
      run's stamp. If drivefs-results-<stamp>.csv exists, that is the
      verification source, because the sync writes it only after
      verifying. Otherwise it falls back to reading the transcript, and
      then insists on the transcript's end marker, since without the CSV
      that is the only evidence the run is not still going.
   2. If the source it used is older than MaxAgeHours, it refuses
      everything. Stale proof is not proof.
   3. If it had to fall back to the transcript and that transcript looks
      like a run still in progress, it refuses everything, so it can
      never freeze a folder mid-copy.
   4. A folder is frozen only if its run reported zero files still
      different. Anything else is skipped and named in the report.
   5. A folder with files open is skipped unless Force is true.
   6. Every folder's ACL is saved before it is touched.
   7. Nothing is ever deleted.

 ACTION  (Params: Action)
   report    Default. Reads everything, changes nothing, prints the
             plan. Launcher WhatIf=true forces this regardless.
   freeze    Do it.
   unfreeze  Put back every ACL this script saved, newest backup first.

 OTHER PARAMS
   Only          Comma separated Shared Drive names to limit to.
   MaxAgeHours   How old the sync transcript may be. Default 8.
   Force         true to close open files instead of skipping. Default false.
   DenyGroup     Broad group denied write on every frozen folder.
                 Default "Domain Users". This is what covers folders
                 whose only permissions are inherited, where there is
                 no specific group to deny. Every staff account is in
                 it; SYSTEM, Administrators and Backup Operators are
                 not, so backups and later sync passes still work.
                 Deny is (W,D,DC) only, so READ still works and an
                 administrator can still change permissions to undo it.

 OUTPUT
   C:\Migration\freeze-report-<stamp>.csv
   C:\Migration\freeze-acl-backup\  (one .acl per folder, plus oesu-freeze-index.csv)
   Machine readable lines start with PLAN|, FROZE|, SKIP| or INFO|.
=======================================================================
#>

$ErrorActionPreference = 'Continue'

$Computer = $env:COMPUTERNAME
$Version  = '1.1'
$Stamp    = Get-Date -Format 'yyyyMMdd-HHmm'

$Out        = if ($env:Out)     { $env:Out.TrimEnd('\') } else { 'C:\Migration' }
$MapCsv     = if ($env:MapCsv)  { $env:MapCsv }           else { Join-Path $Out 'drivefs-map.csv' }
$ActionRaw  = if ($env:Action)  { $env:Action.Trim().ToLower() } else { 'report' }
$MaxAge     = if ($env:MaxAgeHours) { [double]$env:MaxAgeHours } else { 8 }
$DenyGroup  = if ($env:DenyGroup)   { $env:DenyGroup.Trim() }    else { 'Domain Users' }
$Force      = ($env:Force -eq 'true')
$OnlyRaw    = if ($env:Only) { $env:Only } else { '' }
$Only       = @($OnlyRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# The launcher defaults WhatIf to true. Anything but an explicit false keeps us read only.
$IsWhatIf = -not ($env:WhatIf -eq 'false')
$Action   = $ActionRaw
if ($IsWhatIf -and $Action -ne 'report') {
    $Action = 'report'
    $ForcedToReport = $true
}

$AclDir = Join-Path $Out 'freeze-acl-backup'
$Index  = Join-Path $AclDir 'oesu-freeze-index.csv'
$Report = Join-Path $Out "freeze-report-$Stamp.csv"

# Never deny these or the server locks itself, and backups, and us, out.
$NeverDeny = @(
    'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'CREATOR OWNER', 'OWNER RIGHTS',
    'NT AUTHORITY\NETWORK SERVICE', 'NT AUTHORITY\LOCAL SERVICE',
    'BUILTIN\Backup Operators', 'BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users'
)
$WriteRights = @('FullControl','Modify','Write','WriteData','CreateFiles','AppendData',
                 'Delete','DeleteSubdirectoriesAndFiles','ChangePermissions','TakeOwnership')

function Say {
    param([Parameter(ValueFromPipeline = $true, Position = 0)][string]$m)
    process { Write-Host $m }
}

function Stop-Now([string]$reason, [string]$code) {
    Say ''
    Say "REFUSED: $reason"
    Say "INFO|$Computer|refused|$code"
    Say "DONE|OESU-Freeze|$Version|refused|$Computer"
    exit 1
}

function Get-SafeName([string]$p) { ($p -replace '[:\\/ ]+', '_').Trim('_') }

Say '======================================================================='
Say " OESU-Freeze v$Version   action: $Action"
Say " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($ForcedToReport) { Say ' NOTE: WhatIf was not explicitly false, so this is a REPORT ONLY run.' }
Say '======================================================================='
Say "BANNER|OESU-Freeze|$Version|$Action|$Computer"
Say ''

# ---------------------------------------------------------------- unfreeze

if ($Action -eq 'unfreeze') {
    if (-not (Test-Path -LiteralPath $Index)) { Stop-Now "No backup index at $Index. Nothing this script froze." 'noindex' }
    $rows = @(Import-Csv -LiteralPath $Index)
    # newest first, one restore per folder
    $rows = @($rows | Sort-Object Stamp -Descending | Group-Object Source | ForEach-Object { $_.Group[0] })
    Say "Restoring $($rows.Count) folder permission set(s)."
    foreach ($r in $rows) {
        if (-not (Test-Path -LiteralPath $r.AclFile)) { Say "  missing backup for $($r.Source), skipped"; continue }
        Say "  restoring $($r.Source)"
        & icacls.exe $r.Parent /restore $r.AclFile /C 2>&1 | Out-Null
        & icacls.exe $r.Source /remove:d "$($r.DenyApplied)" /T /C 2>&1 | Out-Null
    }
    Say "DONE|OESU-Freeze|$Version|unfreeze|$Computer"
    exit 0
}

# ---------------------------------------------------------------- the map

if (-not (Test-Path -LiteralPath $MapCsv)) { Stop-Now "Can't find $MapCsv." 'nomap' }
$map = @(Import-Csv -LiteralPath $MapCsv)
if ($Only.Count -gt 0) { $map = @($map | Where-Object { $Only -contains $_.SharedDrive }) }
if ($map.Count -eq 0) { Stop-Now 'Nothing in scope after filtering.' 'noscope' }

# ---------------------------------------------------------------- the proof

$tx = @(Get-ChildItem -LiteralPath $Out -Filter 'drivefs-sync-*-transcript.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
if ($tx.Count -eq 0) { Stop-Now "No drivefs-sync transcript in $Out. Nothing has been verified." 'notranscript' }

$latest = $tx[0]

# The run stamp: drivefs-sync-20260919-1715-transcript.txt -> 20260919-1715.
# Sync-SharedDrives writes drivefs-results-<stamp>.csv as the LAST thing it does,
# after the verify pass, so a results CSV carrying this run's stamp is proof the
# run finished. It is also better evidence than the transcript: structured, with
# an explicit StillDifferent column, and not subject to transcript buffering.
# On 2026-09-19 a finished run left its transcript unflushed because the window
# was still open, which reads exactly like a run still in progress.
$runStamp = ''
if ($latest.Name -match 'drivefs-sync-(.+?)-transcript\.txt$') { $runStamp = $Matches[1] }

$verified  = @{}
$usedCsv   = $false
$source    = $latest

if ($runStamp) {
    $csvPath = Join-Path $Out ("drivefs-results-{0}.csv" -f $runStamp)
    if (Test-Path -LiteralPath $csvPath) {
        $rows = @()
        try { $rows = @(Import-Csv -LiteralPath $csvPath -ErrorAction Stop) } catch { $rows = @() }
        $cols = if ($rows.Count -gt 0) { @($rows[0].PSObject.Properties.Name) } else { @() }
        if (($cols -contains 'SharedDrive') -and ($cols -contains 'StillDifferent')) {
            foreach ($r in $rows) {
                $n = "$($r.SharedDrive)".Trim()
                $d = "$($r.StillDifferent)".Trim()
                if ($n -and $d -match '^\d+$') { $verified[$n] = [int]$d }
            }
            $usedCsv = $true
            $source  = Get-Item -LiteralPath $csvPath
        }
        else {
            Say "Ignoring $(Split-Path -Leaf $csvPath): no SharedDrive/StillDifferent columns."
            $verified = @{}
        }
    }
}

Say ("Verification source : {0}" -f $(if ($usedCsv) { 'results CSV (written after the verify pass, so the run finished)' } else { 'sync transcript' }))
Say "File                : $($source.Name)"
$ageHrs = ((Get-Date).ToUniversalTime() - $source.LastWriteTimeUtc).TotalHours
Say ("Written             : {0} UTC  ({1:N1} hours ago)" -f $source.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm'), $ageHrs)

if ($ageHrs -gt $MaxAge) {
    Stop-Now ("That is {0:N1} hours old and MaxAgeHours is {1}. Rerun the sync before freezing." -f $ageHrs, $MaxAge) 'stale'
}

if (-not $usedCsv) {
    $lines = @(Get-Content -LiteralPath $latest.FullName -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { Stop-Now 'The transcript is empty.' 'emptytranscript' }

    # A finished PowerShell transcript ends with its own end banner. With no
    # results CSV for this run, that marker is the only evidence the sync is not
    # still going, so without it nothing here is safe to trust.
    $tail = ($lines[-6..-1] -join "`n")
    if ($tail -notmatch 'Windows PowerShell transcript end') {
        Stop-Now 'That transcript has no end marker and the run wrote no results CSV, so the sync looks like it is still running. Wait for it to finish.' 'running'
    }

    # Parse: "== <Name>  (n files, x GB)  <src>  to  <dst>" then later
    #        "  Still different after copy: <n>   Status: ..."
    $current = $null
    foreach ($ln in $lines) {
        if ($ln -match '^\s*==\s+(.+?)\s{2,}\(') { $current = $Matches[1].Trim(); continue }
        if ($current -and $ln -match 'Still different after copy:\s*(\d+)') {
            $verified[$current] = [int]$Matches[1]
            $current = $null
        }
    }
}

Say "Folders reported in that run : $($verified.Count)"
Say ''

# ---------------------------------------------------------------- plan

$plan = @()
foreach ($row in $map) {
    $name = $row.SharedDrive
    $src  = $row.Source
    $why  = ''
    $ok   = $false

    if (-not $src) { $why = 'map row has no Source' }
    elseif (-not (Test-Path -LiteralPath $src)) { $why = 'source folder not found on this server' }
    elseif (-not $verified.ContainsKey($name)) { $why = 'not verified in the latest sync run' }
    elseif ($verified[$name] -ne 0) { $why = "sync reported $($verified[$name]) file(s) still different" }
    else { $ok = $true; $why = 'verified clean in the latest sync run' }

    $plan += [pscustomobject]@{
        SharedDrive = $name
        Source      = $src
        Eligible    = $ok
        Reason      = $why
        OpenFiles   = 0
        DenyApplied = ''
        Result      = ''
    }
}

# open files, per source
foreach ($p in $plan) {
    if (-not $p.Eligible) { continue }
    try {
        $open = @(Get-SmbOpenFile -ErrorAction Stop | Where-Object { $_.Path -like "$($p.Source)\*" -or $_.Path -eq $p.Source })
        $p.OpenFiles = $open.Count
        if ($open.Count -gt 0 -and -not $Force) {
            $p.Eligible = $false
            $p.Reason   = "$($open.Count) file(s) open, and Force is not set"
        }
    } catch { }
}

$go   = @($plan | Where-Object { $_.Eligible })
$skip = @($plan | Where-Object { -not $_.Eligible })

Say 'PLAN'
$plan | Select-Object SharedDrive, Eligible, OpenFiles, Reason |
    Format-Table -AutoSize | Out-String -Width 240 | Say
foreach ($p in $plan) { Say ("PLAN|{0}|{1}|{2}|{3}" -f $Computer, $p.SharedDrive, $p.Eligible, $p.Reason) }
Say ''
Say ("Would freeze: {0}   Would skip: {1}" -f $go.Count, $skip.Count)
Say ''

if ($Action -eq 'report') {
    Say 'REPORT ONLY. Nothing was changed.'
    Say "INFO|$Computer|report|$($go.Count)|$($skip.Count)"
    Say "DONE|OESU-Freeze|$Version|report|$Computer"
    exit 0
}

# ---------------------------------------------------------------- freeze

if (-not (Test-Path -LiteralPath $AclDir)) { New-Item -ItemType Directory -Path $AclDir -Force | Out-Null }

$domain = $env:USERDOMAIN
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.PartOfDomain -and $cs.Domain) { $domain = ($cs.Domain -split '\.')[0] }
} catch { }
$denyPrincipal = if ($DenyGroup -match '\\') { $DenyGroup } else { "$domain\$DenyGroup" }
Say "Broad deny principal: $denyPrincipal"
Say ''

$note = @"
These files moved to Google Drive on $(Get-Date -Format 'MMMM d, yyyy').

This folder is now read only. You can still open everything here, but new
work belongs in Google Drive. If you cannot find something, or you need
this folder writable again, contact Jeff Jamele, jeff.jamele@oesu.org.

This copy is kept as a safety net and is not deleted.
"@

$indexRows = @()

foreach ($p in $go) {
    Say "== $($p.SharedDrive)   $($p.Source)"

    if ($p.OpenFiles -gt 0 -and $Force) {
        try {
            Get-SmbOpenFile | Where-Object { $_.Path -like "$($p.Source)\*" } | Close-SmbOpenFile -Force -ErrorAction SilentlyContinue
            Say "  closed $($p.OpenFiles) open file handle(s)"
        } catch { Say "  could not close open handles: $($_.Exception.Message)" }
    }

    $aclFile = Join-Path $AclDir ("{0}_{1}.acl" -f (Get-SafeName $p.Source), $Stamp)
    $parent  = Split-Path -Parent $p.Source
    $leaf    = Split-Path -Leaf $p.Source

    $saved = $false
    try {
        Push-Location -LiteralPath $parent
        & icacls.exe $leaf /save $aclFile /T /C 2>&1 | Out-Null
        Pop-Location
        $saved = (Test-Path -LiteralPath $aclFile)
    } catch { try { Pop-Location } catch { } }

    if (-not $saved) {
        $p.Result = 'FAILED: could not save ACL backup, nothing changed'
        Say "  $($p.Result)"
        Say ("SKIP|{0}|{1}|aclbackup" -f $Computer, $p.SharedDrive)
        continue
    }
    Say "  ACL saved to $(Split-Path -Leaf $aclFile)"

    # specific non-inherited writers, minus the ones we must never deny
    $targets = @()
    try {
        $acl = Get-Acl -LiteralPath $p.Source -ErrorAction Stop
        foreach ($a in $acl.Access) {
            if ($a.AccessControlType -ne 'Allow') { continue }
            if ($a.IsInherited) { continue }
            $id = "$($a.IdentityReference)"
            if ($NeverDeny -contains $id) { continue }
            $hasWrite = $false
            foreach ($r in $WriteRights) { if ("$($a.FileSystemRights)" -match $r) { $hasWrite = $true; break } }
            if ($hasWrite) { $targets += $id }
        }
    } catch { Say "  could not read ACL: $($_.Exception.Message)" }
    $targets = @($targets | Sort-Object -Unique)

    # The broad group always goes on. It is what covers folders whose only
    # write permission is inherited, where there is no specific group to deny.
    $applied = @()
    foreach ($t in (@($denyPrincipal) + $targets)) {
        & icacls.exe $p.Source /deny "${t}:(OI)(CI)(W,D,DC)" /C 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $applied += $t } else { Say "  deny failed for $t" }
    }

    if ($applied.Count -eq 0) {
        $p.Result = 'FAILED: no deny could be applied'
        Say "  $($p.Result)"
        Say ("SKIP|{0}|{1}|denyfailed" -f $Computer, $p.SharedDrive)
        continue
    }

    $p.DenyApplied = ($applied -join '; ')
    Say "  denied write to: $($p.DenyApplied)"

    try {
        Set-Content -LiteralPath (Join-Path $p.Source 'MOVED TO GOOGLE DRIVE.txt') -Value $note -Encoding UTF8 -ErrorAction Stop
        Say '  left MOVED TO GOOGLE DRIVE.txt'
    } catch { Say "  could not write the note: $($_.Exception.Message)" }

    $p.Result = 'frozen'
    Say ("FROZE|{0}|{1}|{2}" -f $Computer, $p.SharedDrive, $p.DenyApplied)

    $indexRows += [pscustomobject]@{
        Stamp = $Stamp; SharedDrive = $p.SharedDrive; Source = $p.Source
        Parent = $parent; AclFile = $aclFile; DenyApplied = $denyPrincipal
    }
    Say ''
}

foreach ($p in $skip) { Say ("SKIP|{0}|{1}|{2}" -f $Computer, $p.SharedDrive, $p.Reason) }

# ---------------------------------------------------------------- records

if ($indexRows.Count -gt 0) {
    try {
        if (Test-Path -LiteralPath $Index) { $indexRows | Export-Csv -LiteralPath $Index -NoTypeInformation -Append -Encoding UTF8 }
        else                               { $indexRows | Export-Csv -LiteralPath $Index -NoTypeInformation -Encoding UTF8 }
    } catch { Say "Could not update the index: $($_.Exception.Message)" }
}
try { $plan | Export-Csv -LiteralPath $Report -NoTypeInformation -Encoding UTF8 } catch { }

$frozen = @($plan | Where-Object { $_.Result -eq 'frozen' })
Say ''
Say '======================================================================='
Say (" Frozen  : {0}" -f $frozen.Count)
Say (" Skipped : {0}" -f ($plan.Count - $frozen.Count))
Say (" Report  : $Report")
Say (" Undo    : rerun with Action=unfreeze")
Say '======================================================================='
Say ("INFO|{0}|freeze|{1}|{2}" -f $Computer, $frozen.Count, ($plan.Count - $frozen.Count))
Say "DONE|OESU-Freeze|$Version|ok|$Computer"
exit 0
