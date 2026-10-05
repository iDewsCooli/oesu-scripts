<#
OESU-PaperCutQueueTune.ps1  v1.0.0  (2026-10-05)
 
Purpose: tune the Windows print queues that a PaperCut Hive print computer (edge node)
uses for "Local queue delivery", following PaperCut's published recommendations:
  - Ports tab: turn off "SNMP Status Enabled" on the Standard TCP/IP port
  - Advanced tab: turn off "Enable advanced printing features" (sets RAW_ONLY)
Built for OHS-HIVE2 (Oxbow), where Chromebook and web jobs delivered through these
queues waited minutes per job.
 
Modes (Mode, from -Mode or $env:Mode):
  Audit     Read only. Reports each target queue: driver and driver type, port type,
            port address versus the copier address PaperCut uses, SNMP, advanced
            printing features, jobs waiting, spooler and PaperCut service state,
            and recent PaperCut edge node log errors. Changes nothing.
  Apply     Backs up the registry keys it touches, turns SNMP off on each target
            Standard TCP/IP port, turns advanced printing features off on each
            target queue, then restarts the Print Spooler. Dry run unless WhatIf is
            exactly "false". Refuses to restart the spooler while target queues hold
            jobs, unless Force is "true".
  Rollback  Re-imports the most recent backup and restarts the spooler.
            Dry run unless WhatIf is exactly "false".
 
Inputs (parameters or environment variables, so it runs by hand or from the
Datto "OESU - Run Script" launcher):
  Mode         Audit | Apply | Rollback            (default Audit)
  WhatIf       anything except "false" = dry run   (default true)
  Printers     comma separated queue names         (default the four OHS copiers)
  ExpectedIPs  comma separated name=ip pairs used only for the Audit address check
  Force        "true" to restart the spooler even with jobs waiting
Exit code 0 = success, 1 = a check failed or a change failed.
Nothing here deletes files, removes queues, or prints document names.
#>
[CmdletBinding()]
param(
  [string]$Mode = $(if ($env:Mode) { $env:Mode } else { 'Audit' }),
  [string]$WhatIf = $(if ($env:WhatIf) { $env:WhatIf } else { 'true' }),
  [string]$Printers = $(if ($env:Printers) { $env:Printers } else { 'OHS B-Wing,OHS Staff Room,OHS Library,OHS Front Office' }),
  [string]$ExpectedIPs = $(if ($env:ExpectedIPs) { $env:ExpectedIPs } else { 'OHS B-Wing=192.168.16.193,OHS Staff Room=192.168.16.199,OHS Library=192.168.16.200,OHS Front Office=192.168.16.170' }),
  [string]$Force = $(if ($env:Force) { $env:Force } else { 'false' })
)
 
$ErrorActionPreference = 'Stop'
$Version   = '1.0.0'
$DryRun    = ($WhatIf.Trim().ToLower() -ne 'false')
$ForceRestart = ($Force.Trim().ToLower() -eq 'true')
$Targets   = @($Printers.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Expected  = @{}
foreach ($pair in $ExpectedIPs.Split(',')) { $kv = $pair.Split('='); if ($kv.Count -eq 2) { $Expected[$kv[0].Trim()] = $kv[1].Trim() } }
$WorkDir   = 'C:\ProgramData\OESU\PaperCutQueueTune'
$PrintersKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers'
$PortsKey    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports'
$RAW_ONLY  = 0x1000
$script:Failed = $false
 
function Say([string]$tag, [string]$msg) { Write-Output ("{0,-6} {1}" -f $tag, $msg) }
function Fail([string]$msg) { $script:Failed = $true; Say 'FAIL' $msg }
 
Say 'INFO' ("OESU-PaperCutQueueTune v{0} on {1}, Mode={2}, DryRun={3}, Targets={4}" -f $Version, $env:COMPUTERNAME, $Mode, $DryRun, ($Targets -join '; '))
 
function Get-QueueInfo([string]$name) {
  $p = Get-Printer -Name $name -ErrorAction SilentlyContinue
  if (-not $p) { return $null }
  $drv = Get-PrinterDriver -Name $p.DriverName -ErrorAction SilentlyContinue
  $port = Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue
  $regPrinter = "$PrintersKey\$name"
  $attr = $null; if (Test-Path $regPrinter) { $attr = (Get-ItemProperty -Path $regPrinter -Name Attributes -ErrorAction SilentlyContinue).Attributes }
  $regPort = "$PortsKey\$($p.PortName)"
  $isStdTcp = Test-Path $regPort
  $snmp = $null; $proto = $null; $portNum = $null; $addr = $null
  if ($isStdTcp) {
    $pp = Get-ItemProperty -Path $regPort -ErrorAction SilentlyContinue
    $snmp = $pp.'SNMP Enabled'; $proto = $pp.Protocol; $portNum = $pp.PortNumber
    $addr = if ($pp.IPAddress) { $pp.IPAddress } else { $pp.HostName }
  } elseif ($port) { $addr = $port.PrinterHostAddress }
  $jobs = @(Get-PrintJob -PrinterName $name -ErrorAction SilentlyContinue)
  $oldest = $null; if ($jobs.Count) { $oldest = ($jobs | Sort-Object SubmittedTime | Select-Object -First 1).SubmittedTime }
  [pscustomobject]@{
    Name = $name; Driver = $p.DriverName
    DriverType = $(if ($drv) { "v$($drv.MajorVersion)" } else { '?' })
    DriverVersion = $(if ($drv -and $drv.DriverVersion) { ([version]('{0}.{1}.{2}.{3}' -f (($drv.DriverVersion -shr 48) -band 0xffff), (($drv.DriverVersion -shr 32) -band 0xffff), (($drv.DriverVersion -shr 16) -band 0xffff), ($drv.DriverVersion -band 0xffff))).ToString() } else { '?' })
    PortName = $p.PortName; PortKind = $(if ($isStdTcp) { 'StandardTCPIP' } elseif ($p.PortName -like 'WSD*') { 'WSD' } else { 'Other' })
    Host = $addr; Protocol = $(switch ($proto) { 1 { 'RAW' } 2 { 'LPR' } default { $proto } }); PortNumber = $portNum
    SnmpEnabled = $snmp; Attributes = $attr
    AdvancedFeaturesOn = $(if ($attr -ne $null) { -not ($attr -band $RAW_ONLY) } else { $null })
    Datatype = $p.Datatype; Shared = $p.Shared; KeepPrintedJobs = $p.KeepPrintedJobs
    JobsWaiting = $jobs.Count; OldestJob = $oldest
    RegPrinter = $regPrinter; RegPort = $(if ($isStdTcp) { $regPort } else { $null })
  }
}
 
function Show-Audit {
  $spooler = Get-Service -Name Spooler
  Say 'INFO' ("Spooler: {0}, start type {1}" -f $spooler.Status, $spooler.StartType)
  Get-Service | Where-Object { $_.DisplayName -like '*PaperCut*' } | ForEach-Object { Say 'INFO' ("Service '{0}': {1}" -f $_.DisplayName, $_.Status) }
  foreach ($t in $Targets) {
    $q = Get-QueueInfo $t
    if (-not $q) { Fail "Queue '$t' not found on this computer"; continue }
    Say 'QUEUE' ("{0} | driver {1} ({2}, {3}) | port {4} [{5}] host {6} {7}:{8} | SNMP {9} | advanced features {10} | datatype {11} | jobs waiting {12}{13}" -f `
      $q.Name, $q.Driver, $q.DriverType, $q.DriverVersion, $q.PortName, $q.PortKind, $q.Host, $q.Protocol, $q.PortNumber, $q.SnmpEnabled, $q.AdvancedFeaturesOn, $q.Datatype, $q.JobsWaiting, $(if ($q.OldestJob) { ", oldest $($q.OldestJob)" } else { '' }))
    if ($Expected.ContainsKey($t) -and $q.Host -and ($q.Host -ne $Expected[$t])) { Fail ("{0}: port points at {1} but PaperCut has the copier at {2}" -f $t, $q.Host, $Expected[$t]) }
    if ($q.PortKind -eq 'WSD') { Say 'WARN' "$t uses a WSD port. PaperCut recommends a Standard TCP/IP port; this script does not convert it." }
    if ($q.DriverType -eq 'v4') { Say 'WARN' "$t uses a v4 (Type 4) driver. PaperCut recommends Type 3 for local queue delivery." }
    if ($q.SnmpEnabled -eq 1) { Say 'TODO' "$t : SNMP status is on (PaperCut recommends off)" }
    if ($q.AdvancedFeaturesOn -eq $true) { Say 'TODO' "$t : advanced printing features are on (PaperCut recommends off)" }
  }
  # Edge node log errors, last 7 days, error lines only, trimmed, no document names on purpose
  $roots = @("$env:ProgramFiles\PaperCut Hive", "${env:ProgramFiles(x86)}\PaperCut Hive", "$env:ProgramData\PaperCut Hive", "$env:ProgramData\PaperCut", "$env:ProgramFiles\PaperCut Pocket") | Where-Object { $_ -and (Test-Path $_) }
  $logs = @(); foreach ($r in $roots) { $logs += Get-ChildItem -Path $r -Recurse -Include *.log -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) } }
  Say 'INFO' ("PaperCut log files touched in the last 7 days: {0}" -f $logs.Count)
  foreach ($l in ($logs | Sort-Object LastWriteTime -Descending | Select-Object -First 6)) { Say 'LOG' ("{0} ({1:N0} KB, {2})" -f $l.FullName, ($l.Length / 1KB), $l.LastWriteTime) }
  $pattern = '(?i)(timeout|timed out|failed|error|refused|unreachable|retry)'
  $hits = @(); foreach ($l in $logs) { $hits += Select-String -Path $l.FullName -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -Last 400 }
  Say 'INFO' ("Error-like log lines in the last 7 days: {0}" -f $hits.Count)
  $hits | Select-Object -Last 25 | ForEach-Object { $line = $_.Line; if ($line.Length -gt 220) { $line = $line.Substring(0,220) + '...' }; Say 'LOGERR' $line }
}
 
function Invoke-Apply {
  $infos = @(); foreach ($t in $Targets) { $q = Get-QueueInfo $t; if (-not $q) { Fail "Queue '$t' not found; nothing changed for it" } else { $infos += $q } }
  if (-not $infos.Count) { Fail 'No target queues found'; return }
  $waiting = ($infos | Measure-Object -Property JobsWaiting -Sum).Sum
  $plan = @()
  foreach ($q in $infos) {
    if ($q.RegPort -and $q.SnmpEnabled -ne 0) { $plan += [pscustomobject]@{ Kind='SNMP'; Q=$q } }
    if ($q.Attributes -ne $null -and -not ($q.Attributes -band $RAW_ONLY)) { $plan += [pscustomobject]@{ Kind='RAWONLY'; Q=$q } }
    if (-not $q.RegPort) { Say 'SKIP' "$($q.Name): port is not Standard TCP/IP ($($q.PortKind)); SNMP setting left alone" }
  }
  if (-not $plan.Count) { Say 'OK' 'Nothing to change: every target queue already matches the recommendations.'; return }
  foreach ($c in $plan) {
    if ($c.Kind -eq 'SNMP') { Say 'PLAN' ("{0}: set SNMP Enabled 0 on port {1} (was {2})" -f $c.Q.Name, $c.Q.PortName, $c.Q.SnmpEnabled) }
    else { Say 'PLAN' ("{0}: set Attributes {1} -> {2} (advanced printing features off)" -f $c.Q.Name, $c.Q.Attributes, ($c.Q.Attributes -bor $RAW_ONLY)) }
  }
  Say 'PLAN' 'Then restart the Print Spooler so the changes take effect.'
  if ($waiting -gt 0 -and -not $ForceRestart) { Fail ("{0} job(s) are waiting in the target queues. Not changing anything. Rerun after they clear, or with Force=true." -f $waiting); return }
  if ($DryRun) { Say 'DRYRUN' 'WhatIf is not "false", so nothing was changed.'; return }
 
  New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bdir = Join-Path $WorkDir "backup-$stamp"; New-Item -ItemType Directory -Path $bdir -Force | Out-Null
  $i = 0
  foreach ($q in $infos) {
    $i++
    & reg.exe export ($q.RegPrinter -replace '^HKLM:\\','HKLM\') (Join-Path $bdir ("printer{0}.reg" -f $i)) /y | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "Backup of $($q.RegPrinter) failed; stopping before any change"; return }
    if ($q.RegPort) {
      & reg.exe export ($q.RegPort -replace '^HKLM:\\','HKLM\') (Join-Path $bdir ("port{0}.reg" -f $i)) /y | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail "Backup of $($q.RegPort) failed; stopping before any change"; return }
    }
  }
  Say 'OK' "Backup written to $bdir"
  foreach ($c in $plan) {
    try {
      if ($c.Kind -eq 'SNMP') { Set-ItemProperty -Path $c.Q.RegPort -Name 'SNMP Enabled' -Value 0 -Type DWord; Say 'DONE' "$($c.Q.Name): SNMP off" }
      else { Set-ItemProperty -Path $c.Q.RegPrinter -Name 'Attributes' -Value ($c.Q.Attributes -bor $RAW_ONLY) -Type DWord; Say 'DONE' "$($c.Q.Name): advanced printing features off" }
    } catch { Fail ("{0}: {1}" -f $c.Q.Name, $_.Exception.Message) }
  }
  Restart-Spooler
  foreach ($t in $Targets) { $q = Get-QueueInfo $t; if ($q) { Say 'AFTER' ("{0}: SNMP {1}, advanced features {2}" -f $q.Name, $q.SnmpEnabled, $q.AdvancedFeaturesOn) } }
}
 
function Restart-Spooler {
  try {
    Restart-Service -Name Spooler -Force
    Start-Sleep -Seconds 5
    $s = Get-Service -Name Spooler
    if ($s.Status -ne 'Running') { Start-Service -Name Spooler; Start-Sleep -Seconds 3; $s = Get-Service -Name Spooler }
    if ($s.Status -eq 'Running') { Say 'DONE' 'Print Spooler restarted and running' } else { Fail "Print Spooler is $($s.Status) after restart" }
  } catch { Fail ("Spooler restart: {0}" -f $_.Exception.Message) }
}
 
function Invoke-Rollback {
  if (-not (Test-Path $WorkDir)) { Fail "No backups found in $WorkDir"; return }
  $b = Get-ChildItem -Path $WorkDir -Directory -Filter 'backup-*' | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $b) { Fail "No backups found in $WorkDir"; return }
  $files = @(Get-ChildItem -Path $b.FullName -Filter *.reg)
  Say 'PLAN' ("Re-import {0} registry file(s) from {1}, then restart the Print Spooler" -f $files.Count, $b.FullName)
  if ($DryRun) { Say 'DRYRUN' 'WhatIf is not "false", so nothing was changed.'; return }
  foreach ($f in $files) { & reg.exe import $f.FullName 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Fail "Import failed: $($f.Name)" } else { Say 'DONE' "Imported $($f.Name)" } }
  Restart-Spooler
}
 
try {
  switch ($Mode.Trim().ToLower()) {
    'audit'    { Show-Audit }
    'apply'    { Show-Audit; Invoke-Apply }
    'rollback' { Invoke-Rollback }
    default    { Fail "Unknown Mode '$Mode'. Use Audit, Apply or Rollback." }
  }
} catch { Fail ("Unhandled: {0}" -f $_.Exception.Message) }
 
if ($script:Failed) { Say 'RESULT' 'FAILED (see FAIL lines)'; exit 1 } else { Say 'RESULT' 'OK'; exit 0 }
 