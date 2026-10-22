<#
=======================================================================
 OESU-NativeVpn.ps1
 Version 1.0  (2026-10-22)

 Creates (or checks, or removes) a ready-to-use L2TP over IPsec VPN
 connection on a Windows PC using the client built into Windows, so
 staff can reach a school network without installing FortiClient.
 Built for Sim Cook's BES HVAC access (NES-200877) against the
 "BES-Native" dial-up tunnel on the Bradford Elementary FortiGate,
 the same tunnel Fred Tougas uses from his Mac. Works for any OESU
 FortiGate that has an L2TP tunnel. PowerShell, runs as SYSTEM through
 the "OESU - Run Script" launcher in Datto RMM. Safe to rerun.

 WHAT THE PC ENDS UP WITH (Install)
   - A VPN entry visible to every user on the PC (Settings, Network and
     internet, VPN) named after Params.Name, pointed at Params.Server,
     L2TP/IPsec with the pre-shared key, MS-CHAP v2, "remember my
     sign-in info" on, and all traffic sent through the tunnel (split
     tunneling off, matching the FortiGate wizard build where the
     Windows client cannot learn routes from the firewall).
   - IPsec pinned to what the FortiGate offers: AES256 / SHA256 /
     DH group 14 for phase 1, AES256 / SHA256, no PFS for phase 2.
   - The PolicyAgent registry value AssumeUDPEncapsulationContextOnSendRule
     set to 2, which is what lets Windows L2TP/IPsec work from behind a
     home router. Windows reads this value at boot, so the PC needs one
     restart before the first connection if the value was not already 2.
   - A "Connect <Name>" shortcut on the public desktop that opens the
     Windows dial dialog for that connection.
   The user still types the VPN username and password the first time
   and ticks "Remember". The script never stores the password.

 MODES  (launcher variable: Mode)
   Check     READ ONLY. The default. Reports whether the connection
             exists, its settings, the registry value, the shortcut,
             and whether a restart is pending. Changes nothing.
   Install   Creates or updates the connection and the pieces above.
             Honours WhatIf.
   Remove    Deletes the connection and the shortcut. Leaves the
             registry value alone (harmless, and other VPNs may use it).
             Honours WhatIf.

 Blank, missing or unrecognised Mode means Check.

 OTHER VARIABLES (passed through the launcher's Params JSON)
   Name      Display name of the VPN entry. Default "OESU BES".
   Server    FortiGate public address. Default 68.184.42.74 (BES).
   Psk       The tunnel pre-shared key. Required for Install. Never
             written to the log or the job output.
   Pin       Default true: pin the IPsec proposal to AES256/SHA256/DH14
             (phase 1) and AES256/SHA256 no PFS (phase 2). Set false to
             leave Windows on its default proposal list.
   WhatIf    true = report what would happen and change nothing.

 OUTPUT
   Machine readable lines start with BANNER|, STATUS|, ACTION| or
   RESULT|. The line to look at first after Install is
   RESULT|<pc>|install|ok|reboot_needed=<yes/no>.
   Log: C:\ProgramData\OESU\NativeVpn.log
=======================================================================
#>

$ErrorActionPreference = "Continue"

$ScriptName = "OESU-NativeVpn"
$Version    = "1.0"
$Dir        = "C:\ProgramData\OESU"
$Log        = Join-Path $Dir "NativeVpn.log"
$Computer   = $env:COMPUTERNAME

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }

function L([string]$m) {
    $line = "$(Get-Date -Format s) $m"
    try { $line | Out-File -FilePath $Log -Append -Encoding utf8 } catch { }
    Write-Host $m
}

# ---------------------------------------------------------------- mode

$RawMode = if ($env:Mode) { $env:Mode.Trim() } else { "" }
$Valid   = @("Check", "Install", "Remove")
$Mode    = ($Valid | Where-Object { $_ -ieq $RawMode } | Select-Object -First 1)

$ModeNote = ""
if (-not $Mode) {
    $Mode = "Check"
    if ($RawMode) { $ModeNote = "Mode '$RawMode' not recognised, fell back to Check (read only)." }
    else          { $ModeNote = "Mode not set, using Check (read only)." }
}

$WhatIf = ($env:WhatIf -eq "true")
$Pin    = -not ($env:Pin -eq "false")
$Name   = if ($env:Name)   { $env:Name.Trim() }   else { "OESU BES" }
$Server = if ($env:Server) { $env:Server.Trim() } else { "68.184.42.74" }
$Psk    = if ($env:Psk)    { $env:Psk }           else { "" }

$RegPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\PolicyAgent"
$RegName  = "AssumeUDPEncapsulationContextOnSendRule"
$Shortcut = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) ("Connect " + $Name + ".lnk")

Write-Host "======================================================================="
Write-Host " $ScriptName v$Version   mode: $Mode$(if ($WhatIf) { ' (WHATIF, nothing will change)' })"
Write-Host " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host " connection: '$Name'  server: $Server  psk supplied: $(if ($Psk) { 'yes' } else { 'no' })"
if ($Mode -eq "Check") { Write-Host " This mode is READ ONLY. No setting is changed." }
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

function Get-Conn {
    try { Get-VpnConnection -Name $Name -AllUserConnection -ErrorAction Stop } catch { $null }
}

function Get-RegValue {
    try { (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction Stop).$RegName } catch { $null }
}

function Test-PendingReboot {
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    try {
        $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction Stop
        if ($p.PendingFileRenameOperations) { return $true }
    } catch { }
    return $false
}

function Report {
    $c = Get-Conn
    if ($c) {
        Write-Host "STATUS|$Computer|connection|present"
        Write-Host "STATUS|$Computer|server|$($c.ServerAddress)"
        Write-Host "STATUS|$Computer|tunnel|$($c.TunnelType)"
        Write-Host "STATUS|$Computer|auth|$($c.AuthenticationMethod -join ',')"
        Write-Host "STATUS|$Computer|split_tunnel|$($c.SplitTunneling)"
        Write-Host "STATUS|$Computer|remember_credential|$($c.RememberCredential)"
        Write-Host "STATUS|$Computer|state|$($c.ConnectionStatus)"
        $ipsec = $null
        try { $ipsec = $c.IPsecCustomPolicy } catch { }
        if ($ipsec) {
            Write-Host "STATUS|$Computer|ipsec|$($ipsec.EncryptionMethod)/$($ipsec.IntegrityCheckMethod)/$($ipsec.DHGroup) p2 $($ipsec.CipherTransformConstants)/$($ipsec.AuthenticationTransformConstants)/pfs $($ipsec.PfsGroup)"
        } else {
            Write-Host "STATUS|$Computer|ipsec|windows default"
        }
    } else {
        Write-Host "STATUS|$Computer|connection|missing"
    }
    $v = Get-RegValue
    Write-Host "STATUS|$Computer|nat_t_registry|$(if ($null -eq $v) { 'not set' } else { $v })"
    Write-Host "STATUS|$Computer|shortcut|$(if (Test-Path $Shortcut) { 'present' } else { 'missing' })"
    Write-Host "STATUS|$Computer|reboot_pending|$(if (Test-PendingReboot) { 'yes' } else { 'no' })"
    Write-Host "STATUS|$Computer|os|$((Get-CimInstance Win32_OperatingSystem).Caption)"
}

# -------------------------------------------------------------- check

if ($Mode -eq "Check") {
    Report
    Write-Host "RESULT|$Computer|check|ok"
    exit 0
}

# ------------------------------------------------------------- remove

if ($Mode -eq "Remove") {
    $c = Get-Conn
    if ($c) {
        if (Would "Remove VPN connection '$Name' (all users)") {
            try { Remove-VpnConnection -Name $Name -AllUserConnection -Force -ErrorAction Stop }
            catch { L "ERROR removing connection: $($_.Exception.Message)"; Write-Host "RESULT|$Computer|remove|failed"; exit 1 }
        }
    } else { L "Connection '$Name' not present, nothing to remove." }
    if (Test-Path $Shortcut) {
        if (Would "Delete shortcut $Shortcut") { Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue }
    }
    Report
    Write-Host "RESULT|$Computer|remove|ok"
    exit 0
}

# ------------------------------------------------------------ install

if (-not $Psk) {
    L "ERROR: Install needs the pre-shared key in Params as Psk. Nothing changed."
    Write-Host "RESULT|$Computer|install|failed|no_psk"
    exit 1
}

$failed = $false

# 1. Registry value for L2TP/IPsec behind NAT (home routers).
$regBefore = Get-RegValue
$rebootNeeded = $false
if ($regBefore -ne 2) {
    if (Would "Set $RegPath\$RegName = 2 (was $(if ($null -eq $regBefore) { 'not set' } else { $regBefore }))") {
        try {
            New-ItemProperty -Path $RegPath -Name $RegName -PropertyType DWord -Value 2 -Force -ErrorAction Stop | Out-Null
            $rebootNeeded = $true
        } catch { L "ERROR setting registry value: $($_.Exception.Message)"; $failed = $true }
    } else { $rebootNeeded = $true }
} else { L "Registry value $RegName already 2." }

# 2. The connection itself. Remove and recreate so settings are exact.
$existing = Get-Conn
if ($existing) {
    if (Would "Replace existing VPN connection '$Name' (all users)") {
        try { Remove-VpnConnection -Name $Name -AllUserConnection -Force -ErrorAction Stop }
        catch { L "ERROR removing old connection: $($_.Exception.Message)"; $failed = $true }
    }
}

if (Would "Create VPN connection '$Name' -> $Server, L2TP/IPsec with pre-shared key, MS-CHAP v2, all traffic through tunnel, remember credential, all users") {
    try {
        Add-VpnConnection -Name $Name -ServerAddress $Server -TunnelType L2tp -L2tpPsk $Psk `
            -AuthenticationMethod MSChapv2 -EncryptionLevel Required -RememberCredential `
            -SplitTunneling:$false -AllUserConnection -Force -ErrorAction Stop
    } catch { L "ERROR creating connection: $($_.Exception.Message)"; $failed = $true }
}

# 3. Pin IPsec to what the FortiGate offers.
if ($Pin -and -not $failed) {
    if (Would "Pin IPsec: phase1 AES256/SHA256/DH14, phase2 AES256/SHA256 no PFS") {
        try {
            Set-VpnConnectionIPsecConfiguration -ConnectionName $Name -AllUserConnection `
                -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 -DHGroup Group14 `
                -CipherTransformConstants AES256 -AuthenticationTransformConstants SHA256128 `
                -PfsGroup None -Force -ErrorAction Stop
        } catch {
            L "WARN could not pin IPsec, Windows defaults left in place: $($_.Exception.Message)"
        }
    }
}

# 4. Desktop shortcut that opens the Windows dial dialog.
if (Would "Create shortcut $Shortcut") {
    try {
        $w = New-Object -ComObject WScript.Shell
        $s = $w.CreateShortcut($Shortcut)
        $s.TargetPath   = "$env:SystemRoot\System32\rasphone.exe"
        $s.Arguments    = "-d `"$Name`""
        $s.Description  = "Connect to $Name"
        $s.IconLocation = "$env:SystemRoot\System32\netshell.dll,0"
        $s.Save()
    } catch { L "WARN could not create shortcut: $($_.Exception.Message)" }
}

Write-Host ""
Report
if ($failed) {
    Write-Host "RESULT|$Computer|install|failed"
    exit 1
}
if ($rebootNeeded -and -not $WhatIf) {
    L "Restart the PC once before the first connection so Windows picks up the registry value."
}
Write-Host "RESULT|$Computer|install|ok|reboot_needed=$(if ($rebootNeeded) { 'yes' } else { 'no' })"
exit 0
