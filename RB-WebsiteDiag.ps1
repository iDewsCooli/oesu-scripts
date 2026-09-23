# RB-WebsiteDiag.ps1
# Read-only diagnostic: why can Riverbend machines not reach rbctc.org from inside the building?
# Makes no changes. Prints everything to stdout for the Datto job log.

$ErrorActionPreference = 'Continue'
$hosts = @('rbctc.org','www.rbctc.org','oesuorg.finalsite.com','oesu.org','www.oesu.org','google.com')
$publicResolvers = @('8.8.8.8','1.1.1.1')

function Section($t) { Write-Output ""; Write-Output "===== $t ====="; }

Section "HOST"
Write-Output ("Computer: {0}   User: {1}   Time: {2}" -f $env:COMPUTERNAME, $env:USERNAME, (Get-Date).ToString('s'))
try { Write-Output ("Domain: {0}" -f (Get-CimInstance Win32_ComputerSystem).Domain) } catch {}

Section "IP CONFIG (DNS servers, suffixes)"
try {
  Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
    Write-Output ("Adapter: {0}  IPv4: {1}  GW: {2}" -f $_.InterfaceAlias, ($_.IPv4Address.IPAddress -join ','), ($_.IPv4DefaultGateway.NextHop -join ','))
    Write-Output ("  DNS servers: {0}" -f ($_.DNSServer | Where-Object AddressFamily -eq 2 | ForEach-Object { $_.ServerAddresses } | ForEach-Object { $_ }) -join ',')
  }
} catch { Write-Output "Get-NetIPConfiguration failed: $_" }
try {
  $g = Get-DnsClientGlobalSetting
  Write-Output ("Suffix search list: {0}" -f ($g.SuffixSearchList -join ','))
} catch {}
try {
  Get-DnsClient | Where-Object { $_.ConnectionSpecificSuffix } | ForEach-Object { Write-Output ("  {0}: connection suffix {1}" -f $_.InterfaceAlias, $_.ConnectionSpecificSuffix) }
} catch {}
$dnsServers = @()
try { $dnsServers = (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses }) | Select-Object -Unique } catch {}
Write-Output ("Configured DNS servers (unique): {0}" -f ($dnsServers -join ','))

Section "HOSTS FILE (non-comment lines)"
try {
  Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object { Write-Output "  $_" }
} catch { Write-Output "hosts read failed: $_" }

Section "PROXY SETTINGS"
try { netsh winhttp show proxy 2>&1 | ForEach-Object { Write-Output "  $_" } } catch {}
try {
  $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  Write-Output ("  User ProxyEnable={0} ProxyServer={1} AutoConfigURL={2}" -f $reg.ProxyEnable, $reg.ProxyServer, $reg.AutoConfigURL)
} catch {}

Section "DNS CLIENT CACHE entries for rbctc"
try { Get-DnsClientCache | Where-Object { $_.Entry -like '*rbctc*' -or $_.Entry -like '*finalsite*' } | ForEach-Object { Write-Output ("  {0} -> {1} ({2}, ttl {3})" -f $_.Entry, $_.Data, $_.Type, $_.TimeToLive) } } catch {}

Section "RESOLUTION via default resolver"
foreach ($h in $hosts) {
  try {
    $r = Resolve-DnsName -Name $h -DnsOnly -ErrorAction Stop
    $r | ForEach-Object { Write-Output ("  {0,-28} {1,-6} {2}" -f $_.Name, $_.Type, ($(if ($_.IPAddress) { $_.IPAddress } elseif ($_.NameHost) { $_.NameHost } else { $_.PrimaryServer }))) }
  } catch { Write-Output ("  {0,-28} FAILED: {1}" -f $h, $_.Exception.Message) }
}

Section "IS THE LOCAL DNS SERVER AUTHORITATIVE FOR rbctc.org? (SOA/NS per configured server)"
foreach ($s in $dnsServers) {
  foreach ($t in 'SOA','NS') {
    try {
      $r = Resolve-DnsName -Name rbctc.org -Type $t -Server $s -DnsOnly -ErrorAction Stop
      $r | ForEach-Object { Write-Output ("  [{0}] {1,-10} {2,-4} {3}" -f $s, $_.Name, $_.Type, ($(if ($_.PrimaryServer) { $_.PrimaryServer + ' (admin ' + $_.NameAdministrator + ')' } elseif ($_.NameHost) { $_.NameHost } else { $_.IPAddress }))) }
    } catch { Write-Output ("  [{0}] {1} FAILED: {2}" -f $s, $t, $_.Exception.Message) }
  }
  try {
    $r = Resolve-DnsName -Name rbctc.org -Type A -Server $s -DnsOnly -ErrorAction Stop
    $r | ForEach-Object { Write-Output ("  [{0}] A rbctc.org -> {1}" -f $s, $_.IPAddress) }
    $r = Resolve-DnsName -Name www.rbctc.org -Server $s -DnsOnly -ErrorAction Stop
    $r | ForEach-Object { Write-Output ("  [{0}] www.rbctc.org {1} -> {2}" -f $s, $_.Type, ($(if ($_.IPAddress) { $_.IPAddress } else { $_.NameHost }))) }
  } catch { Write-Output ("  [{0}] A lookup FAILED: {1}" -f $s, $_.Exception.Message) }
}

Section "RESOLUTION via public resolvers (tests whether the firewall allows outbound DNS)"
foreach ($s in $publicResolvers) {
  foreach ($h in 'rbctc.org','www.rbctc.org') {
    try {
      $r = Resolve-DnsName -Name $h -Server $s -DnsOnly -ErrorAction Stop
      $r | ForEach-Object { Write-Output ("  [{0}] {1,-16} {2,-6} {3}" -f $s, $_.Name, $_.Type, ($(if ($_.IPAddress) { $_.IPAddress } else { $_.NameHost }))) }
    } catch { Write-Output ("  [{0}] {1} FAILED: {2}" -f $s, $h, $_.Exception.Message) }
  }
}

Section "IF THIS MACHINE RUNS THE DNS SERVER ROLE: zones and forwarders"
if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
  try {
    Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated } | ForEach-Object { Write-Output ("  Zone: {0,-30} type={1} dsIntegrated={2} reverse={3}" -f $_.ZoneName, $_.ZoneType, $_.IsDsIntegrated, $_.IsReverseLookupZone) }
    $z = Get-DnsServerZone -Name rbctc.org -ErrorAction SilentlyContinue
    if ($z) {
      Write-Output "  >>> LOCAL ZONE rbctc.org EXISTS. Records:"
      Get-DnsServerResourceRecord -ZoneName rbctc.org | ForEach-Object {
        $d = $_.RecordData
        $val = if ($d.IPv4Address) { $d.IPv4Address } elseif ($d.HostNameAlias) { $d.HostNameAlias } elseif ($d.NameServer) { $d.NameServer } elseif ($d.PrimaryServer) { $d.PrimaryServer } else { ($d | Out-String).Trim() }
        Write-Output ("     {0,-20} {1,-6} {2}" -f $_.HostName, $_.RecordType, $val)
      }
    } else { Write-Output "  No local zone named rbctc.org" }
    $f = Get-DnsServerForwarder
    Write-Output ("  Forwarders: {0}   UseRootHint={1}  Timeout={2}" -f ($f.IPAddress.IPAddressToString -join ','), $f.UseRootHint, $f.Timeout)
    Get-DnsServerZone | Where-Object { $_.ZoneType -eq 'Forwarder' } | ForEach-Object { Write-Output ("  Conditional forwarder: {0} -> {1}" -f $_.ZoneName, ($_.MasterServers.IPAddressToString -join ',')) }
    try {
      $rs = Get-DnsServerResponseRateLimiting -ErrorAction SilentlyContinue
      if ($rs) { Write-Output ("  RRL mode: {0}" -f $rs.Mode) }
    } catch {}
    try {
      $pol = Get-DnsServerQueryResolutionPolicy -ErrorAction SilentlyContinue
      if ($pol) { $pol | ForEach-Object { Write-Output ("  Query policy: {0} action={1} enabled={2} criteria={3}" -f $_.Name, $_.Action, $_.IsEnabled, (($_.Criteria | ForEach-Object { $_.CriteriaType + ':' + $_.Criteria }) -join ' | ')) } }
    } catch {}
  } catch { Write-Output "  DNS server query failed: $_" }
} else { Write-Output "  (DNS Server role / module not present on this machine)" }

Section "TCP REACHABILITY"
foreach ($target in @(@{h='104.17.67.73';p=443},@{h='104.17.67.73';p=80},@{h='rbctc.org';p=443},@{h='www.rbctc.org';p=443},@{h='oesuorg.finalsite.com';p=443})) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($target.h, $target.p, $null, $null)
    $ok = $ar.AsyncWaitHandle.WaitOne(5000, $false)
    if ($ok -and $c.Connected) { Write-Output ("  {0}:{1}  OPEN (remote {2})" -f $target.h, $target.p, $c.Client.RemoteEndPoint) } else { Write-Output ("  {0}:{1}  TIMEOUT/CLOSED" -f $target.h, $target.p) }
    $c.Close()
  } catch { Write-Output ("  {0}:{1}  ERROR {2}" -f $target.h, $target.p, $_.Exception.Message) }
}

Section "TLS CERTIFICATE PRESENTED (who is actually answering on 443?)"
function Get-Cert($name, $ip) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect($ip, 443)
    $ssl = New-Object System.Net.Security.SslStream($c.GetStream(), $false, ({ $true }))
    $ssl.AuthenticateAsClient($name)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    Write-Output ("  SNI={0} via {1}" -f $name, $ip)
    Write-Output ("     Subject : {0}" -f $cert.Subject)
    Write-Output ("     Issuer  : {0}" -f $cert.Issuer)
    Write-Output ("     Valid   : {0} to {1}   EXPIRED={2}" -f $cert.NotBefore.ToString('yyyy-MM-dd'), $cert.NotAfter.ToString('yyyy-MM-dd'), ($cert.NotAfter -lt (Get-Date)))
    $san = ($cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Subject Alternative Name' }).Format($false)
    if ($san) { Write-Output ("     SAN     : {0}" -f ($san.Substring(0, [Math]::Min(300, $san.Length)))) }
    $ssl.Close(); $c.Close()
  } catch { Write-Output ("  SNI={0} via {1}  FAILED: {2}" -f $name, $ip, $_.Exception.Message) }
}
$resolved = $null
try { $resolved = (Resolve-DnsName rbctc.org -Type A -DnsOnly -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1).IPAddress } catch {}
if ($resolved) { Get-Cert 'rbctc.org' $resolved }
if ($resolved -ne '104.17.67.73') { Get-Cert 'rbctc.org' '104.17.67.73' }
Get-Cert 'www.rbctc.org' '104.17.67.73'
Get-Cert 'oesuorg.finalsite.com' 'oesuorg.finalsite.com'

Section "WHO ON THE LAN OR THE WAN IP ANSWERS FOR rbctc.org ON 443? (finding the box holding the expired 2023 certificate)"
$gw = $null
try { $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch {}
$probeIps = @('192.168.5.3','192.168.5.19','192.168.5.21','192.168.5.5','64.223.220.126')
if ($gw) { $probeIps = @($gw) + $probeIps }
foreach ($ip in ($probeIps | Select-Object -Unique)) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($ip, 443, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(3000, $false) -and $c.Connected) { $c.Close(); Get-Cert 'rbctc.org' $ip } else { $c.Close(); Write-Output ("  {0}:443 not open" -f $ip) }
  } catch { Write-Output ("  {0}:443 not open ({1})" -f $ip, $_.Exception.Message) }
}

Section "THIS MACHINE: anything listening on 80/443 and the cert it serves"
try {
  Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -in 80,443,8443 } | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    Write-Output ("  {0}:{1}  pid {2} {3}" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $p.ProcessName)
  }
  if (Get-NetTCPConnection -State Listen -LocalPort 443 -ErrorAction SilentlyContinue) { Get-Cert 'rbctc.org' '127.0.0.1' }
} catch {}
try {
  Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like '*rbctc*' -or $_.DnsNameList -like '*rbctc*' } | ForEach-Object { Write-Output ("  Local cert store: {0}  issuer {1}  expires {2}" -f $_.Subject, $_.Issuer, $_.NotAfter.ToString('yyyy-MM-dd')) }
} catch {}

Section "HTTP FETCH (curl, certificate check off, 15s cap)"
foreach ($u in 'https://rbctc.org/','https://www.rbctc.org/','http://rbctc.org/','https://www.oesu.org/') {
  Write-Output "  --- $u"
  try { & curl.exe -k -s -S -o NUL -w "  http_code=%{http_code} remote=%{remote_ip} redirect=%{redirect_url} time=%{time_total}s\n" --max-time 15 $u 2>&1 | ForEach-Object { Write-Output "  $_" } } catch { Write-Output "  curl failed: $_" }
}
Write-Output "  --- response headers https://rbctc.org/"
try { & curl.exe -k -s -S -I --max-time 15 https://rbctc.org/ 2>&1 | Select-Object -First 15 | ForEach-Object { Write-Output "  $_" } } catch {}

Section "ROUTE TO 104.17.67.73 (first 6 hops)"
try { tracert -d -h 6 -w 800 104.17.67.73 2>&1 | ForEach-Object { Write-Output "  $_" } } catch {}

Section "DONE"
exit 0
