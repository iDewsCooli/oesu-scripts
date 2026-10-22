<#
=======================================================================
 OESU-AcrobatReader.ps1
 Version 1.0  (2026-10-22)

 Diagnoses and repairs the "Adobe can't save PDFs / keeps asking me to
 sign in" problem seen at OESU in Sept and Oct 2026 (Jen in HR, Mae,
 Bernadette at OHS). PowerShell, runs as SYSTEM through the
 "OESU - Run Script" launcher in Datto RMM. Safe to rerun.

 BACKGROUND
 Adobe's unified 64-bit installer reports itself as "Adobe Acrobat
 (64-bit)" whether the PC has free Reader or paid Acrobat. Since the
 October 2026 builds (26.002.21996 and 26.002.22031) Reader installs
 have been flipping into an unlicensed Acrobat state that nags for an
 Adobe sign-in and gates Save / Save As. This script tells you which
 state a PC is in, quiets the nags, and if needed puts clean Reader
 back with the self-updater under OESU control.

 MODES  (launcher variable: Mode)
   Check      READ ONLY. The default. Reports the Adobe product and
              version actually installed, whether it is in Reader or
              paid-Acrobat mode, when it was last installed or updated,
              whether Creative Cloud is present, the Adobe updater
              state, which OESU policy keys are already set, Windows
              Controlled Folder Access, and any recent Acrobat crashes
              or blocked writes in the event logs. Changes nothing.
   Lock       Applies the OESU policy keys only: suppresses upsell and
              in-product marketing nags, keeps Protected Mode on, and
              (only if DisableUpdater=true) turns the Adobe self-updater
              off. Does not uninstall or reinstall anything. No reboot.
   Reinstall  Uninstalls every "Adobe Acrobat" entry, downloads the
              enterprise 64-bit Reader MUI installer from Adobe,
              verifies it is Authenticode-signed by Adobe, installs it
              silently, then applies Lock. The PC should be idle
              (Acrobat is closed by force). No reboot.
   Unlock     Removes the OESU policy keys set by Lock and re-enables
              the updater. Adobe's defaults come back.

 Blank, missing or unrecognised Mode means Check, so a typo gives you a
 report and never a reinstall.

 OTHER VARIABLES (passed through the launcher's Params JSON)
   WhatIf           true = report what would happen and change nothing.
                    Honoured in Lock, Reinstall and Unlock.
   DisableUpdater   Lock and Reinstall. "true" turns the Adobe updater
                    off (bUpdater=0 plus the ARM service and task).
                    Default false: leave Adobe's updater running until
                    Datto is managing Adobe versions. If you set this
                    true, Datto must push Adobe security updates.
   InstallerUrl     Reinstall. Override the Reader installer URL.
                    Default is the 26.002.22031 64-bit MUI enterprise
                    installer on ardownload2.adobe.com.
   KeepIfReader     Reinstall. Default true: if Check already shows
                    Reader mode (SCAPackageLevel 1) the reinstall is
                    skipped and only Lock runs. Set false to force it.

 OUTPUT
   Line 1 is a banner. Machine readable lines start with BANNER|,
   STATUS|, ACTION| or RESULT| so results from many PCs can be pasted
   together and sorted. The line to look at first is
   STATUS|<pc>|adobe_mode|... which says Reader, Acrobat or Missing.
   Log: C:\ProgramData\OESU\AcrobatReader.log
=======================================================================
#>

$ErrorActionPreference = "Continue"

$ScriptName = "OESU-AcrobatReader"
$Version    = "1.0"
$Dir        = "C:\ProgramData\OESU"
$Log        = Join-Path $Dir "AcrobatReader.log"
$Computer   = $env:COMPUTERNAME

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

function L([string]$m) {
    $line = "$(Get-Date -Format s) $m"
    try { $line | Out-File -FilePath $Log -Append -Encoding utf8 } catch { }
    Write-Host $m
}

# ---------------------------------------------------------------- mode

$RawMode = if ($env:Mode) { $env:Mode.Trim() } else { "" }
$Valid   = @("Check", "Lock", "Reinstall", "Unlock")
$Mode    = ($Valid | Where-Object { $_ -ieq $RawMode } | Select-Object -First 1)

$ModeNote = ""
if (-not $Mode) {
    $Mode = "Check"
    if ($RawMode) { $ModeNote = "Mode '$RawMode' not recognised, fell back to Check (read only)." }
    else          { $ModeNote = "Mode not set, using Check (read only)." }
}

$WhatIf         = ($env:WhatIf -eq "true")
$DisableUpdater = ($env:DisableUpdater -eq "true")
$KeepIfReader   = -not ($env:KeepIfReader -eq "false")
$InstallerUrl   = if ($env:InstallerUrl) { $env:InstallerUrl.Trim() } else {
    "https://ardownload2.adobe.com/pub/adobe/reader/win/AcrobatDC/2600222031/AcroRdrDCx642600222031_MUI.exe"
}

Write-Host "======================================================================="
Write-Host " $ScriptName v$Version   mode: $Mode$(if ($WhatIf) { ' (WHATIF, nothing will change)' })"
Write-Host " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($Mode -eq "Check") { Write-Host " This mode is READ ONLY. No setting is changed and nothing is installed." }
Write-Host "======================================================================="
Write-Host "BANNER|$ScriptName|$Version|$Mode|$(if ($WhatIf) { 'whatif' } else { 'live' })|$Computer"
if ($ModeNote) { L "NOTE: $ModeNote" }
Write-Host ""

function Would([string]$m) {
    if ($WhatIf) { L "WOULD: $m"; Write-Host "ACTION|$Computer|would|$m" }
    else         { L $m;          Write-Host "ACTION|$Computer|did|$m" }
    return (-not $WhatIf)
}

# ------------------------------------------------------------ helpers

$UninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
$AcroInstKey  = "HKLM:\SOFTWARE\Adobe\Adobe Acrobat\DC\Installer"
$LockKey      = "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown"
$IpmKey       = Join-Path $LockKey "cIPM"
$ArmService   = "AdobeARMservice"
$ArmTask      = "Adobe Acrobat Update Task"

function Get-AdobeInstalls {
    $out = @()
    foreach ($root in $UninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and $p.DisplayName -match '^Adobe (Acrobat|Reader|Creative Cloud)') {
                $out += [pscustomobject]@{
                    Name        = $p.DisplayName
                    Version     = $p.DisplayVersion
                    InstallDate = $p.InstallDate
                    ProductCode = $k.PSChildName
                    Uninstall   = $p.UninstallString
                    Location    = $p.InstallLocation
                }
            }
        }
    }
    return $out
}

function Get-AdobeMode {
    # SCAPackageLevel is written by Adobe's unified installer:
    # 1 = Reader (free). Higher values are the paid Acrobat tiers.
    $lvl = (Get-ItemProperty $AcroInstKey -Name SCAPackageLevel -ErrorAction SilentlyContinue).SCAPackageLevel
    if ($null -eq $lvl) { return @{ Level = $null; Mode = "Unknown" } }
    if ([int]$lvl -eq 1) { return @{ Level = $lvl; Mode = "Reader" } }
    return @{ Level = $lvl; Mode = "Acrobat" }
}

function Get-RegDword([string]$path, [string]$name) {
    $v = (Get-ItemProperty $path -Name $name -ErrorAction SilentlyContinue).$name
    if ($null -eq $v) { return "unset" } else { return $v }
}

function Set-RegDword([string]$path, [string]$name, [int]$value) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $name -Value $value -Type DWord
}

function Remove-RegValue([string]$path, [string]$name) {
    if (Test-Path $path) { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }
}

# --------------------------------------------------------------- check

function Show-Check {
    $installs = Get-AdobeInstalls
    $acro = $installs | Where-Object { $_.Name -match '^Adobe (Acrobat|Reader)' }
    $cc   = $installs | Where-Object { $_.Name -match '^Adobe Creative Cloud' }

    if (-not $acro) {
        L "Adobe Acrobat / Reader: NOT INSTALLED"
        Write-Host "STATUS|$Computer|adobe_mode|Missing"
    } else {
        foreach ($a in $acro) {
            L ("Installed: {0}  version {1}  installed {2}  product {3}" -f $a.Name, $a.Version, $a.InstallDate, $a.ProductCode)
            Write-Host "STATUS|$Computer|adobe_install|$($a.Name)|$($a.Version)|$($a.InstallDate)|$($a.ProductCode)"
        }
        $m = Get-AdobeMode
        L ("Product mode: {0} (SCAPackageLevel = {1})" -f $m.Mode, $(if ($null -eq $m.Level) { 'not present' } else { $m.Level }))
        Write-Host "STATUS|$Computer|adobe_mode|$($m.Mode)|$($m.Level)"
        if ($m.Mode -eq "Acrobat") {
            L "  >> This PC is running the PAID Acrobat product. If there is no Creative Cloud licence here, that is the cause of the sign-in nag and the blocked Save."
        }
    }

    if ($cc) {
        L ("Creative Cloud desktop app: present, version {0} (user may hold an Adobe licence or trial)" -f $cc[0].Version)
        Write-Host "STATUS|$Computer|creative_cloud|present|$($cc[0].Version)"
    } else {
        L "Creative Cloud desktop app: not installed"
        Write-Host "STATUS|$Computer|creative_cloud|absent"
    }

    # Executable on disk, to confirm what actually launches
    $exe = @("C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
             "C:\Program Files (x86)\Adobe\Acrobat DC\Acrobat\Acrobat.exe",
             "C:\Program Files (x86)\Adobe\Acrobat Reader DC\Reader\AcroRd32.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) {
        $fv = (Get-Item $exe).VersionInfo
        L ("Binary: {0}  file version {1}  modified {2:yyyy-MM-dd HH:mm}" -f $exe, $fv.FileVersion, (Get-Item $exe).LastWriteTime)
        Write-Host "STATUS|$Computer|adobe_exe|$exe|$($fv.FileVersion)|$((Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd'))"
    }

    # Updater state
    $svc = Get-Service -Name $ArmService -ErrorAction SilentlyContinue
    if ($svc) {
        L ("Adobe updater service ({0}): {1}, start {2}" -f $ArmService, $svc.Status, $svc.StartType)
        Write-Host "STATUS|$Computer|arm_service|$($svc.Status)|$($svc.StartType)"
    } else {
        L "Adobe updater service: not present"
        Write-Host "STATUS|$Computer|arm_service|missing"
    }
    try {
        $t = Get-ScheduledTask -TaskName $ArmTask -ErrorAction Stop
        L ("Adobe updater task: {0}" -f $t.State)
        Write-Host "STATUS|$Computer|arm_task|$($t.State)"
    } catch { L "Adobe updater task: not present"; Write-Host "STATUS|$Computer|arm_task|missing" }

    # OESU policy keys
    $bUpd  = Get-RegDword $LockKey "bUpdater"
    $bUps  = Get-RegDword $LockKey "bAcroSuppressUpsell"
    $bPM   = Get-RegDword $LockKey "bProtectedMode"
    $bLnch = Get-RegDword $IpmKey  "bShowMsgAtLaunch"
    $bView = Get-RegDword $IpmKey  "bDontShowMsgWhenViewingDoc"
    L ("Policy keys: bUpdater={0} bAcroSuppressUpsell={1} bProtectedMode={2} cIPM\bShowMsgAtLaunch={3} cIPM\bDontShowMsgWhenViewingDoc={4}" -f $bUpd, $bUps, $bPM, $bLnch, $bView)
    Write-Host "STATUS|$Computer|policy|bUpdater=$bUpd;bAcroSuppressUpsell=$bUps;bProtectedMode=$bPM;bShowMsgAtLaunch=$bLnch;bDontShowMsgWhenViewingDoc=$bView"

    # Windows Controlled Folder Access (blocks unknown apps from writing to Documents and Desktop)
    try {
        $cfa = (Get-MpPreference -ErrorAction Stop).EnableControlledFolderAccess
        $cfaText = switch ($cfa) { 0 { "Off" } 1 { "On (BLOCKING)" } 2 { "Audit" } default { "Unknown ($cfa)" } }
        L "Controlled Folder Access: $cfaText"
        Write-Host "STATUS|$Computer|controlled_folder_access|$cfaText"
    } catch { L "Controlled Folder Access: could not query (Defender not the active AV, or no cmdlet)"; Write-Host "STATUS|$Computer|controlled_folder_access|unknown" }

    # Recent evidence in the event logs (last 30 days)
    $since = (Get-Date).AddDays(-30)
    try {
        $msiIds = @(1033, 1034, 1035, 1036, 11707, 11724, 11728)
        $msi = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $since } -ErrorAction SilentlyContinue |
               Where-Object { ($msiIds -contains $_.Id) -and ($_.Message -match 'Adobe Acrobat|Adobe Reader') } |
               Select-Object -First 8
        if ($msi) {
            L "Adobe install / update events (last 30 days):"
            foreach ($e in $msi) {
                $first = ($e.Message -split "`n")[0].Trim()
                L ("  {0:yyyy-MM-dd HH:mm}  id {1}  {2}" -f $e.TimeCreated, $e.Id, $first)
                Write-Host ("STATUS|$Computer|adobe_msi_event|{0:yyyy-MM-dd HH:mm}|{1}" -f $e.TimeCreated, $e.Id)
            }
        } else { L "Adobe install / update events (last 30 days): none" }
    } catch { L "Adobe install / update events: could not read Application log" }

    try {
        $crash = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; StartTime = $since } -ErrorAction SilentlyContinue |
                 Where-Object { $_.Message -match 'Acrobat\.exe|AcroRd32\.exe|AcroCEF|AcroWebView' } | Select-Object -First 5
        $n = @($crash).Count
        L "Acrobat crashes (last 30 days): $n"
        Write-Host "STATUS|$Computer|acrobat_crashes_30d|$n"
        foreach ($e in $crash) { L ("  {0:yyyy-MM-dd HH:mm}  {1}" -f $e.TimeCreated, (($e.Message -split "`n")[0]).Trim()) }
    } catch { L "Acrobat crashes: could not read Application log" }

    try {
        $blk = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1123, 1127; StartTime = $since } -ErrorAction SilentlyContinue |
               Select-Object -First 5
        $n = @($blk).Count
        L "Defender blocked-write events 1123/1127 (last 30 days): $n"
        Write-Host "STATUS|$Computer|defender_blocked_writes_30d|$n"
        foreach ($e in $blk) { L ("  {0:yyyy-MM-dd HH:mm}  {1}" -f $e.TimeCreated, (($e.Message -split "`n")[0]).Trim()) }
    } catch { L "Defender blocked-write events: none or log not readable" }

    # Per-user Adobe state for any profile whose hive is loaded (signed-in users)
    try {
        $hives = Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-\d+-\d+-\d+-\d+$' }
        foreach ($h in $hives) {
            $sid = $h.PSChildName
            $base = "Registry::HKEY_USERS\$sid\Software\Adobe\Adobe Acrobat\DC"
            if (-not (Test-Path $base)) { continue }
            $who = $sid
            try { $who = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
            $pm = (Get-ItemProperty "$base\Privileged" -Name bProtectedMode -ErrorAction SilentlyContinue).bProtectedMode
            $hasId = Test-Path "$base\Identity"
            L ("User {0}: Acrobat has been launched; ProtectedMode={1}; Adobe identity cached={2}" -f $who, $(if ($null -eq $pm) { 'default' } else { $pm }), $hasId)
            Write-Host "STATUS|$Computer|user_adobe|$who|protectedmode=$(if ($null -eq $pm) { 'default' } else { $pm })|identity=$hasId"
        }
    } catch { }
}

# ---------------------------------------------------------------- lock

function Do-Lock {
    if (Would "Set FeatureLockDown: bAcroSuppressUpsell=1 (no 'upgrade to Acrobat Pro' nags)") {
        Set-RegDword $LockKey "bAcroSuppressUpsell" 1
    }
    if (Would "Set FeatureLockDown: bProtectedMode=1 (keep the sandbox on; it is the safe default)") {
        Set-RegDword $LockKey "bProtectedMode" 1
    }
    if (Would "Set FeatureLockDown\cIPM: bShowMsgAtLaunch=0 and bDontShowMsgWhenViewingDoc=1 (no in-product marketing pop-ups)") {
        Set-RegDword $IpmKey "bShowMsgAtLaunch" 0
        Set-RegDword $IpmKey "bDontShowMsgWhenViewingDoc" 1
    }
    if ($DisableUpdater) {
        if (Would "Set FeatureLockDown: bUpdater=0 and stop/disable the Adobe updater service and task (Datto now owns Adobe updates)") {
            Set-RegDword $LockKey "bUpdater" 0
            $svc = Get-Service -Name $ArmService -ErrorAction SilentlyContinue
            if ($svc) { try { Stop-Service $svc -Force -ErrorAction SilentlyContinue; Set-Service $svc -StartupType Disabled } catch { L "  (service change failed: $($_.Exception.Message))" } }
            try { Disable-ScheduledTask -TaskName $ArmTask -ErrorAction Stop | Out-Null } catch { }
        }
    } else {
        L "Updater left as is (DisableUpdater not set). Adobe will keep self-updating until Datto manages Adobe versions."
    }
    Write-Host "RESULT|$Computer|lock|$(if ($WhatIf) { 'whatif' } else { 'applied' })|updater_disabled=$DisableUpdater"
}

# -------------------------------------------------------------- unlock

function Do-Unlock {
    if (Would "Remove OESU FeatureLockDown keys (bAcroSuppressUpsell, bProtectedMode, bUpdater, cIPM values)") {
        Remove-RegValue $LockKey "bAcroSuppressUpsell"
        Remove-RegValue $LockKey "bProtectedMode"
        Remove-RegValue $LockKey "bUpdater"
        Remove-RegValue $IpmKey  "bShowMsgAtLaunch"
        Remove-RegValue $IpmKey  "bDontShowMsgWhenViewingDoc"
    }
    if (Would "Re-enable the Adobe updater service and task") {
        $svc = Get-Service -Name $ArmService -ErrorAction SilentlyContinue
        if ($svc) { try { Set-Service $svc -StartupType Automatic; Start-Service $svc -ErrorAction SilentlyContinue } catch { } }
        try { Enable-ScheduledTask -TaskName $ArmTask -ErrorAction Stop | Out-Null } catch { }
    }
    Write-Host "RESULT|$Computer|unlock|$(if ($WhatIf) { 'whatif' } else { 'applied' })"
}

# ----------------------------------------------------------- reinstall

function Do-Reinstall {
    $m = Get-AdobeMode
    $acro = Get-AdobeInstalls | Where-Object { $_.Name -match '^Adobe (Acrobat|Reader)' }

    if ($acro -and $m.Mode -eq "Reader" -and $KeepIfReader) {
        L "Already in Reader mode (SCAPackageLevel 1). Skipping the reinstall and applying Lock only. Set KeepIfReader=false to force."
        Write-Host "RESULT|$Computer|reinstall|skipped|already_reader"
        Do-Lock
        return
    }

    # 1. Download the installer first, so a failed download never leaves the PC with no PDF reader.
    $dl = Join-Path $Dir ("AcroRdr_" + (Get-Date -Format 'yyyyMMddHHmm') + ".exe")
    if (Would "Download Reader installer from $InstallerUrl") {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $dl -UseBasicParsing -TimeoutSec 900
        } catch {
            L "Download failed: $($_.Exception.Message)"
            Write-Host "RESULT|$Computer|reinstall|failed|download"
            exit 1
        }
        $sig = Get-AuthenticodeSignature -FilePath $dl
        $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "none" }
        L ("Installer signature: {0}  signer: {1}" -f $sig.Status, $signer)
        if ($sig.Status -ne "Valid" -or $signer -notmatch 'Adobe') {
            L "Installer is not validly signed by Adobe. Stopping before any uninstall."
            Write-Host "RESULT|$Computer|reinstall|failed|bad_signature"
            Remove-Item $dl -Force -ErrorAction SilentlyContinue
            exit 1
        }
    }

    # 2. Close Acrobat and remove every Adobe Acrobat / Reader entry.
    if (Would "Close Acrobat / Reader processes") {
        Get-Process -Name Acrobat, AcroRd32, AcroCEF, AcroWebView, AdobeCollabSync -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    foreach ($a in $acro) {
        if ($a.ProductCode -match '^\{[0-9A-Fa-f\-]+\}$') {
            if (Would "Uninstall '$($a.Name)' $($a.Version) (msiexec /x $($a.ProductCode))") {
                $p = Start-Process msiexec.exe -ArgumentList "/x $($a.ProductCode) /qn /norestart" -Wait -PassThru
                L ("  uninstall exit code {0} (0 or 3010 is fine)" -f $p.ExitCode)
            }
        } else {
            L ("  '{0}' has no MSI product code; leaving it (uninstall string: {1})" -f $a.Name, $a.Uninstall)
        }
    }

    # 3. Install Reader silently. /sAll = silent, /rs = suppress reboot, /msi passes MSI properties.
    if (Would "Install Reader silently from $dl") {
        $instArgs = "/sAll /rs /rps /msi EULA_ACCEPT=YES DISABLEDESKTOPSHORTCUT=1"
        $p = Start-Process -FilePath $dl -ArgumentList $instArgs -Wait -PassThru
        L ("  install exit code {0} (0 or 3010 is fine)" -f $p.ExitCode)
        Remove-Item $dl -Force -ErrorAction SilentlyContinue
        $m2 = Get-AdobeMode
        $new = Get-AdobeInstalls | Where-Object { $_.Name -match '^Adobe (Acrobat|Reader)' } | Select-Object -First 1
        L ("  now installed: {0} {1}, mode {2}" -f $(if ($new) { $new.Name } else { 'nothing' }), $(if ($new) { $new.Version } else { '' }), $m2.Mode)
        Write-Host "RESULT|$Computer|reinstall|exit$($p.ExitCode)|$($m2.Mode)|$(if ($new) { $new.Version } else { 'missing' })"
    } else {
        Write-Host "RESULT|$Computer|reinstall|whatif"
    }

    # 4. Policy keys.
    Do-Lock
}

# ---------------------------------------------------------------- run

Show-Check
Write-Host ""

switch ($Mode) {
    "Check"     { }
    "Lock"      { Do-Lock }
    "Unlock"    { Do-Unlock }
    "Reinstall" { Do-Reinstall }
}

Write-Host ""
L "Done. Mode $Mode finished on $Computer."
exit 0
