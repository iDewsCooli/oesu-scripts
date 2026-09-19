<#
=======================================================================
 OESU-DriveFS.ps1
 Version 4.0  (2026-09-18)

 One Datto RMM component for the whole server-to-Google-Drive move.
 PowerShell, runs as SYSTEM. Safe to rerun in every mode.

 WHY THIS IS ONE COMPONENT AND NOT SEVERAL
 On 18 September 2026 a component named "OESU-DriveFS-Discover" turned
 out to contain the deploy script. The name in Datto is a label, not a
 guarantee. With a single component there is no wrong one to pick, and
 every run prints a banner saying exactly what it is and what it did,
 so nobody has to trust a label again.

 MODES  (component variable: Mode)
   Discover  READ ONLY. The default. Reports the drive letters each
             profile has saved, the server shares they have reached
             before, and whether Drive for desktop is installed and
             signed in. Changes nothing at all.
   Install   Wave 1. Installs Drive for desktop, sets it to stream as
             G:, starts at sign in, restricts sign in to @oesu.org,
             and asks the logged in user to sign in. Does NOT touch
             drive letters.
   Letters   Wave 2. Points the drive letters named in the Letters
             variable at Google Drive folders, at each sign in. Run
             this only after that group's folders are frozen and the
             copy has been verified.
   Undo      Removes the letter remapping from this PC. Drive for
             desktop stays installed.

 Mode is deliberately fail safe. Blank, missing, or unrecognised means
 Discover, so a mistyped variable gives you an inventory and never a
 deployment.

 OTHER VARIABLES
   Letters         Letters mode only. Letter=folder pairs separated by
                   semicolons, for example:
                     N=G:\Shared drives\Shared Accounting
                     N=G:\Shared drives\Shared Accounting;S=G:\Shared drives\Shared Files All Staff
                   Only the letters listed are touched.
   WhatIf          true = report what would happen and change nothing.
                   Works in Install, Letters and Undo. Discover ignores
                   it because Discover never changes anything anyway.
   RestrictDomain  Install mode. Default true. Only @oesu.org accounts
                   may sign in to Drive on this PC.
   NotifyUser      Install mode. Default true. Pops a message asking
                   the signed in user to finish the Google sign in.

 OUTPUT
   Line 1 of every run is a banner: script, version, mode, computer.
   Machine readable lines start with BANNER|, STATUS|, MAPPING| or
   ACTION| so results from many PCs can be pasted together and sorted.
   Logs: C:\ProgramData\OESU\DriveFS.log
         %LOCALAPPDATA%\OESU-drive-letters.log   (the per user task)
=======================================================================
#>

$ErrorActionPreference = "Continue"

$ScriptName = "OESU-DriveFS"
$Version    = "4.0"
$Dir        = "C:\ProgramData\OESU"
$Log        = Join-Path $Dir "DriveFS.log"
$Cfg        = Join-Path $Dir "drive-letters.csv"
$MapPath    = Join-Path $Dir "Map-DriveLetters.ps1"
$OutCsv     = Join-Path $Dir "drive-discovery.csv"
$TaskName   = "OESU Map Google Drive Letters"
$Computer   = $env:COMPUTERNAME

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

function L([string]$m) {
    $line = "$(Get-Date -Format s) $m"
    try { $line | Out-File -FilePath $Log -Append -Encoding utf8 } catch { }
    Write-Host $m
}

# ---------------------------------------------------------------- mode

$RawMode = if ($env:Mode) { $env:Mode.Trim() } else { "" }
$Valid   = @("Discover", "Install", "Letters", "Undo")
$Mode    = ($Valid | Where-Object { $_ -ieq $RawMode } | Select-Object -First 1)

$ModeNote = ""
if (-not $Mode) {
    $Mode = "Discover"
    if ($RawMode) { $ModeNote = "Mode '$RawMode' not recognised, fell back to Discover (read only)." }
    else          { $ModeNote = "Mode not set, using Discover (read only)." }
}

$WhatIf = ($env:WhatIf -eq "true")
$ReadOnlyRun = ($Mode -eq "Discover") -or $WhatIf

# ------------------------------------------------------------- banner

Write-Host "======================================================================="
Write-Host " $ScriptName v$Version   mode: $Mode$(if ($WhatIf) { ' (WHATIF, nothing will change)' })"
Write-Host " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($Mode -eq "Discover") { Write-Host " This mode is READ ONLY. No setting, file or drive letter is changed." }
Write-Host "======================================================================="
Write-Host "BANNER|$ScriptName|$Version|$Mode|$(if ($WhatIf) { 'whatif' } else { 'live' })|$Computer"
if ($ModeNote) { L "NOTE: $ModeNote" }
Write-Host ""

function Would([string]$m) {
    if ($WhatIf) { L "WOULD: $m"; Write-Host "ACTION|$Computer|would|$m" }
    else         { L $m;          Write-Host "ACTION|$Computer|did|$m" }
    return (-not $WhatIf)
}

# ------------------------------------------------------- shared helpers

function Get-UserProfiles {
    $profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $loaded = @(Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.PSChildName } |
        Where-Object { $_ -match '^S-1-5-21-' -and $_ -notmatch '_Classes$' })

    foreach ($p in Get-ChildItem $profileList -ErrorAction SilentlyContinue) {
        $sid = $p.PSChildName
        if ($sid -notmatch '^S-1-5-21-') { continue }
        $path = (Get-ItemProperty $p.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $path) { continue }
        $account = ""
        try { $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
        [pscustomobject]@{
            Sid           = $sid
            Account       = $account
            ProfilePath   = $path
            Folder        = Split-Path $path -Leaf
            AlreadyLoaded = ($loaded -contains $sid)
        }
    }
}

function Get-DriveSignInState($profiles) {
    $installed = (Test-Path "C:\Program Files\Google\Drive File Stream\launch.bat")
    $signedIn = @()
    foreach ($prof in $profiles) {
        $dfs = Join-Path $prof.ProfilePath "AppData\Local\Google\DriveFS"
        if (Test-Path $dfs) {
            $n = @(Get-ChildItem $dfs -Directory -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '^\d{6,}$' }).Count
            if ($n -gt 0) { $signedIn += $prof.Folder }
        }
    }
    return [pscustomobject]@{ Installed = $installed; SignedIn = $signedIn }
}

# ============================================================ DISCOVER

function Invoke-Discover {
    $profiles = @(Get-UserProfiles)
    L "Profiles found: $($profiles.Count)"
    $rows = @()

    function Read-Mappings([string]$HiveRoot, $Prof) {
        $found = @()

        $net = "Registry::$HiveRoot\Network"
        if (Test-Path $net) {
            foreach ($letterKey in Get-ChildItem $net -ErrorAction SilentlyContinue) {
                $v = Get-ItemProperty $letterKey.PSPath -ErrorAction SilentlyContinue
                if ($v.RemotePath) {
                    $found += [pscustomobject]@{
                        Computer = $Computer; Account = $Prof.Account; Folder = $Prof.Folder
                        Letter = "$($letterKey.PSChildName.ToUpper()):"; RemotePath = $v.RemotePath
                        Source = "saved drive letter"
                    }
                }
            }
        }

        $mp = "Registry::$HiveRoot\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
        if (Test-Path $mp) {
            foreach ($k in Get-ChildItem $mp -ErrorAction SilentlyContinue) {
                $n = $k.PSChildName
                if ($n -notlike '##*') { continue }
                $unc = "\\" + ($n.TrimStart('#') -replace '#', '\')
                if ($found | Where-Object { $_.RemotePath -ieq $unc }) { continue }
                $found += [pscustomobject]@{
                    Computer = $Computer; Account = $Prof.Account; Folder = $Prof.Folder
                    Letter = ""; RemotePath = $unc; Source = "connected before, no letter saved"
                }
            }
        }
        return $found
    }

    $n = 0
    foreach ($prof in $profiles) {
        $n++
        if ($prof.AlreadyLoaded) {
            $rows += @(Read-Mappings "HKEY_USERS\$($prof.Sid)" $prof)
            continue
        }

        $dat = Join-Path $prof.ProfilePath "NTUSER.DAT"
        if (-not (Test-Path -LiteralPath $dat)) { continue }

        # Numbered so a local and a domain account sharing a RID cannot collide.
        $tempKey = "OESUDISC_$n"
        $mounted = $false
        try {
            $null = & reg.exe load "HKU\$tempKey" "$dat" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $mounted = $true
                $rows += @(Read-Mappings "HKEY_USERS\$tempKey" $prof)
            } else {
                L "  Could not read the profile for $($prof.Account) (in use or locked). Skipped."
            }
        } catch {
            L "  Could not read the profile for $($prof.Account): $($_.Exception.Message)"
        } finally {
            if ($mounted) {
                [gc]::Collect(); Start-Sleep -Milliseconds 500
                $null = & reg.exe unload "HKU\$tempKey" 2>&1
                if ($LASTEXITCODE -ne 0) { Start-Sleep -Seconds 2; $null = & reg.exe unload "HKU\$tempKey" 2>&1 }
            }
        }
    }

    try { @($rows) | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8 } catch { }

    $drive = Get-DriveSignInState $profiles

    Write-Host ""
    Write-Host "==== $Computer ===="
    if (@($rows).Count -eq 0) {
        Write-Host "No saved drive letters or server connections found in any profile."
    } else {
        @($rows) | Sort-Object Account, Letter |
            Format-Table Account, Letter, RemotePath, Source -AutoSize |
            Out-String -Width 240 | Write-Host
    }
    Write-Host "Google Drive for desktop installed : $($drive.Installed)"
    Write-Host "Profiles signed in to Drive        : $(if ($drive.SignedIn.Count) { $drive.SignedIn -join ', ' } else { 'none' })"
    Write-Host "Inventory saved to                 : $OutCsv"
    Write-Host ""

    Write-Host "STATUS|$Computer|DriveInstalled=$($drive.Installed)|SignedIn=$(if ($drive.SignedIn.Count) { $drive.SignedIn -join '+' } else { 'none' })|Profiles=$($profiles.Count)|Mappings=$(@($rows).Count)"
    foreach ($r in @($rows)) {
        Write-Host "MAPPING|$($r.Computer)|$($r.Account)|$($r.Folder)|$($r.Letter)|$($r.RemotePath)|$($r.Source)"
    }
}

# ============================================================= INSTALL

function Invoke-Install {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $uninstall = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "Google Drive*" }
    $installed = (Test-Path "C:\Program Files\Google\Drive File Stream\launch.bat") -or [bool]$uninstall

    if ($installed) {
        L "Drive for desktop already installed."
    } else {
        if (Would "install Drive for desktop (silent download from dl.google.com)") {
            $exe = Join-Path $env:TEMP "GoogleDriveSetup.exe"
            try {
                Invoke-WebRequest -Uri "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe" -OutFile $exe -UseBasicParsing
            } catch {
                L "FAILED to download: $($_.Exception.Message)"
                Write-Host "STATUS|$Computer|Install=failed|Reason=download"
                return
            }
            $p = Start-Process -FilePath $exe -ArgumentList "--silent --desktop_shortcut --gsuite_shortcuts=false" -Wait -PassThru
            L "Installer exit code $($p.ExitCode)"
            Remove-Item $exe -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path "C:\Program Files\Google\Drive File Stream\launch.bat")) {
                L "FAILED: the installer ran but Drive is not there."
                Write-Host "STATUS|$Computer|Install=failed|Reason=notpresent"
                return
            }
        }
    }

    $k = "HKLM:\SOFTWARE\Google\DriveFS"
    if (Would "apply Drive settings: stream as G:, start at sign in, streaming only (no local mirror)") {
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        New-ItemProperty -Path $k -Name "DefaultMountPoint"       -Value "G:" -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $k -Name "AutoStartOnLogin"        -Value 1    -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $k -Name "DisableOnboardingDialog" -Value 1    -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $k -Name "DisableMirroredFolders"  -Value 1    -PropertyType DWord  -Force | Out-Null
        New-ItemProperty -Path $k -Name "DisableMirroredMyDrive"  -Value 1    -PropertyType DWord  -Force | Out-Null
    }

    if ($env:RestrictDomain -ne "false") {
        if (Would "restrict Drive sign in to @oesu.org accounts") {
            if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
            New-ItemProperty -Path $k -Name "RestrictAccountsPattern" -Value ".*@oesu\.org" -PropertyType String -Force | Out-Null
        }
    }

    $who = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($who) {
        L "Logged in now: $who"
        if (Would "start Drive for desktop in $who's session") {
            $launch = "C:\Program Files\Google\Drive File Stream\launch.bat"
            try {
                $a  = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$launch`""
                $pr = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName "OESU start Google Drive once" -Action $a -Principal $pr -Force | Out-Null
                Start-ScheduledTask -TaskName "OESU start Google Drive once"
                Start-Sleep -Seconds 10
                Unregister-ScheduledTask -TaskName "OESU start Google Drive once" -Confirm:$false -ErrorAction SilentlyContinue
            } catch { L "Could not start Drive in the user's session: $($_.Exception.Message)" }
        }

        if ($env:NotifyUser -ne "false") {
            if (Would "show $who a message asking them to sign in to Drive") {
                $msg = "Google Drive has been installed on this computer. Please click the Google Drive icon near the clock and sign in with your @oesu.org account. Your shared folders are moving from the OESU server to Google Drive. Contact the technology department with any questions."
                try { & msg.exe $who /TIME:600 $msg 2>&1 | Out-Null }
                catch { L "Could not show the sign in message (msg.exe unavailable)." }
            }
        }
    } else {
        L "Nobody is logged in right now. Drive starts and prompts at their next sign in."
    }

    L "Drive letters were NOT touched. That is Letters mode, run per group after the freeze."

    $profiles = @(Get-UserProfiles)
    $drive = Get-DriveSignInState $profiles
    Write-Host ""
    Write-Host "RESULT for $Computer"
    Write-Host "  Drive for desktop : $(if ($drive.Installed) { 'installed' } else { 'NOT installed' })"
    Write-Host "  Mount point       : G:"
    Write-Host "  Signed in         : $(if ($drive.SignedIn.Count) { $drive.SignedIn -join ', ' } else { 'nobody yet' })"
    Write-Host "  NOT signed in     : $(if (@($profiles | Where-Object { $drive.SignedIn -notcontains $_.Folder }).Count) { (@($profiles | Where-Object { $drive.SignedIn -notcontains $_.Folder }).Folder) -join ', ' } else { 'none' })"
    Write-Host "  Letters remapped  : none (Install mode never changes letters)"
    Write-Host "STATUS|$Computer|Install=ok|DriveInstalled=$($drive.Installed)|SignedIn=$(if ($drive.SignedIn.Count) { $drive.SignedIn -join '+' } else { 'none' })"
}

# ============================================================= LETTERS

function Invoke-Letters {
    if (-not $env:Letters) {
        L "REFUSED: Letters mode was asked for but the Letters variable is empty."
        L "Nothing was changed. Set Letters, for example: N=G:\Shared drives\Shared Accounting"
        Write-Host "STATUS|$Computer|Letters=refused|Reason=empty"
        return
    }

    if (-not (Test-Path "C:\Program Files\Google\Drive File Stream\launch.bat")) {
        L "REFUSED: Drive for desktop is not installed on this PC, so G: will never appear."
        L "Nothing was changed. Run Install mode here first."
        Write-Host "STATUS|$Computer|Letters=refused|Reason=drivemissing"
        return
    }

    $pairs = @(
        foreach ($item in ($env:Letters -split ";")) {
            if ($item -match '^\s*([A-Za-z]):?\s*=\s*(\S.*?)\s*$') {
                $target = $Matches[2].TrimEnd('\')
                [pscustomobject]@{ Letter = $Matches[1].ToUpper(); Target = $target; Label = ($target -split '\\')[-1] }
            } elseif ($item.Trim()) {
                L "Ignored an entry that could not be read: '$item'"
            }
        }
    )
    if ($pairs.Count -eq 0) {
        L "REFUSED: no usable letter pairs in: $env:Letters"
        Write-Host "STATUS|$Computer|Letters=refused|Reason=unparseable"
        return
    }

    L ("Letters to map at sign in: " + (($pairs | ForEach-Object { "$($_.Letter): to $($_.Target)" }) -join "; "))

    if (Would "write the letter list and register the sign in task that applies it") {
        $pairs | Export-Csv -Path $Cfg -NoTypeInformation -Encoding UTF8

        $mapScript = @'
# Runs at sign in as the user. Points the listed drive letters at Google Drive folders.
$cfg = "C:\ProgramData\OESU\drive-letters.csv"
$log = Join-Path $env:LOCALAPPDATA "OESU-drive-letters.log"
function W([string]$m) { "$(Get-Date -Format s) $m" | Out-File -FilePath $log -Append -Encoding utf8 }
if (-not (Test-Path $cfg)) { exit 0 }
$map = @(Import-Csv $cfg)

# Drive for desktop needs a moment to mount after sign in. Wait up to 5 minutes.
$deadline = (Get-Date).AddMinutes(5)
do {
    $missing = @($map | Where-Object { -not (Test-Path -LiteralPath $_.Target) })
    if ($missing.Count -eq 0) { break }
    Start-Sleep -Seconds 5
} while ((Get-Date) -lt $deadline)

foreach ($m in $map) {
    $d = "$($m.Letter):"
    if (-not (Test-Path -LiteralPath $m.Target)) { W "$d not mapped, folder not found: $($m.Target). Is Drive signed in?"; continue }
    & net.exe use $d /delete /y 2>&1 | Out-Null
    & subst.exe $d /d 2>&1 | Out-Null
    & subst.exe $d $m.Target 2>&1 | Out-Null
    $key = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$($m.Letter)\DefaultLabel"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name "(default)" -Value $m.Label
    if (Test-Path "$d\") { W "$d mapped to $($m.Target)" } else { W "$d FAILED to map to $($m.Target)" }
}
'@
        Set-Content -Path $MapPath -Value $mapScript -Encoding UTF8

        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$MapPath`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

        L "Registered the sign in task. Letters switch the next time each user signs in."
    }

    $profiles = @(Get-UserProfiles)
    $drive = Get-DriveSignInState $profiles
    $notSignedIn = @($profiles | Where-Object { $drive.SignedIn -notcontains $_.Folder })

    Write-Host ""
    Write-Host "RESULT for $Computer"
    Write-Host "  Letters queued    : $(($pairs | ForEach-Object { "$($_.Letter): -> $($_.Target)" }) -join '; ')"
    Write-Host "  Applies           : at each user's next sign in"
    Write-Host "  Signed in to Drive: $(if ($drive.SignedIn.Count) { $drive.SignedIn -join ', ' } else { 'nobody yet' })"
    if ($notSignedIn.Count -gt 0) {
        Write-Host "  WARNING           : these profiles have NOT signed in to Drive, so their new letters will not work until they do: $(($notSignedIn.Folder) -join ', ')"
    }
    Write-Host "STATUS|$Computer|Letters=$(if ($WhatIf) { 'whatif' } else { 'set' })|Pairs=$($pairs.Count)|NotSignedIn=$(if ($notSignedIn.Count) { ($notSignedIn.Folder) -join '+' } else { 'none' })"
}

# ================================================================ UNDO

function Invoke-Undo {
    $hadTask = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    $hadCfg  = Test-Path $Cfg

    if (-not $hadTask -and -not $hadCfg) {
        L "Nothing to undo on this PC: no letter task and no letter list."
        Write-Host "STATUS|$Computer|Undo=nothingtodo"
        return
    }

    if (Would "remove the sign in task and the letter list (Drive for desktop stays installed)") {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $Cfg, $MapPath -Force -ErrorAction SilentlyContinue
    }

    L "The user must sign out and back in for their old server letters to return."
    Write-Host "STATUS|$Computer|Undo=$(if ($WhatIf) { 'whatif' } else { 'done' })|HadTask=$hadTask|HadList=$hadCfg"
}

# =============================================================== run it

switch ($Mode) {
    "Discover" { Invoke-Discover }
    "Install"  { Invoke-Install }
    "Letters"  { Invoke-Letters }
    "Undo"     { Invoke-Undo }
}

Write-Host ""
Write-Host "DONE|$ScriptName|$Version|$Mode|$(if ($WhatIf) { 'whatif' } else { 'live' })|$Computer"
exit 0
