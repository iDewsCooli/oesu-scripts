<#
=======================================================================
 OESU-Personal-Move.ps1
 Version 1.0  (2026-09-20)

 Moves ONE person's home folder from OESU2019 into their own My Drive,
 then freezes the server copy. Built from the September 11 procedure
 "Moving Tim Ross From the Server Drives to Google Drive", with the
 parts that were examples in that document replaced by things the
 script works out for itself.

 THE ONE RULE THIS SCRIPT EXISTS TO ENFORCE
 Personal files must be copied WHILE SIGNED IN AS THE PERSON, so that
 person owns them in Google Drive. Files uploaded by an IT account end
 up owned by the wrong person, which is the cleanup OESU has been doing
 since July 2026.

 So the Copy action does not take a "which user" parameter at all. It
 copies the CURRENT user's own folder, to the CURRENT user's own Drive.
 There is no way to point it at someone else. That is deliberate: it
 makes the ownership mistake structurally impossible rather than a
 thing you have to remember.

 WHY THE WORK IS SPLIT IN TWO
 Copy must run as the person, in their signed in session, because
 Google Drive for desktop mounts for one user token only.
 Freeze must run on OESU2019 as an administrator, because it changes
 NTFS permissions.
 One person cannot do both in one session, so this is two runs of the
 same script in two places. The Copy leaves a signed receipt in the
 folder; the Freeze refuses to act without it.

 ACTIONS
   Detect     Default. Reads both sides and reports. Changes nothing.
              Run this first, always. It tells you whether a copy
              already exists, what differs, and what will be skipped.
   Copy       On the person's PC, in their session. Robocopy delta into
              their My Drive, then verify counts. Needs -Run.
   Freeze     On OESU2019, as admin. Denies that person write access to
              their server folder and leaves the note. Reads the receipt
              the Copy wrote and refuses if it is missing, stale, or
              says the counts did not match. Needs -Run.
   Unfreeze   On OESU2019, as admin. Puts the permission back.

 NOTHING IS EVER DELETED
 The copy is /E, never /MIR and never /PURGE. A file deleted on the
 server stays in Drive. A file deleted in Drive comes back on the next
 pass. Neither side is authoritative, which is correct for a move that
 has to be reversible.

 EXAMPLES
   .\OESU-Personal-Move.ps1
   .\OESU-Personal-Move.ps1 -Action Copy
   .\OESU-Personal-Move.ps1 -Action Copy -Run
   .\OESU-Personal-Move.ps1 -Action Freeze -User timothy.ross
   .\OESU-Personal-Move.ps1 -Action Freeze -User timothy.ross -Run

 OUTPUT
   Machine readable lines start with PLAN|, COPY|, VERIFY|, FROZE| or INFO|.
   Copy log   : <Desktop>\personal-move-<stamp>.log
   Receipt    : <server folder>\.oesu-move-receipt.json
=======================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Detect','Copy','Freeze','Unfreeze')]
    [string]$Action = 'Detect',

    # Server hosting the home folders.
    [string]$Server = 'OESU2019',

    # Override the source folder. Normally worked out from the signed in account.
    [string]$Source,

    # Override the Drive destination. Normally "G:\My Drive\<Letter> Drive".
    [string]$Destination,

    # The drive letter the person already knows, used to name the Drive folder
    # so the path they see does not change. Worked out from their mappings if
    # not supplied.
    [string]$Letter,

    # Freeze and Unfreeze only: whose folder. SamAccountName, e.g. timothy.ross
    [string]$User,

    # Databases and mail archives stay on the server by standing decision.
    # Set this only after deciding file by file with the person.
    [switch]$IncludeDatabases,

    # Do it. Without this, Copy and Freeze print the plan and stop.
    [switch]$Run,

    # Copy: proceed even when the destination already holds files that are
    # not on the server. Freeze: proceed despite a receipt older than MaxAgeHours.
    [switch]$Force,

    [double]$MaxAgeHours = 24
)

$ErrorActionPreference = 'Continue'
$Version = '1.0'
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmm'

# Files that never belong in the Drive copy. Thumbs.db and desktop.ini are
# Windows droppings, ~$ files are Office lock files, .lnk shortcuts point at
# server paths that are about to stop working.
$SkipAlways = @('Thumbs.db','desktop.ini','~$*','*.tmp','*.lnk','.oesu-move-receipt.json')

# Mail archives never go to Drive: Outlook holds them open, so they copy
# corrupt and re-upload in full every pass.
$SkipMail = @('*.pst','*.ost')

# Databases break when synced: Access and QuickBooks write in place and
# Drive cannot merge that. Standing decision is that these stay on the
# server and are handled by hand with the person.
$SkipDatabases = @('*.accdb','*.mdb','*.qbw','*.qbb','*.laccdb','*.ldb')

$ReceiptName = '.oesu-move-receipt.json'

function Say { param([Parameter(ValueFromPipeline=$true,Position=0)][string]$m) process { Write-Host $m } }

function Stop-Now([string]$reason, [string]$code) {
    Say ''
    Say "REFUSED: $reason"
    Say "INFO|$env:COMPUTERNAME|refused|$code"
    Say "DONE|OESU-Personal-Move|$Version|refused|$env:COMPUTERNAME"
    exit 1
}

function Get-SkipPatterns {
    $p = @() + $SkipAlways + $SkipMail
    if (-not $IncludeDatabases) { $p += $SkipDatabases }
    return $p
}

# Does a file name match any of the wildcard patterns?
function Test-Skipped([string]$name, [string[]]$patterns) {
    foreach ($pat in $patterns) { if ($name -like $pat) { return $true } }
    return $false
}

# Count and size a tree, honouring the same exclusions the copy uses, so the
# two sides are compared on equal terms. Returns a hashtable, never throws.
function Measure-Tree([string]$path, [string[]]$patterns) {
    $r = @{ Files = 0; Bytes = 0; LongPaths = 0; Skipped = 0; Unreadable = 0; Exists = $false }
    if (-not (Test-Path -LiteralPath $path)) { return $r }
    $r.Exists = $true
    try {
        $items = Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable errs
        if ($errs) { $r.Unreadable = @($errs).Count }
        foreach ($f in $items) {
            if (Test-Skipped $f.Name $patterns) { $r.Skipped++; continue }
            $r.Files++
            $r.Bytes += $f.Length
            if ($f.FullName.Length -gt 240) { $r.LongPaths++ }
        }
    } catch { }
    return $r
}

function Format-GB([double]$bytes) { "{0:N2} GB" -f ($bytes / 1GB) }

Say '======================================================================='
Say " OESU-Personal-Move v$Version   action: $Action"
Say " computer: $env:COMPUTERNAME   user: $env:USERDOMAIN\$env:USERNAME"
Say " time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say '======================================================================='
Say "BANNER|OESU-Personal-Move|$Version|$Action|$env:COMPUTERNAME"
Say ''

# ---------------------------------------------------------------- who am I

$IsSystem = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $IsSystem = $id.IsSystem
    $IsAdmin  = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
                 [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $IsAdmin = $false }

# =======================================================================
#  FREEZE and UNFREEZE: on the server, as admin
# =======================================================================

if ($Action -in @('Freeze','Unfreeze')) {

    if (-not $User) { Stop-Now "Freeze needs -User, the SamAccountName whose folder to freeze, for example -User timothy.ross" 'nouser' }
    if (-not $IsAdmin) { Stop-Now "Freeze changes NTFS permissions and must run in an Administrator PowerShell on $Server." 'notadmin' }

    $root = if ($Source) { $Source } else { 'C:\Data\users' }
    if ($Source) { $folder = $Source } else {
        $match = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -eq $User -or $_.Name -replace '[._-]','' -eq ($User -replace '[._-]','') })
        if ($match.Count -eq 0) { Stop-Now "No folder under $root matches '$User'. Pass -Source with the exact path." 'nofolder' }
        if ($match.Count -gt 1) { Stop-Now "More than one folder under $root matches '$User': $($match.Name -join ', '). Pass -Source." 'ambiguous' }
        $folder = $match[0].FullName
    }

    Say "Folder  : $folder"

    $domain = $env:USERDOMAIN
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain -and $cs.Domain) { $domain = ($cs.Domain -split '\.')[0] }
    } catch { }
    $who = "$domain\$User"
    Say "Account : $who"

    if ($Action -eq 'Unfreeze') {
        if (-not $Run) { Say ''; Say "PLAN|$env:COMPUTERNAME|unfreeze|$folder|$who"; Say 'Rerun with -Run to remove the deny.'; exit 0 }
        & icacls.exe $folder /remove:d $who /T /C 2>&1 | Out-Null
        Say "Removed the deny for $who on $folder"
        Say "INFO|$env:COMPUTERNAME|unfrozen|$folder"
        Say "DONE|OESU-Personal-Move|$Version|unfreeze|$env:COMPUTERNAME"
        exit 0
    }

    # ---- Freeze: the receipt is the evidence, same rule as OESU-Freeze ----

    $receiptPath = Join-Path $folder $ReceiptName
    if (-not (Test-Path -LiteralPath $receiptPath)) {
        Stop-Now "No $ReceiptName in $folder. Nothing has proved the copy finished, so there is nothing safe to freeze. Run -Action Copy -Run as $User first." 'noreceipt'
    }

    $receipt = $null
    try { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } catch { }
    if (-not $receipt) { Stop-Now "$ReceiptName is not readable JSON." 'badreceipt' }

    Say ''
    Say "Receipt written : $($receipt.FinishedUtc) UTC"
    Say "  by            : $($receipt.User) on $($receipt.Computer)"
    Say "  destination   : $($receipt.Destination)"
    Say "  server files  : $($receipt.ServerFiles)   drive files: $($receipt.DriveFiles)"
    Say "  robocopy exit : $($receipt.RobocopyExit)   failed: $($receipt.Failed)"

    # Age from the epoch milliseconds, not from the text. ConvertFrom-Json turns
    # an ISO-8601 Z string into a DateTime whose Kind is not reliably Utc, and a
    # later ToUniversalTime() then shifts it by the local offset. That silently
    # made a 70 hour old receipt read as 66 on a UTC-4 machine, which is exactly
    # the kind of error a staleness check must not have.
    $ageHrs = 9999
    if ($receipt.FinishedUnixMs) {
        try {
            $nowMs  = [long]([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds())
            $ageHrs = ($nowMs - [long]$receipt.FinishedUnixMs) / 3600000.0
        } catch { }
    }
    elseif ($receipt.FinishedUtc) {
        # Receipts from before FinishedUnixMs existed. Parse keeping the offset.
        try {
            $dto = [datetimeoffset]::Parse(
                       [string]$receipt.FinishedUtc, $null,
                       [Globalization.DateTimeStyles]::AssumeUniversal -bor
                       [Globalization.DateTimeStyles]::AdjustToUniversal)
            $ageHrs = ([datetimeoffset]::UtcNow - $dto).TotalHours
        } catch { }
    }
    Say ("  age           : {0:N1} hours" -f $ageHrs)

    if ($receipt.User -notlike "*$User*") {
        Stop-Now "That receipt was written by '$($receipt.User)', not '$User'. Refusing to freeze one person's folder on another person's evidence." 'wronguser'
    }
    if (-not $receipt.Matched) {
        Stop-Now "The copy that wrote this receipt did NOT verify clean (server $($receipt.ServerFiles) files, Drive $($receipt.DriveFiles)). Rerun the copy until the counts match." 'notverified'
    }
    if ($ageHrs -gt $MaxAgeHours -and -not $Force) {
        Stop-Now ("That receipt is {0:N1} hours old and MaxAgeHours is {1}. Anything saved to the server since is not in Drive. Rerun the copy, or pass -Force if you are certain." -f $ageHrs, $MaxAgeHours) 'stale'
    }

    # Anything open right now would be lost work, so look before acting.
    $open = @()
    try { $open = @(Get-SmbOpenFile -ErrorAction Stop | Where-Object { $_.Path -like "$folder\*" }) } catch { }
    if ($open.Count -gt 0) {
        Say ''
        Say "$($open.Count) file(s) still open in that folder:"
        $open | Select-Object -First 10 ClientUserName, Path | Format-Table -AutoSize | Out-String -Width 200 | Say
        if (-not $Force) { Stop-Now "Files are still open. Ask them to save and close, then rerun. -Force closes the handles instead." 'openfiles' }
    }

    Say ''
    Say "PLAN|$env:COMPUTERNAME|freeze|$folder|$who"
    if (-not $Run) { Say 'PLAN ONLY. Rerun with -Run to apply.'; Say "DONE|OESU-Personal-Move|$Version|plan|$env:COMPUTERNAME"; exit 0 }

    if ($open.Count -gt 0 -and $Force) {
        try { $open | Close-SmbOpenFile -Force -ErrorAction SilentlyContinue; Say "  closed $($open.Count) handle(s)" } catch { }
    }

    # Back the permissions up before touching them.
    $aclDir = 'C:\Migration\freeze-acl-backup'
    if (-not (Test-Path -LiteralPath $aclDir)) { New-Item -ItemType Directory -Path $aclDir -Force | Out-Null }
    $aclFile = Join-Path $aclDir ("{0}_{1}.acl" -f (($folder -replace '[:\\/ ]+','_').Trim('_')), $Stamp)
    $parent  = Split-Path -Parent $folder
    $leaf    = Split-Path -Leaf   $folder
    $saved   = $false
    try {
        Push-Location -LiteralPath $parent
        & icacls.exe $leaf /save $aclFile /T /C 2>&1 | Out-Null
        Pop-Location
        $saved = Test-Path -LiteralPath $aclFile
    } catch { try { Pop-Location } catch { } }
    if (-not $saved) { Stop-Now "Could not save an ACL backup to $aclFile. Nothing was changed." 'aclbackup' }
    Say "  ACL saved to $(Split-Path -Leaf $aclFile)"

    # Deny write and delete, leave read alone. Administrators keep FullControl,
    # so this is reversible without taking ownership.
    & icacls.exe $folder /deny "${who}:(OI)(CI)(W,D,DC)" /C 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Now "icacls could not apply the deny for $who." 'denyfailed' }
    Say "  denied write to $who"

    $note = @"
These files moved to Google Drive on $(Get-Date -Format 'MMMM d, yyyy').

They are in your own My Drive, under $($receipt.DestinationLeaf), and they
still open from the same drive letter on your PC.

This folder is now read only. You can still open everything here, but new
work belongs in Google Drive. If you cannot find something, or you need
this folder writable again, contact Jeff Jamele, jeff.jamele@oesu.org.

This copy is kept as a safety net for 30 days and is not deleted.
"@
    try {
        Set-Content -LiteralPath (Join-Path $folder 'MOVED TO GOOGLE DRIVE.txt') -Value $note -Encoding UTF8 -ErrorAction Stop
        Say '  left MOVED TO GOOGLE DRIVE.txt'
    } catch { Say "  could not write the note: $($_.Exception.Message)" }

    Say ''
    Say "FROZE|$env:COMPUTERNAME|$folder|$who"
    Say "Undo: .\OESU-Personal-Move.ps1 -Action Unfreeze -User $User -Run"
    Say "DONE|OESU-Personal-Move|$Version|freeze|$env:COMPUTERNAME"
    exit 0
}

# =======================================================================
#  DETECT and COPY: on the person's PC, in their own session
# =======================================================================

if ($IsSystem) {
    # A SYSTEM run cannot do the copy, but it does not have to be wasted. Push this
    # through Datto and it leaves itself on the machine, ready for the person to run
    # in their own session. That turns a dead end into the one thing a remote push
    # is actually good for here: delivery.
    $stageDir = if ($env:ProgramData) { Join-Path $env:ProgramData 'OESU' }
                else { Join-Path ([IO.Path]::GetTempPath()) 'OESU' }
    $staged   = Join-Path $stageDir 'OESU-Personal-Move.ps1'
    try {
        if (-not (Test-Path -LiteralPath $stageDir)) {
            New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        }
        if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $staged -Force -ErrorAction Stop
            Say ''
            Say "STAGED|$env:COMPUTERNAME|$staged"
            Say "Left a copy at $staged"
            Say ''
            Say 'To run it, the person signs in to this PC as themselves, opens PowerShell'
            Say '(a normal window, not Administrator), and runs:'
            Say ''
            Say "    cd '$stageDir'"
            Say '    .\OESU-Personal-Move.ps1'
            Say ''
            Say 'That first run only reports. It copies nothing until -Action Copy -Run.'
        }
    } catch {
        Say "Could not stage a copy to $staged : $($_.Exception.Message)"
    }

    Stop-Now 'Running as SYSTEM, so the copy cannot happen here. Google Drive for desktop mounts for one user token only: SYSTEM sees an empty drive, and anything it did upload would be owned by the wrong account. The script has been left on this machine for the person to run in their own signed in session.' 'system'
}

$me = $env:USERNAME
Say "Signed in as    : $env:USERDOMAIN\$me"

# ---- source: the current user's own folder, found on the server ----

if ($Source) {
    $src = $Source
    Say "Source override : $src"
} else {
    $share = "\\$Server\users"
    if (-not (Test-Path -LiteralPath $share)) {
        Stop-Now "Cannot reach $share. Check the server is up and you are on the network or VPN." 'noshare'
    }
    $cands = @(Get-ChildItem -LiteralPath $share -Directory -ErrorAction SilentlyContinue |
               Where-Object { ($_.Name -replace '[._-]','') -eq ($me -replace '[._-]','') })
    if ($cands.Count -eq 0) {
        Stop-Now "No folder under $share matches the signed in account '$me'. If the folder is named differently, pass -Source ""$share\<folder>""." 'nosource'
    }
    if ($cands.Count -gt 1) {
        Stop-Now "More than one folder under $share matches '$me': $($cands.Name -join ', '). Pass -Source to pick one." 'ambiguous'
    }
    $src = $cands[0].FullName
}

if (-not (Test-Path -LiteralPath $src)) { Stop-Now "Source folder not found: $src" 'nosource' }
Say "Server folder   : $src"

# ---- Google Drive: must be mounted and signed in ----

$driveRoot = $null
foreach ($d in @('G:','H:','I:','J:','K:')) {
    $p = Join-Path $d 'My Drive'
    if (Test-Path -LiteralPath $p) { $driveRoot = $p; break }
}
if (-not $driveRoot) {
    $gd = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
          Where-Object { Test-Path -LiteralPath (Join-Path "$($_.Name):" 'My Drive') } | Select-Object -First 1
    if ($gd) { $driveRoot = Join-Path "$($gd.Name):" 'My Drive' }
}
if (-not $driveRoot) {
    Stop-Now 'Cannot find "My Drive" on any drive letter. Open Google Drive from the Start menu, sign in with the oesu.org account, wait for the letter to appear, then rerun.' 'nodrive'
}
Say "My Drive at     : $driveRoot"

# ---- the letter the person knows, so the Drive folder keeps their name ----

if (-not $Letter) {
    $hit = $null
    try {
        $hit = Get-CimInstance Win32_NetworkConnection -ErrorAction SilentlyContinue |
               Where-Object { $_.RemoteName -and ($_.RemoteName -replace '/','\') -like "*\$(Split-Path -Leaf $src)" } |
               Select-Object -First 1
    } catch { }
    if ($hit -and $hit.LocalName) { $Letter = $hit.LocalName.TrimEnd(':') }
}
$destLeaf = if ($Letter) { "$($Letter.TrimEnd(':')) Drive" } else { Split-Path -Leaf $src }
if ($Destination) { $dst = $Destination; $destLeaf = Split-Path -Leaf $Destination }
else              { $dst = Join-Path $driveRoot $destLeaf }

Say "Drive folder    : $dst"
if (-not $Letter -and -not $Destination) {
    Say "  (no mapped letter found for that folder, so the Drive folder is named after the server folder."
    Say "   If they know it as a letter, rerun with -Letter U to name it ""U Drive"" instead.)"
}
Say ''

# ---- measure both sides ----

$patterns = Get-SkipPatterns
Say "Excluding       : $($patterns -join ' ')"
if (-not $IncludeDatabases) {
    Say '  Databases and mail archives stay on the server by standing decision.'
    Say '  They are listed below if present. Decide those by hand, then use -IncludeDatabases if you want them copied.'
}
Say ''

Say 'Measuring the server folder. Large folders take a minute.'
$S = Measure-Tree $src $patterns
Say 'Measuring the Drive folder.'
$D = Measure-Tree $dst $patterns

Say ''
Say ("Server : {0,7} files  {1,10}  long paths {2}  excluded {3}" -f $S.Files, (Format-GB $S.Bytes), $S.LongPaths, $S.Skipped)
Say ("Drive  : {0,7} files  {1,10}  {2}" -f $D.Files, (Format-GB $D.Bytes), $(if ($D.Exists) { '' } else { '(does not exist yet)' }))
Say ''

# What is on the server that is being deliberately left behind?
$held = @()
if (-not $IncludeDatabases) {
    try {
        $held = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { Test-Skipped $_.Name $SkipDatabases } )
    } catch { }
}
$mail = @()
try {
    $mail = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
              Where-Object { Test-Skipped $_.Name $SkipMail } )
} catch { }

if ($held.Count -gt 0) {
    Say "STAYING ON THE SERVER, databases ($($held.Count)):"
    $held | Select-Object -First 20 | ForEach-Object { Say ("  {0}  {1}" -f (Format-GB $_.Length), $_.FullName) }
    if ($held.Count -gt 20) { Say "  ... and $($held.Count - 20) more" }
    Say ''
}
if ($mail.Count -gt 0) {
    Say "STAYING ON THE SERVER, mail archives ($($mail.Count)):"
    $mail | Select-Object -First 20 | ForEach-Object { Say ("  {0}  {1}" -f (Format-GB $_.Length), $_.FullName) }
    if ($mail.Count -gt 20) { Say "  ... and $($mail.Count - 20) more" }
    Say ''
}

if ($S.LongPaths -gt 0) {
    Say "$($S.LongPaths) file(s) have paths over 240 characters. Those will show as failures in the copy log and need copying by hand."
    Say ''
}
if ($S.Unreadable -gt 0) {
    Say "$($S.Unreadable) item(s) could not be read on the server. Usually permissions. They will not copy."
    Say ''
}

# Free space on C:, because Drive stages uploads through its local cache.
try {
    $free = (Get-PSDrive C).Free
    Say ("Free on C:      : {0}   needed to stage: about {1}" -f (Format-GB $free), (Format-GB ($S.Bytes - $D.Bytes)))
    if (($S.Bytes - $D.Bytes) -gt $free) {
        Say '  NOT ENOUGH ROOM. Drive stages the upload on C: first. Free up space before copying.'
    }
    Say ''
} catch { }

# Files in Drive that are not on the server. On a rerun that is normal (work
# done in Drive since the last pass). On a first pass it means the destination
# was already in use and is worth a look before copying into it.
$extra = 0
if ($D.Exists -and $D.Files -gt 0) {
    try {
        $srcRel = @{}
        Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Skipped $_.Name $patterns) } |
            ForEach-Object { $srcRel[$_.FullName.Substring($src.Length).TrimStart('\').ToLower()] = $true }
        Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Skipped $_.Name $patterns) } |
            ForEach-Object {
                $rel = $_.FullName.Substring($dst.Length).TrimStart('\').ToLower()
                if (-not $srcRel.ContainsKey($rel)) { $extra++ }
            }
    } catch { }
    if ($extra -gt 0) {
        Say "$extra file(s) are in Drive but not on the server."
        Say '  On a repeat pass that is normal: it is work done in Drive since the last copy, and nothing here deletes it.'
        Say '  On a first pass it means this Drive folder was already in use. Look before you copy.'
        Say ''
    }
}

$toCopy = $S.Files - $D.Files
Say ("PLAN|{0}|{1}|{2}|{3}|server={4}|drive={5}" -f $env:COMPUTERNAME, $me, $src, $dst, $S.Files, $D.Files)
if ($toCopy -gt 0) { Say "About $toCopy file(s) still to reach Drive. Robocopy decides the exact set by date and size." }
elseif ($D.Files -eq $S.Files -and $S.Files -gt 0) { Say 'Counts already match. A copy now would be a no-op, which is a fine way to confirm.' }
Say ''

if ($Action -eq 'Detect') {
    Say 'DETECT ONLY. Nothing was changed.'
    Say "Next: .\OESU-Personal-Move.ps1 -Action Copy        (plan)"
    Say "      .\OESU-Personal-Move.ps1 -Action Copy -Run   (do it)"
    Say "INFO|$env:COMPUTERNAME|detect|$($S.Files)|$($D.Files)"
    Say "DONE|OESU-Personal-Move|$Version|detect|$env:COMPUTERNAME"
    exit 0
}

# ---------------------------------------------------------------- copy

# If most of what is already in the destination did not come from this server
# folder, the destination is probably not this folder's home. Copying in would
# mix two people's work in one place, which is hard to unpick later. A normal
# repeat pass fails this test easily: a few files created in Drive out of
# hundreds is a small fraction, not a majority.
if ($extra -gt 0 -and $D.Files -gt 0 -and $extra -ge ($D.Files / 2) -and -not $Force) {
    Stop-Now "The Drive folder holds $($D.Files) file(s) and $extra of them are not on the server, so most of what is there did not come from this folder. Check that $dst is the right destination, then rerun with -Force if it is." 'unexpecteddest'
}

if (-not $Run) {
    Say 'PLAN ONLY. Nothing was copied. Rerun with -Run.'
    Say "DONE|OESU-Personal-Move|$Version|plan|$env:COMPUTERNAME"
    exit 0
}

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = $env:USERPROFILE }
$log = Join-Path $desktop "personal-move-$Stamp.log"

$rcArgs = @($src, $dst, '/E', '/COPY:DT', '/R:2', '/W:5', '/NP', '/NFL', '/NDL', '/XJ', '/XF') +
          $patterns + @('/LOG:' + $log)

Say "Copying. Log: $log"
Say '  /E adds and updates only. Nothing is deleted on either side.'
Say ''

& robocopy.exe @rcArgs | Out-Null
$rc = $LASTEXITCODE
if ($null -eq $rc) { $rc = 0 }

# Robocopy: 0 to 7 is success, 8 and above means at least one file failed.
$failed = 0
try {
    $tail = Get-Content -LiteralPath $log -Tail 15 -ErrorAction SilentlyContinue
    foreach ($ln in $tail) {
        if ($ln -match '^\s*Files\s*:\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+\d+') { $failed = [int]$Matches[1] }
    }
} catch { }

Say "COPY|$env:COMPUTERNAME|$me|exit=$rc|failed=$failed"
if ($rc -ge 8) { Say "  Robocopy exit $rc means at least one file failed. The log lists them." }

# ---- verify ----

Say ''
Say 'Verifying. Recounting both sides.'
$S2 = Measure-Tree $src $patterns
$D2 = Measure-Tree $dst $patterns
$matched = ($S2.Files -eq $D2.Files -and $failed -eq 0)

Say ("VERIFY|{0}|server={1}|drive={2}|match={3}" -f $env:COMPUTERNAME, $S2.Files, $D2.Files, $matched)
Say ("Server : {0} files   Drive: {1} files" -f $S2.Files, $D2.Files)

if (-not $matched) {
    Say ''
    Say 'The two sides do not match yet. Common reasons, in order of likelihood:'
    Say '  a file was open during the copy, so rerun once it is closed'
    Say '  a long path over 240 characters, which needs copying by hand'
    Say '  Drive has not finished writing, so wait for the tray icon and rerun'
}

# ---- receipt ----

$receipt = [pscustomobject]@{
    Version        = $Version
    User           = "$env:USERDOMAIN\$me"
    Computer       = $env:COMPUTERNAME
    Source         = $src
    Destination    = $dst
    DestinationLeaf= $destLeaf
    ServerFiles    = $S2.Files
    DriveFiles     = $D2.Files
    Matched        = $matched
    RobocopyExit   = $rc
    Failed         = $failed
    Excluded       = ($patterns -join ' ')
    Log            = $log
    FinishedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    # For the age arithmetic. A number has no timezone to get wrong.
    FinishedUnixMs = [long]([datetimeoffset]::UtcNow.ToUnixTimeMilliseconds())
}
$receiptPath = Join-Path $src $ReceiptName
try {
    $receipt | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $receiptPath -Encoding UTF8 -ErrorAction Stop
    Say ''
    Say "Receipt written to $receiptPath"
    Say '  The freeze step on the server reads this and refuses without it.'
} catch {
    Say ''
    Say "Could not write the receipt to $receiptPath : $($_.Exception.Message)"
    Say '  The freeze will refuse until this succeeds. Check write access to the folder.'
}

Say ''
Say '======================================================================='
Say ' Still to do, by hand:'
Say '   1. Wait for the Google Drive tray icon to say everything is up to date.'
Say '      Until then some files exist only on this PC.'
Say '   2. Spot check two or three files at drive.google.com.'
Say '   3. Then on OESU2019, as admin:'
Say "        .\OESU-Personal-Move.ps1 -Action Freeze -User $me -Run"
Say '   4. Then clear the drive letter and repoint it (see the procedure doc).'
Say '======================================================================='
Say "INFO|$env:COMPUTERNAME|copy|$($S2.Files)|$($D2.Files)|$matched"
Say "DONE|OESU-Personal-Move|$Version|$(if ($matched) { 'ok' } else { 'unverified' })|$env:COMPUTERNAME"
exit $(if ($matched) { 0 } else { 2 })
