<#
=======================================================================
 OESU-HiveNode.ps1
 Version 1.0  (2026-09-30)

 Maintenance for the always-on PaperCut Hive computers (BES-HIVE2,
 TES-HIVE2, OHS-HIVE2 and friends). PowerShell, runs as SYSTEM through
 the "OESU - Run Script" launcher in Datto RMM. Safe to rerun.

 MODES  (launcher variable: Mode)
   Check    READ ONLY. The default. Reports uptime, pending reboot
            flags, pending Windows updates, power and network adapter
            sleep settings, and the state of the PaperCut Hive
            services. Changes nothing.
   Harden   Stops the PC from ever sleeping (AC and battery), turns
            hibernate off, turns off "allow the computer to turn off
            this device" on every physical network adapter, and sets
            Windows Update active hours to 6 AM to 6 PM so Windows
            never restarts it during the school day. No reboot.
   Update   Downloads and installs every pending Windows update that
            is not hidden, using the Windows Update Agent (no extra
            module needed). Does NOT reboot.
   Reboot   Schedules a restart in Delay seconds (default 60) and
            exits, so the Datto job records its result before the
            machine goes down.
   Full     Harden, then Update, then Reboot. This is the one to use
            before school on a node with a pending reboot.

 Blank, missing or unrecognised Mode means Check, so a typo gives you a
 report and never a reboot.

 OTHER VARIABLES (passed through the launcher's Params JSON)
   Delay      Seconds before the restart in Reboot or Full. Default 60.
   WhatIf     true = report what would happen and change nothing.
              Honoured in Harden, Update, Reboot and Full.

 OUTPUT
   Line 1 is a banner. Machine readable lines start with BANNER|,
   STATUS|, ACTION| or RESULT| so results from several nodes can be
   pasted together.
   Log: C:\ProgramData\OESU\HiveNode.log
=======================================================================
#>

$ErrorActionPreference = "Continue"

$ScriptName = "OESU-HiveNode"
$Version    = "1.0"
$Dir        = "C:\ProgramData\OESU"
$Log        = Join-Path $Dir "HiveNode.log"
$Computer   = $env:COMPUTERNAME

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

function L([string]$m) {
    $line = "$(Get-Date -Format s) $m"
    try { $line | Out-File -FilePath $Log -Append -Encoding utf8 } catch { }
    Write-Host $m
}

# ---------------------------------------------------------------- mode

$RawMode = if ($env:Mode) { $env:Mode.Trim() } else { "" }
$Valid   = @("Check", "Harden", "Update", "Reboot", "Full")
$Mode    = ($Valid | Where-Object { $_ -ieq $RawMode } | Select-Object -First 1)

$ModeNote = ""
if (-not $Mode) {
    $Mode = "Check"
    if ($RawMode) { $ModeNote = "Mode '$RawMode' not recognised, fell back to Check (read only)." }
    else          { $ModeNote = "Mode not set, using Check (read only)." }
}

$WhatIf = ($env:WhatIf -eq "true")
$Delay  = 60
if ($env:Delay -match '^\d+$') { $Delay = [int]$env:Delay }
if ($Delay -lt 15) { $Delay = 15 }

Write-Host "======================================================================="
Write-Host " $ScriptName v$Version   mode: $Mode$(if ($WhatIf) { ' (WHATIF, nothing will change)' })"
Write-Host " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($Mode -eq "Check") { Write-Host " This mode is READ ONLY. No setting is changed and nothing restarts." }
Write-Host "======================================================================="
Write-Host "BANNER|$ScriptName|$Version|$Mode|$(if ($WhatIf) { 'whatif' } else { 'live' })|$Computer"
if ($ModeNote) { L "NOTE: $ModeNote" }
Write-Host ""

function Would([string]$m) {
    if ($WhatIf) { L "WOULD: $m"; Write-Host "ACTION|$Computer|would|$m" }
    else         { L $m;          Write-Host "ACTION|$Computer|did|$m" }
    return (-not $WhatIf)
}

# --------------------------------------------------------------- check

function Get-PendingRebootReasons {
    $r = @()
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $r += "CBS" }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $r += "WindowsUpdate" }
    $pfr = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfr) { $r += "PendingFileRename" }
    return $r
}

function Get-HiveServices {
    Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -match 'PaperCut|Hive' -or $_.Name -match 'papercut|hive|pc-'
    }
}

function Show-Check {
    $os = Get-CimInstance Win32_OperatingSystem
    $boot = $os.LastBootUpTime
    $up = (Get-Date) - $boot
    L ("Uptime: {0:N1} days (last boot {1})" -f $up.TotalDays, $boot.ToString('yyyy-MM-dd HH:mm'))
    Write-Host ("STATUS|$Computer|uptime_days|{0:N1}" -f $up.TotalDays)

    $reasons = Get-PendingRebootReasons
    L ("Pending reboot: " + $(if ($reasons) { $reasons -join ", " } else { "none" }))
    Write-Host ("STATUS|$Computer|pending_reboot|" + $(if ($reasons) { $reasons -join "+" } else { "none" }))

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result   = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $n = $result.Updates.Count
        L "Pending Windows updates: $n"
        Write-Host "STATUS|$Computer|pending_updates|$n"
        for ($i = 0; $i -lt $n; $i++) { L ("  - " + $result.Updates.Item($i).Title) }
    } catch { L "Pending Windows updates: could not query ($($_.Exception.Message))" }

    $ac = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Select-String 'Current AC Power Setting Index' | ForEach-Object { $_.ToString().Split(':')[-1].Trim() })
    $dc = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Select-String 'Current DC Power Setting Index' | ForEach-Object { $_.ToString().Split(':')[-1].Trim() })
    L "Sleep timeout (hex seconds) AC=$ac DC=$dc   (0x00000000 means never)"
    Write-Host "STATUS|$Computer|sleep_ac|$ac"

    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    foreach ($nic in $nics) {
        $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
        L ("NIC {0}: status {1}, AllowComputerToTurnOffDevice={2}" -f $nic.Name, $nic.Status, $(if ($pm) { $pm.AllowComputerToTurnOffDevice } else { 'n/a' }))
    }

    $ah = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -ErrorAction SilentlyContinue
    if ($ah) { L ("Windows Update active hours: {0} to {1}" -f $ah.ActiveHoursStart, $ah.ActiveHoursEnd) }

    $svcs = Get-HiveServices
    if ($svcs) {
        foreach ($s in $svcs) {
            L ("Service {0} ({1}): {2}, start {3}" -f $s.DisplayName, $s.Name, $s.Status, $s.StartType)
            Write-Host "STATUS|$Computer|service|$($s.Name)|$($s.Status)"
        }
    } else {
        L "No PaperCut Hive service found on this computer."
        Write-Host "STATUS|$Computer|service|none|missing"
    }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
    L "IPv4: $ip"
    Write-Host "STATUS|$Computer|ip|$ip"
}

# -------------------------------------------------------------- harden

function Do-Harden {
    if (Would "Set sleep and hibernate timeouts to never (AC and DC)") {
        powercfg /change standby-timeout-ac 0   | Out-Null
        powercfg /change standby-timeout-dc 0   | Out-Null
        powercfg /change hibernate-timeout-ac 0 | Out-Null
        powercfg /change hibernate-timeout-dc 0 | Out-Null
        powercfg /hibernate off                 | Out-Null
    }
    if (Would "Keep the disk and display timeouts sane (disk never, display 20 min)") {
        powercfg /change disk-timeout-ac 0     | Out-Null
        powercfg /change monitor-timeout-ac 20 | Out-Null
    }
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
    foreach ($nic in $nics) {
        if (Would "Disable power management on network adapter '$($nic.Name)'") {
            try { Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction Stop } catch { L "  (could not change: $($_.Exception.Message))" }
        }
    }
    if (Would "Set Windows Update active hours 6 AM to 6 PM") {
        $k = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        Set-ItemProperty -Path $k -Name ActiveHoursStart -Value 6  -Type DWord
        Set-ItemProperty -Path $k -Name ActiveHoursEnd   -Value 18 -Type DWord
    }
}

# -------------------------------------------------------------- update

function Do-Update {
    try {
        $session   = New-Object -ComObject Microsoft.Update.Session
        $searcher  = $session.CreateUpdateSearcher()
        $result    = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        $updates   = $result.Updates
        if ($updates.Count -eq 0) { L "No pending Windows updates."; Write-Host "RESULT|$Computer|updates|0|none"; return }

        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $u = $updates.Item($i)
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
            L ("Queue: " + $u.Title)
            $coll.Add($u) | Out-Null
        }
        if (-not (Would "Download and install $($coll.Count) Windows update(s)")) { return }

        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
        $dr = $dl.Download()
        L ("Download result code: {0} (2 = succeeded)" -f $dr.ResultCode)

        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $ir = $inst.Install()
        L ("Install result code: {0} (2 = succeeded, 3 = succeeded with errors), reboot required: {1}" -f $ir.ResultCode, $ir.RebootRequired)
        for ($i = 0; $i -lt $coll.Count; $i++) {
            L ("  {0} -> {1}" -f $coll.Item($i).Title, $ir.GetUpdateResult($i).ResultCode)
        }
        Write-Host "RESULT|$Computer|updates|$($coll.Count)|code$($ir.ResultCode)|reboot$($ir.RebootRequired)"
    } catch {
        L "Update step failed: $($_.Exception.Message)"
        Write-Host "RESULT|$Computer|updates|error|$($_.Exception.Message)"
    }
}

# -------------------------------------------------------------- reboot

function Do-Reboot {
    if (Would "Restart this computer in $Delay seconds") {
        shutdown.exe /r /t $Delay /c "OESU Datto RMM: PaperCut Hive node maintenance restart" /d p:2:17
        Write-Host "RESULT|$Computer|reboot|scheduled|$Delay"
    } else {
        Write-Host "RESULT|$Computer|reboot|skipped|whatif"
    }
}

# ---------------------------------------------------------------- run

Show-Check
Write-Host ""

switch ($Mode) {
    "Check"  { }
    "Harden" { Do-Harden }
    "Update" { Do-Update }
    "Reboot" { Do-Reboot }
    "Full"   { Do-Harden; Write-Host ""; Do-Update; Write-Host ""; Do-Reboot }
}

Write-Host ""
L "Done. Mode $Mode finished on $Computer."
exit 0
