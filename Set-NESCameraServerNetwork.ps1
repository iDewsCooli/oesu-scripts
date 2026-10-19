#Requires -Version 5.1
<#
.SYNOPSIS
  Newbury exacqVision server (ER2205021434): pin its phone network address and let the camera portal pull RTSP.
  Version 1.0.0, October 19, 2026.

.DESCRIPTION
  Modes (environment variable Mode, as passed by the Datto "OESU - Run Script" launcher):

    Report   Default. Read only. Lists every network adapter (address, mask, gateway, DNS, DHCP state and lease),
             the routing table, which ports the exacq services listen on, Windows Firewall state and any rule
             already covering the RTSP port. Changes nothing.
    Apply    Needs WhatIf=false. On the adapter with TargetMac only:
               1. Adds an inbound Windows Firewall rule: TCP RtspPort from PortalIP only (all profiles).
               2. Turns the DHCP address it has right now into the same address set by hand (same mask, gateway
                  and DNS), so it can no longer change. Then tests the gateway, DNS and Datto's servers. If any test
                  fails it puts DHCP back within seconds. A safety task also puts DHCP back after 10 minutes unless
                  the script confirmed success, in case the script is cut off midway.
               3. If the camera side adapter also has a default gateway, adds a persistent route so replies to
                  the Central Office go out the phone network side.
    Undo     Needs WhatIf=false. Removes the firewall rule and the route, and returns the adapter to DHCP.

  Params JSON keys (all optional): TargetMac (default 70-85-C2-E6-7F-79), PortalIP (192.168.48.12),
  PortalNet (192.168.48.0/24), RtspPort (8554), ExpectNet (10.2.8.0/22).

.NOTES
  The camera network adapter (192.168.10.x) is never changed. Recording does not stop; only the phone network side
  blips for a second or two while the address is re-applied.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Ver = '1.0.0'

function Pick([string]$name, [string]$default) { $v = [Environment]::GetEnvironmentVariable($name); if ($v) { return $v.Trim() } return $default }
$Mode      = Pick 'Mode' 'Report'
$WhatIfRaw = Pick 'WhatIf' 'true'
$TargetMac = (Pick 'TargetMac' '70-85-C2-E6-7F-79').ToUpper().Replace(':', '-')
$PortalIP  = Pick 'PortalIP' '192.168.48.12'
$PortalNet = Pick 'PortalNet' '192.168.48.0/24'
$RtspPort  = [int](Pick 'RtspPort' '8554')
$ExpectNet = Pick 'ExpectNet' '10.2.8.0/22'
$DryRun    = ($WhatIfRaw.ToLower() -ne 'false')

$Sys32   = Join-Path $env:SystemRoot 'System32'
$Ipconfig = Join-Path $Sys32 'ipconfig.exe'
$RuleName = 'OESU Camera Portal RTSP from OESU2019'
$WorkDir  = 'C:\OESU\nes-camera-net'
$TaskName = 'OESU-NES-CameraNet-Revert'
$StateFile = Join-Path $WorkDir 'state.json'
$OkFlag    = Join-Path $WorkDir 'confirmed.flag'

function Say([string]$t) { Write-Output $t }
function Head([string]$t) { Write-Output ''; Write-Output ('== ' + $t) }

function Test-InNet([string]$ip, [string]$cidr) {
  $p = $cidr.Split('/'); $bits = [int]$p[1]
  $a = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); $n = ([Net.IPAddress]::Parse($p[0])).GetAddressBytes()
  [Array]::Reverse($a); [Array]::Reverse($n)
  $ai = [BitConverter]::ToUInt32($a, 0); $ni = [BitConverter]::ToUInt32($n, 0)
  $mask = if ($bits -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $bits)) }
  return (($ai -band $mask) -eq ($ni -band $mask))
}

function Get-AdapterInfo {
  foreach ($a in (Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object ifIndex)) {
    $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $addr = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
    $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
    $dns = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $prof = (Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).NetworkCategory
    $wmi = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter ("InterfaceIndex=" + $a.ifIndex) -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Index = $a.ifIndex; Name = $a.Name; Description = $a.InterfaceDescription; Mac = $a.MacAddress; Status = $a.Status
      LinkSpeed = $a.LinkSpeed; Dhcp = $(if ($ipif) { [string]$ipif.Dhcp } else { '' })
      IP = $(if ($addr) { $addr.IPAddress } else { '' }); Prefix = $(if ($addr) { $addr.PrefixLength } else { 0 })
      Gateway = $gw; Dns = @($dns); Profile = [string]$prof
      DhcpServer = $(if ($wmi) { $wmi.DHCPServer } else { '' })
      LeaseObtained = $(if ($wmi -and $wmi.DHCPLeaseObtained) { $wmi.DHCPLeaseObtained.ToString('s') } else { '' })
      LeaseExpires = $(if ($wmi -and $wmi.DHCPLeaseExpires) { $wmi.DHCPLeaseExpires.ToString('s') } else { '' })
      Metric = $(if ($ipif) { $ipif.InterfaceMetric } else { 0 })
    }
  }
}

function Show-Report {
  Head 'Adapters'
  foreach ($i in (Get-AdapterInfo)) {
    Say ('  [{0}] {1} ({2}) MAC {3} {4} {5}' -f $i.Index, $i.Name, $i.Description, $i.Mac, $i.Status, $i.LinkSpeed)
    Say ('      IPv4 {0}/{1}  gateway {2}  DNS {3}  DHCP {4}  profile {5}  metric {6}' -f $i.IP, $i.Prefix, $i.Gateway, ($i.Dns -join ','), $i.Dhcp, $i.Profile, $i.Metric)
    if ($i.Dhcp -eq 'Enabled') { Say ('      DHCP server {0}, lease {1} to {2}' -f $i.DhcpServer, $i.LeaseObtained, $i.LeaseExpires) }
    if ($i.Mac -eq $TargetMac) { Say '      ^ target adapter (phone network side)' }
  }
  Head 'IPv4 routes (default and Central Office)'
  Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -or $_.DestinationPrefix -eq $PortalNet } |
    Sort-Object RouteMetric | ForEach-Object { Say ('  {0} via {1} on ifIndex {2} metric {3} ({4})' -f $_.DestinationPrefix, $_.NextHop, $_.ifIndex, $_.RouteMetric, $_.Store) }
  Head ('Listening ports of interest (exacq client 22609, RTSP ' + $RtspPort + ', web 80/443)')
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 22609, $RtspPort, 80, 443 } | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    Say ('  {0}:{1} {2}' -f $_.LocalAddress, $_.LocalPort, $(if ($p) { $p.ProcessName } else { 'pid ' + $_.OwningProcess }))
  }
  Head 'Windows Firewall'
  Get-NetFirewallProfile | ForEach-Object { Say ('  {0}: enabled {1}, default inbound {2}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction) }
  $rules = Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -contains [string]$RtspPort } | Get-NetFirewallRule -ErrorAction SilentlyContinue
  if ($rules) { foreach ($r in $rules) { $af = $r | Get-NetFirewallAddressFilter; Say ('  rule for {0}: "{1}" {2} {3} from {4}' -f $RtspPort, $r.DisplayName, $r.Direction, $r.Action, ($af.RemoteAddress -join ',')) } }
  else { Say ('  no rule mentions TCP ' + $RtspPort) }
  $exq = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'exacq' -and $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' }
  foreach ($r in $exq) { $pf = $r | Get-NetFirewallPortFilter; $af = $r | Get-NetFirewallAddressFilter; Say ('  exacq rule "{0}" {1} ports {2} from {3}' -f $r.DisplayName, $r.Action, ($pf.LocalPort -join ','), ($af.RemoteAddress -join ',')) }
}

function Test-Path-Out([int]$ifIndex, [string]$gw) {
  $ok = $true
  $ping = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
  Say ('  gateway ' + $gw + ' answers ping: ' + $ping + ' (information only; the firewall may not answer ping on this network)')
  $dnsOk = $false
  try { $r = Resolve-DnsName -Name 'zinfandel.centrastage.net' -Type A -DnsOnly -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1; $dnsOk = [bool]$r } catch { }
  Say ('  DNS resolves the Datto platform: ' + $dnsOk); if (-not $dnsOk) { $ok = $false }
  $https = $false
  try { $c = New-Object Net.Sockets.TcpClient; $ar = $c.BeginConnect('zinfandel.centrastage.net', 443, $null, $null); if ($ar.AsyncWaitHandle.WaitOne(8000)) { $c.EndConnect($ar); $https = $true }; $c.Close() } catch { }
  Say ('  Datto platform answers on 443: ' + $https); if (-not $https) { $ok = $false }
  return $ok
}

function Restore-Dhcp([int]$ifIndex, [string]$name) {
  Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.Protocol -eq 'NetMgmt' } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -eq 'Manual' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue
  Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $Ipconfig /renew "$name" 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev }
}

function Register-RevertTask([int]$ifIndex) {
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  if (Test-Path $OkFlag) { Remove-Item $OkFlag -Force }
  $cmd = "if (-not (Test-Path '$OkFlag')) { Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' | Where-Object { `$_.Protocol -eq 'NetMgmt' } | Remove-NetRoute -Confirm:`$false; Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 | Where-Object { `$_.PrefixOrigin -eq 'Manual' } | Remove-NetIPAddress -Confirm:`$false; Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Enabled; Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ResetServerAddresses; & '$Ipconfig' /renew }; Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
  $action = New-ScheduledTaskAction -Execute (Join-Path $Sys32 'WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -Command "' + $cmd + '"')
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -TaskPath '\OESU\' -Action $action -Trigger $trigger -Principal $principal -Force `
    -Description 'Safety net for Set-NESCameraServerNetwork: returns the phone network adapter to DHCP unless the change was confirmed.' | Out-Null
}

try {
  Say ("Set-NESCameraServerNetwork {0}, mode {1}{2}, on {3} at {4}" -f $Ver, $Mode, $(if ($DryRun -and $Mode -ne 'Report') { ' (dry run)' } else { '' }), $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM-dd HH:mm'))
  if ($env:COMPUTERNAME -ne 'ER2205021434') { throw "This script is only for the Newbury exacq server ER2205021434, not $($env:COMPUTERNAME)." }
  Show-Report
  if ($Mode -eq 'Report') { Head 'Result'; Say 'Report only. Nothing was changed.'; exit 0 }

  $t = Get-AdapterInfo | Where-Object { $_.Mac -eq $TargetMac }
  if (-not $t) { throw "No adapter with MAC $TargetMac." }
  if ($t.Status -ne 'Up') { throw "Target adapter $($t.Name) is $($t.Status)." }

  if ($Mode -eq 'Undo') {
    Head 'Undo'
    if ($DryRun) { Say ('  would remove firewall rule "' + $RuleName + '", the ' + $PortalNet + ' route, and return ' + $t.Name + ' to DHCP'); exit 0 }
    Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetRoute -DestinationPrefix $PortalNet -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Restore-Dhcp $t.Index $t.Name
    Start-Sleep -Seconds 5
    Say '  done'; Show-Report; exit 0
  }

  if ($Mode -ne 'Apply') { throw "Unknown mode '$Mode'. Use Report, Apply or Undo." }

  Head 'Apply plan'
  if (-not $t.IP -or -not (Test-InNet $t.IP $ExpectNet)) { throw "Target adapter address '$($t.IP)' is not inside $ExpectNet. Stopping; check the Report first." }
  if (-not $t.Gateway) { throw 'Target adapter has no default gateway. Stopping.' }
  if (-not $t.Dns -or -not $t.Dns.Count) { throw 'Target adapter has no DNS servers. Stopping.' }
  $others = @(Get-AdapterInfo | Where-Object { $_.Mac -ne $TargetMac -and $_.Gateway })
  Say ('  1. firewall rule "' + $RuleName + '": inbound TCP ' + $RtspPort + ' from ' + $PortalIP + ' only, all profiles')
  Say ('  2. ' + $t.Name + ': ' + $(if ($t.Dhcp -eq 'Enabled') { 'DHCP ' + $t.IP + '/' + $t.Prefix + ' becomes fixed ' } else { 'already fixed at ' }) + $t.IP + '/' + $t.Prefix + ', gateway ' + $t.Gateway + ', DNS ' + ($t.Dns -join ','))
  Say ('  3. ' + $(if ($others.Count) { 'persistent route ' + $PortalNet + ' via ' + $t.Gateway + ' (another adapter also has a default gateway: ' + (($others | ForEach-Object { $_.Name + ' ' + $_.Gateway }) -join '; ') + ')' } else { 'no extra route needed (only this adapter has a default gateway)' }))
  if ($DryRun) { Head 'Result'; Say 'Dry run. Rerun with WhatIf=false to apply.'; exit 0 }

  Head 'Applying'
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  [IO.File]::WriteAllText($StateFile, ($t | ConvertTo-Json -Depth 3))
  Say ('  saved the current settings to ' + $StateFile)

  Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $RuleName -Group 'OESU Camera Portal' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $RtspPort `
    -RemoteAddress $PortalIP -Profile Any -Description 'Lets the OESU camera portal (OESU2019) pull RTSP from exacq. Added by Set-NESCameraServerNetwork.' | Out-Null
  Say '  1. firewall rule added'

  if ($t.Dhcp -eq 'Enabled') {
    Register-RevertTask $t.Index
    Say '  safety task registered (returns to DHCP in 10 minutes unless confirmed)'
    Get-NetRoute -InterfaceIndex $t.Index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceIndex $t.Index -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $t.Index -IPAddress $t.IP -PrefixLength $t.Prefix -DefaultGateway $t.Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $t.Index -ServerAddresses $t.Dns
    Start-Sleep -Seconds 4
    Say '  2. address set by hand, testing:'
    if (Test-Path-Out $t.Index $t.Gateway) {
      New-Item -ItemType File -Force -Path $OkFlag | Out-Null
      Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\OESU\' -Confirm:$false -ErrorAction SilentlyContinue
      Say '     tests passed, change kept, safety task removed'
    } else {
      Say '     a test failed: returning the adapter to DHCP now'
      Restore-Dhcp $t.Index $t.Name
      Start-Sleep -Seconds 6
      Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\OESU\' -Confirm:$false -ErrorAction SilentlyContinue
      throw 'Static address did not pass the tests; DHCP restored. The firewall rule was kept.'
    }
  } else { Say '  2. adapter already uses a fixed address, left as is' }

  if ($others.Count) {
    Get-NetRoute -DestinationPrefix $PortalNet -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    New-NetRoute -DestinationPrefix $PortalNet -InterfaceIndex $t.Index -NextHop $t.Gateway -PolicyStore PersistentStore | Out-Null
    Say ('  3. persistent route ' + $PortalNet + ' via ' + $t.Gateway + ' added')
  } else { Say '  3. no route change needed' }

  Head 'After'
  Show-Report
  Head 'Result'
  Say 'Done. Ask the Allworx administrator (Current Concepts) to reserve or exclude this address in the phone system''s address pool so nothing else is ever handed it.'
  exit 0
}
catch {
  Write-Output ('FAILED: ' + $_.Exception.Message)
  exit 1
}
