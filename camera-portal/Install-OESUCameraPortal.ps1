#Requires -Version 5.1
<#
.SYNOPSIS
  OESU Camera Portal on OESU2019: Apache (Apache Lounge build) for HTTPS, oauth2-proxy for Google sign-in,
  reachable from the Central Office LAN only. Version 1.0.0, October 5, 2026.

.DESCRIPTION
  Modes (parameter -Mode or environment variable Mode, as passed by the Datto "OESU - Run Script" launcher):

    Plan       Default. Read only on the system. Downloads Apache and oauth2-proxy into C:\OESU\CameraPortal\staging,
               prints their SHA-256 values, checks ports, firewall, DNS, VC++ runtime and outbound access, and lists
               every change Install would make. Nothing is installed or reconfigured.
    Install    Requires ApacheSha256 and OAuth2ProxySha256 equal to what Plan printed (plan, then confirm).
               Safe to rerun: it upgrades binaries and rewrites config, keeping the certificate and the secrets.
    SetSecret  Interactive only (at the server console or RDP, elevated PowerShell). Prompts for the Google
               OAuth client ID and secret. Secrets never travel through Datto, email or chat.
    Status     Read only health report.
    TrustCert  For a viewer's Windows PC (run there, not on the server): trusts the portal certificate passed in
               CertPem and, if AddHosts is true, maps the portal name to the server when DNS does not.
    Uninstall  Removes the service, task, firewall rule and (if RemoveDns is true) the DNS zone. Files are moved to
               C:\OESU\CameraPortal-removed-<date>, nothing is deleted.

  Under the Datto launcher, WhatIf anything other than "false" forces Plan.

.NOTES
  Design: browser -> Apache 192.168.48.12:443 (TLS, CO LAN only, security headers)
          -> oauth2-proxy 127.0.0.1:4180 (Google sign-in, allowed emails list)
          -> Apache 127.0.0.1:8088 (static portal page, logs who viewed)
  Apache runs as NT AUTHORITY\LocalService, never as SYSTEM, because this server is a domain controller.
#>
[CmdletBinding()]
param(
  [string]$Mode,
  [string]$Hostname,
  [string]$ServerIP,
  [string]$AllowedNet,
  [string]$AllowedEmails,
  [string]$ApacheZipUrl,
  [string]$ApacheSha256,
  [string]$OAuth2ProxyVersion,
  [string]$OAuth2ProxySha256,
  [string]$CreateDns,
  [string]$PublishTrustToDomain,
  [string]$RemoveDns,
  [string]$CertPem,
  [string]$AddHosts
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptVersion = '1.0.0'

function Pick([string]$a, [string]$envName, [string]$default) {
  if ($a) { return $a }
  $e = [Environment]::GetEnvironmentVariable($envName)
  if ($e) { return $e }
  return $default
}
function IsTrue([string]$v) { return ($v -and $v.Trim().ToLower() -in @('true', '1', 'yes', 'y')) }

$Mode              = Pick $Mode 'Mode' 'Plan'
$Hostname          = Pick $Hostname 'Hostname' 'cameras.oesu.org'
$ServerIP          = Pick $ServerIP 'ServerIP' ''
$AllowedNet        = Pick $AllowedNet 'AllowedNet' ''
$AllowedEmails     = Pick $AllowedEmails 'AllowedEmails' 'heather.lawler@oesu.org,jeff.jamele@oesu.org'
$ApacheZipUrl      = Pick $ApacheZipUrl 'ApacheZipUrl' ''
$ApacheSha256      = Pick $ApacheSha256 'ApacheSha256' ''
$OAuth2ProxyVersion = Pick $OAuth2ProxyVersion 'OAuth2ProxyVersion' 'v7.15.4'
$OAuth2ProxySha256 = Pick $OAuth2ProxySha256 'OAuth2ProxySha256' ''
$CreateDns         = IsTrue (Pick $CreateDns 'CreateDns' 'true')
$PublishTrust      = IsTrue (Pick $PublishTrustToDomain 'PublishTrustToDomain' 'false')
$RemoveDns         = IsTrue (Pick $RemoveDns 'RemoveDns' 'false')
$CertPem           = Pick $CertPem 'CertPem' ''
$AddHosts          = IsTrue (Pick $AddHosts 'AddHosts' 'false')

$recPath = 'C:\OESU\CameraPortal\install-record.json'
if (-not $PSBoundParameters.ContainsKey('Hostname') -and -not $env:Hostname -and (Test-Path $recPath)) {
  try { $h = (Get-Content -Raw $recPath | ConvertFrom-Json).host; if ($h) { $Hostname = $h } } catch { }
}
$Hostname = $Hostname.Trim().ToLower()
if ($Hostname -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { Write-Output "FAILED: bad Hostname '$Hostname'"; exit 1 }

$whatIfEnv = [Environment]::GetEnvironmentVariable('WhatIf')
if ($whatIfEnv -and $whatIfEnv.Trim().ToLower() -ne 'false' -and $Mode -in @('Install', 'Uninstall')) {
  Write-Output "WhatIf is '$whatIfEnv', so $Mode runs as Plan. Pass WhatIf=false to make changes."
  $Mode = 'Plan'
}

# Absolute paths: the Datto agent environment on OESU2019 has no System32 on PATH.
$Sys32   = Join-Path $env:SystemRoot 'System32'
$Icacls  = Join-Path $Sys32 'icacls.exe'
$ScExe   = Join-Path $Sys32 'sc.exe'
$TarExe  = Join-Path $Sys32 'tar.exe'
$Certutil = Join-Path $Sys32 'certutil.exe'

$Root      = 'C:\OESU\CameraPortal'
$RootFwd   = 'C:/OESU/CameraPortal'
$Staging   = Join-Path $Root 'staging'
$ApacheDir = Join-Path $Root 'apache\Apache24'
$ProxyDir  = Join-Path $Root 'oauth2-proxy'
$SiteDir   = Join-Path $Root 'site'
$ConfDir   = Join-Path $Root 'conf'
$SslDir    = Join-Path $ConfDir 'ssl'
$SecretDir = Join-Path $Root 'secrets'
$LogDir    = Join-Path $Root 'logs'
$PubDir    = Join-Path $Root 'public'
$Svc       = 'OESU-CameraPortal'
$TaskProxy = 'OESU-CameraPortal-oauth2-proxy'
$TaskClean = 'OESU-CameraPortal-LogCleanup'
$FwGroup   = 'OESU Camera Portal'
$UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) OESU-CameraPortal-Installer/' + $ScriptVersion

$SID_SYSTEM = '*S-1-5-18'
$SID_ADMINS = '*S-1-5-32-544'
$SID_LOCALSVC = '*S-1-5-19'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Portal page files, embedded by the build (base64 of the exact bytes).
$SiteFiles = [ordered]@{
  'index.html' = 'PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImVuIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPG1ldGEgbmFtZT0icm9ib3RzIiBjb250ZW50PSJub2luZGV4LCBub2ZvbGxvdyI+Cjx0aXRsZT5PRVNVIENhbWVyYSBQb3J0YWw8L3RpdGxlPgo8bGluayByZWw9InN0eWxlc2hlZXQiIGhyZWY9InBvcnRhbC5jc3MiPgo8c2NyaXB0IHNyYz0icG9ydGFsLmpzIiBkZWZlcj48L3NjcmlwdD4KPC9oZWFkPgo8Ym9keT4KPGhlYWRlciBjbGFzcz0idG9wIj4KICA8ZGl2IGNsYXNzPSJicmFuZCI+CiAgICA8c3BhbiBjbGFzcz0ibWFyayIgYXJpYS1oaWRkZW49InRydWUiPjwvc3Bhbj4KICAgIDxkaXY+CiAgICAgIDxoMT5PRVNVIENhbWVyYSBQb3J0YWw8L2gxPgogICAgICA8cCBjbGFzcz0ic3ViIj5PcmFuZ2UgRWFzdCBTdXBlcnZpc29yeSBVbmlvbiwgbGl2ZSBzYWZldHkgdmlld2luZzwvcD4KICAgIDwvZGl2PgogIDwvZGl2PgogIDxkaXYgY2xhc3M9IndobyI+CiAgICA8c3BhbiBpZD0id2hvIj5TaWduZWQgaW48L3NwYW4+CiAgICA8YSBjbGFzcz0iYnRuIGdob3N0IiBocmVmPSIvb2F1dGgyL3NpZ25fb3V0P3JkPSUyRiI+U2lnbiBvdXQ8L2E+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPG1haW4+CiAgPHNlY3Rpb24gY2xhc3M9Im5vdGljZSIgaWQ9Im5vdGljZSIgaGlkZGVuPjwvc2VjdGlvbj4KCiAgPHNlY3Rpb24gY2xhc3M9IndhbGwgY2FyZCIgYXJpYS1sYWJlbGxlZGJ5PSJ3YWxsLWgiPgogICAgPGRpdj4KICAgICAgPGgyIGlkPSJ3YWxsLWgiPkxpdmUgd2FsbDwvaDI+CiAgICAgIDxwIGlkPSJ3YWxsLXRleHQiPkV2ZXJ5IGJ1aWxkaW5nIG9uIG9uZSBzY3JlZW4uIFRoaXMgb3BlbnMgb25jZSB0aGUgY2FtZXJhIHJlbGF5IHBpbG90IGlzIHJ1bm5pbmcuPC9wPgogICAgPC9kaXY+CiAgICA8YSBjbGFzcz0iYnRuIHByaW1hcnkiIGlkPSJ3YWxsLWxpbmsiIGhyZWY9IiMiIGhpZGRlbiB0YXJnZXQ9Il9ibGFuayIgcmVsPSJub29wZW5lciI+T3BlbiB0aGUgbGl2ZSB3YWxsPC9hPgogIDwvc2VjdGlvbj4KCiAgPGgyIGNsYXNzPSJzZWN0aW9uLWgiPkJ1aWxkaW5nczwvaDI+CiAgPHAgY2xhc3M9ImhpbnQiPkVhY2ggY2FyZCBzYXlzIGhvdyB0byBzZWUgdGhhdCBidWlsZGluZyB0b2RheS4gUmVjb3JkZWQgZm9vdGFnZSwgcGxheWJhY2sgYW5kIGV4cG9ydHMgc3RheSBpbiBlYWNoIGJ1aWxkaW5nJ3Mgb3duIHN5c3RlbS48L3A+CiAgPHNlY3Rpb24gY2xhc3M9ImdyaWQiIGlkPSJidWlsZGluZ3MiIGFyaWEtbGl2ZT0icG9saXRlIj4KICAgIDxwIGNsYXNzPSJsb2FkaW5nIj5Mb2FkaW5nIGJ1aWxkaW5ncy4uLjwvcD4KICA8L3NlY3Rpb24+CgogIDxzZWN0aW9uIGNsYXNzPSJjYXJkIGhlbHAiIGFyaWEtbGFiZWxsZWRieT0iaGVscC1oIj4KICAgIDxoMiBpZD0iaGVscC1oIj5OZWVkIGZvb3RhZ2Ugb3IgaGVscD88L2gyPgogICAgPHVsIGlkPSJoZWxwLWxpc3QiPjwvdWw+CiAgPC9zZWN0aW9uPgoKICA8cCBjbGFzcz0iZmluZSIgaWQ9ImZpbmUiPjwvcD4KPC9tYWluPgo8L2JvZHk+CjwvaHRtbD4K'
  'portal.css' = 'OnJvb3QgewogIC0tYmc6ICNmNGY2Zjg7CiAgLS1wYW5lbDogI2ZmZmZmZjsKICAtLWluazogIzE3MjEyYjsKICAtLW11dGVkOiAjNWI2ODc2OwogIC0tbGluZTogI2Q5ZTBlNzsKICAtLWFjY2VudDogIzFmNWY5OTsKICAtLWFjY2VudC1pbms6ICNmZmZmZmY7CiAgLS1vazogIzFkN2E0NjsKICAtLW9rLWJnOiAjZTVmNGViOwogIC0td2FybjogIzhhNWEwMDsKICAtLXdhcm4tYmc6ICNmZGYxZDg7CiAgLS1vZmY6ICM2YjcyODA7CiAgLS1vZmYtYmc6ICNlY2VmZjI7CiAgLS1zaGFkb3c6IDAgMXB4IDJweCByZ2JhKDE2LCAyNCwgNDAsIDAuMDYpLCAwIDFweCAzcHggcmdiYSgxNiwgMjQsIDQwLCAwLjA4KTsKfQpAbWVkaWEgKHByZWZlcnMtY29sb3Itc2NoZW1lOiBkYXJrKSB7CiAgOnJvb3QgewogICAgLS1iZzogIzBmMTUxYjsKICAgIC0tcGFuZWw6ICMxODIxMmI7CiAgICAtLWluazogI2U3ZWRmMzsKICAgIC0tbXV0ZWQ6ICM5YWE4YjY7CiAgICAtLWxpbmU6ICMyYTM2NDM7CiAgICAtLWFjY2VudDogIzVhYTJlMDsKICAgIC0tYWNjZW50LWluazogIzBiMTIxODsKICAgIC0tb2s6ICM2ZmQzOWI7CiAgICAtLW9rLWJnOiAjMTczMzI1OwogICAgLS13YXJuOiAjZjFjNDZiOwogICAgLS13YXJuLWJnOiAjM2EyZTE0OwogICAgLS1vZmY6ICNhM2FkYjg7CiAgICAtLW9mZi1iZzogIzIzMmQzODsKICAgIC0tc2hhZG93OiBub25lOwogIH0KfQoqIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQpbaGlkZGVuXSB7IGRpc3BsYXk6IG5vbmUgIWltcG9ydGFudDsgfQpodG1sLCBib2R5IHsgbWFyZ2luOiAwOyBwYWRkaW5nOiAwOyB9CmJvZHkgewogIGJhY2tncm91bmQ6IHZhcigtLWJnKTsKICBjb2xvcjogdmFyKC0taW5rKTsKICBmb250OiAxNnB4LzEuNSAiU2Vnb2UgVUkiLCBzeXN0ZW0tdWksIC1hcHBsZS1zeXN0ZW0sIFJvYm90bywgQXJpYWwsIHNhbnMtc2VyaWY7Cn0KLnRvcCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBnYXA6IDE2cHg7CiAgcGFkZGluZzogMTZweCAyNHB4OyBiYWNrZ3JvdW5kOiB2YXIoLS1wYW5lbCk7IGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1saW5lKTsKICBmbGV4LXdyYXA6IHdyYXA7Cn0KLmJyYW5kIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxMnB4OyB9Ci5tYXJrIHsKICB3aWR0aDogMzZweDsgaGVpZ2h0OiAzNnB4OyBib3JkZXItcmFkaXVzOiA4cHg7IGJhY2tncm91bmQ6IHZhcigtLWFjY2VudCk7CiAgYm94LXNoYWRvdzogaW5zZXQgMCAwIDAgOXB4IHZhcigtLXBhbmVsKSwgaW5zZXQgMCAwIDAgMTJweCB2YXIoLS1hY2NlbnQpOwp9CmgxIHsgZm9udC1zaXplOiAxLjI1cmVtOyBtYXJnaW46IDA7IH0KaDIgeyBmb250LXNpemU6IDEuMXJlbTsgbWFyZ2luOiAwIDAgNHB4OyB9Ci5zdWIsIC5oaW50LCAuZmluZSB7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IG1hcmdpbjogMDsgfQouZmluZSB7IGZvbnQtc2l6ZTogMC44NXJlbTsgbWFyZ2luOiAyNHB4IDAgOHB4OyB9Ci53aG8geyBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBnYXA6IDEycHg7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IH0KbWFpbiB7IG1heC13aWR0aDogMTE4MHB4OyBtYXJnaW46IDAgYXV0bzsgcGFkZGluZzogMjRweCAxNnB4IDQwcHg7IH0KLmNhcmQgewogIGJhY2tncm91bmQ6IHZhcigtLXBhbmVsKTsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tbGluZSk7IGJvcmRlci1yYWRpdXM6IDEycHg7CiAgcGFkZGluZzogMThweCAyMHB4OyBib3gtc2hhZG93OiB2YXIoLS1zaGFkb3cpOwp9Ci53YWxsIHsgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOyBnYXA6IDE2cHg7IGZsZXgtd3JhcDogd3JhcDsgfQoud2FsbCBwIHsgbWFyZ2luOiAwOyBjb2xvcjogdmFyKC0tbXV0ZWQpOyB9Ci5zZWN0aW9uLWggeyBtYXJnaW4tdG9wOiAyOHB4OyB9Ci5oaW50IHsgbWFyZ2luLWJvdHRvbTogMTRweDsgfQouZ3JpZCB7IGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogcmVwZWF0KGF1dG8tZmlsbCwgbWlubWF4KDI2MHB4LCAxZnIpKTsgZ2FwOiAxNHB4OyB9Ci5ibGRnIHsgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAxMHB4OyB9Ci5ibGRnIGhlYWRlciB7IGRpc3BsYXk6IGZsZXg7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgYWxpZ24taXRlbXM6IGZsZXgtc3RhcnQ7IGdhcDogOHB4OyB9Ci5ibGRnIGgzIHsgbWFyZ2luOiAwOyBmb250LXNpemU6IDFyZW07IH0KLmJsZGcgLnBsYXQgeyBjb2xvcjogdmFyKC0tbXV0ZWQpOyBmb250LXNpemU6IDAuOXJlbTsgbWFyZ2luOiAycHggMCAwOyB9Ci5ibGRnIC5ub3RlIHsgbWFyZ2luOiAwOyBmb250LXNpemU6IDAuOTJyZW07IH0KLnBpbGwgewogIHdoaXRlLXNwYWNlOiBub3dyYXA7IGZvbnQtc2l6ZTogMC43OHJlbTsgZm9udC13ZWlnaHQ6IDYwMDsgYm9yZGVyLXJhZGl1czogOTk5cHg7CiAgcGFkZGluZzogMnB4IDEwcHg7IGJvcmRlcjogMXB4IHNvbGlkIHRyYW5zcGFyZW50Owp9Ci5waWxsLm9rIHsgY29sb3I6IHZhcigtLW9rKTsgYmFja2dyb3VuZDogdmFyKC0tb2stYmcpOyB9Ci5waWxsLndhcm4geyBjb2xvcjogdmFyKC0td2Fybik7IGJhY2tncm91bmQ6IHZhcigtLXdhcm4tYmcpOyB9Ci5waWxsLm9mZiB7IGNvbG9yOiB2YXIoLS1vZmYpOyBiYWNrZ3JvdW5kOiB2YXIoLS1vZmYtYmcpOyB9Ci5hY3Rpb25zIHsgZGlzcGxheTogZmxleDsgZmxleC13cmFwOiB3cmFwOyBnYXA6IDhweDsgbWFyZ2luLXRvcDogYXV0bzsgfQouYnRuIHsKICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7IHRleHQtZGVjb3JhdGlvbjogbm9uZTsgZm9udC13ZWlnaHQ6IDYwMDsgZm9udC1zaXplOiAwLjlyZW07CiAgYm9yZGVyLXJhZGl1czogOHB4OyBwYWRkaW5nOiA3cHggMTJweDsgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYWNjZW50KTsgY29sb3I6IHZhcigtLWFjY2VudCk7CiAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7IHdoaXRlLXNwYWNlOiBub3dyYXA7Cn0KLmJ0bi5wcmltYXJ5IHsgYmFja2dyb3VuZDogdmFyKC0tYWNjZW50KTsgY29sb3I6IHZhcigtLWFjY2VudC1pbmspOyB9Ci5idG4uZ2hvc3QgeyBib3JkZXItY29sb3I6IHZhcigtLWxpbmUpOyBjb2xvcjogdmFyKC0taW5rKTsgfQouYnRuOmZvY3VzLXZpc2libGUgeyBvdXRsaW5lOiAzcHggc29saWQgdmFyKC0tYWNjZW50KTsgb3V0bGluZS1vZmZzZXQ6IDJweDsgfQouaGVscCB7IG1hcmdpbi10b3A6IDI4cHg7IH0KLmhlbHAgdWwgeyBtYXJnaW46IDhweCAwIDA7IHBhZGRpbmctbGVmdDogMjBweDsgfQouaGVscCBsaSB7IG1hcmdpbjogNHB4IDA7IH0KLm5vdGljZSB7IG1hcmdpbi1ib3R0b206IDE2cHg7IHBhZGRpbmc6IDEycHggMTZweDsgYm9yZGVyLXJhZGl1czogMTBweDsgYmFja2dyb3VuZDogdmFyKC0td2Fybi1iZyk7IGNvbG9yOiB2YXIoLS13YXJuKTsgfQoubG9hZGluZyB7IGNvbG9yOiB2YXIoLS1tdXRlZCk7IH0KYSB7IGNvbG9yOiB2YXIoLS1hY2NlbnQpOyB9CkBtZWRpYSAobWF4LXdpZHRoOiA1MjBweCkgewogIC50b3AgeyBwYWRkaW5nOiAxMnB4IDE2cHg7IH0KICAud2hvIHsgd2lkdGg6IDEwMCU7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgfQp9Cg=='
  'portal.js' = 'LyogT0VTVSBDYW1lcmEgUG9ydGFsLiBSZW5kZXJzIHBvcnRhbC1jb25maWcuanNvbi4gTm8gZXh0ZXJuYWwgY2FsbHMsIG5vIGlubmVySFRNTC4gKi8KKGZ1bmN0aW9uICgpIHsKICAidXNlIHN0cmljdCI7CgogIHZhciBTVEFUVVMgPSB7CiAgICBsaXZlOiB7IGxhYmVsOiAiVmlld2FibGUgbm93IiwgY2xzOiAib2siIH0sCiAgICBuYXRpdmU6IHsgbGFiZWw6ICJPd24gYXBwIG9ubHkiLCBjbHM6ICJvayIgfSwKICAgIHBlbmRpbmc6IHsgbGFiZWw6ICJJbiBwcm9ncmVzcyIsIGNsczogIndhcm4iIH0sCiAgICBub25lOiB7IGxhYmVsOiAiTm8gcmVtb3RlIHZpZXciLCBjbHM6ICJvZmYiIH0sCiAgICB1bmtub3duOiB7IGxhYmVsOiAiVW5rbm93biIsIGNsczogIm9mZiIgfQogIH07CgogIGZ1bmN0aW9uIGVsKHRhZywgY2xzLCB0ZXh0KSB7CiAgICB2YXIgbiA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQodGFnKTsKICAgIGlmIChjbHMpIHsgbi5jbGFzc05hbWUgPSBjbHM7IH0KICAgIGlmICh0ZXh0ICE9PSB1bmRlZmluZWQgJiYgdGV4dCAhPT0gbnVsbCkgeyBuLnRleHRDb250ZW50ID0gU3RyaW5nKHRleHQpOyB9CiAgICByZXR1cm4gbjsKICB9CgogIGZ1bmN0aW9uIHNhZmVVcmwodSkgewogICAgaWYgKHR5cGVvZiB1ICE9PSAic3RyaW5nIikgeyByZXR1cm4gbnVsbDsgfQogICAgdmFyIHMgPSB1LnRyaW0oKTsKICAgIGlmICgvXmh0dHBzOlwvXC8vaS50ZXN0KHMpIHx8IC9ebWFpbHRvOi9pLnRlc3QocykgfHwgL15cL1teXC9dLy50ZXN0KHMpKSB7IHJldHVybiBzOyB9CiAgICByZXR1cm4gbnVsbDsKICB9CgogIGZ1bmN0aW9uIGxpbmsoaXRlbSwgcHJpbWFyeSkgewogICAgdmFyIGhyZWYgPSBzYWZlVXJsKGl0ZW0gJiYgaXRlbS51cmwpOwogICAgaWYgKCFocmVmKSB7IHJldHVybiBudWxsOyB9CiAgICB2YXIgYSA9IGVsKCJhIiwgcHJpbWFyeSA/ICJidG4gcHJpbWFyeSIgOiAiYnRuIiwgaXRlbS5sYWJlbCB8fCAiT3BlbiIpOwogICAgYS5ocmVmID0gaHJlZjsKICAgIGlmICgvXmh0dHBzOi9pLnRlc3QoaHJlZikpIHsgYS50YXJnZXQgPSAiX2JsYW5rIjsgYS5yZWwgPSAibm9vcGVuZXIgbm9yZWZlcnJlciI7IH0KICAgIHJldHVybiBhOwogIH0KCiAgZnVuY3Rpb24gcmVuZGVyQnVpbGRpbmcoYikgewogICAgdmFyIGNhcmQgPSBlbCgiYXJ0aWNsZSIsICJjYXJkIGJsZGciKTsKICAgIHZhciBoZWFkID0gZWwoImhlYWRlciIpOwogICAgdmFyIHRpdGxlcyA9IGVsKCJkaXYiKTsKICAgIHRpdGxlcy5hcHBlbmRDaGlsZChlbCgiaDMiLCBudWxsLCBiLm5hbWUgfHwgYi5jb2RlIHx8ICJCdWlsZGluZyIpKTsKICAgIGlmIChiLnBsYXRmb3JtKSB7IHRpdGxlcy5hcHBlbmRDaGlsZChlbCgicCIsICJwbGF0IiwgYi5wbGF0Zm9ybSkpOyB9CiAgICBoZWFkLmFwcGVuZENoaWxkKHRpdGxlcyk7CiAgICB2YXIgc3QgPSBTVEFUVVNbYi5zdGF0dXNdIHx8IFNUQVRVUy51bmtub3duOwogICAgaGVhZC5hcHBlbmRDaGlsZChlbCgic3BhbiIsICJwaWxsICIgKyBzdC5jbHMsIGIuc3RhdHVzTGFiZWwgfHwgc3QubGFiZWwpKTsKICAgIGNhcmQuYXBwZW5kQ2hpbGQoaGVhZCk7CiAgICBpZiAoYi5ub3RlKSB7IGNhcmQuYXBwZW5kQ2hpbGQoZWwoInAiLCAibm90ZSIsIGIubm90ZSkpOyB9CiAgICB2YXIgYWN0cyA9IGVsKCJkaXYiLCAiYWN0aW9ucyIpOwogICAgKGIubGlua3MgfHwgW10pLmZvckVhY2goZnVuY3Rpb24gKGwsIGkpIHsKICAgICAgdmFyIGEgPSBsaW5rKGwsIGkgPT09IDApOwogICAgICBpZiAoYSkgeyBhY3RzLmFwcGVuZENoaWxkKGEpOyB9CiAgICB9KTsKICAgIGlmIChhY3RzLmNoaWxkTm9kZXMubGVuZ3RoKSB7IGNhcmQuYXBwZW5kQ2hpbGQoYWN0cyk7IH0KICAgIHJldHVybiBjYXJkOwogIH0KCiAgZnVuY3Rpb24gc2hvd05vdGljZSh0ZXh0KSB7CiAgICB2YXIgbiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJub3RpY2UiKTsKICAgIG4udGV4dENvbnRlbnQgPSB0ZXh0OwogICAgbi5oaWRkZW4gPSBmYWxzZTsKICB9CgogIGZ1bmN0aW9uIHJlbmRlcihjZmcpIHsKICAgIHZhciBncmlkID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoImJ1aWxkaW5ncyIpOwogICAgZ3JpZC50ZXh0Q29udGVudCA9ICIiOwogICAgKGNmZy5idWlsZGluZ3MgfHwgW10pLmZvckVhY2goZnVuY3Rpb24gKGIpIHsgZ3JpZC5hcHBlbmRDaGlsZChyZW5kZXJCdWlsZGluZyhiKSk7IH0pOwoKICAgIHZhciB3YWxsID0gY2ZnLndhbGwgfHwge307CiAgICB2YXIgd2wgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgid2FsbC1saW5rIik7CiAgICB2YXIgd3VybCA9IHNhZmVVcmwod2FsbC51cmwpOwogICAgaWYgKHdhbGwudGV4dCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgid2FsbC10ZXh0IikudGV4dENvbnRlbnQgPSB3YWxsLnRleHQ7IH0KICAgIGlmICh3dXJsKSB7IHdsLmhyZWYgPSB3dXJsOyB3bC5oaWRkZW4gPSBmYWxzZTsgfQoKICAgIHZhciBoZWxwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoImhlbHAtbGlzdCIpOwogICAgaGVscC50ZXh0Q29udGVudCA9ICIiOwogICAgKGNmZy5oZWxwIHx8IFtdKS5mb3JFYWNoKGZ1bmN0aW9uIChoKSB7CiAgICAgIHZhciBsaSA9IGVsKCJsaSIpOwogICAgICBsaS5hcHBlbmRDaGlsZChkb2N1bWVudC5jcmVhdGVUZXh0Tm9kZSgoaC50ZXh0IHx8ICIiKSArICIgIikpOwogICAgICB2YXIgaHJlZiA9IHNhZmVVcmwoaC51cmwpOwogICAgICBpZiAoaHJlZikgewogICAgICAgIHZhciBhID0gZWwoImEiLCBudWxsLCBoLmxpbmtUZXh0IHx8IGhyZWYucmVwbGFjZSgvXm1haWx0bzovaSwgIiIpKTsKICAgICAgICBhLmhyZWYgPSBocmVmOwogICAgICAgIGlmICgvXmh0dHBzOi9pLnRlc3QoaHJlZikpIHsgYS50YXJnZXQgPSAiX2JsYW5rIjsgYS5yZWwgPSAibm9vcGVuZXIgbm9yZWZlcnJlciI7IH0KICAgICAgICBsaS5hcHBlbmRDaGlsZChhKTsKICAgICAgfQogICAgICBoZWxwLmFwcGVuZENoaWxkKGxpKTsKICAgIH0pOwoKICAgIGlmIChjZmcubm90aWNlKSB7IHNob3dOb3RpY2UoY2ZnLm5vdGljZSk7IH0KICAgIHZhciBmaW5lID0gW107CiAgICBpZiAoY2ZnLnVwZGF0ZWQpIHsgZmluZS5wdXNoKCJQb3J0YWwgaW5mb3JtYXRpb24gdXBkYXRlZCAiICsgY2ZnLnVwZGF0ZWQgKyAiLiIpOyB9CiAgICBmaW5lLnB1c2goIkxpdmUgdmlld2luZyBpcyBmb3IgbmFtZWQgYWRtaW5pc3RyYXRvcnMgZm9yIHNjaG9vbCBzYWZldHkuIFZpZGVvIHNob3dpbmcgc3R1ZGVudHMgY2FuIGJlIGFuIGVkdWNhdGlvbiByZWNvcmQgdW5kZXIgRkVSUEE6IGRvIG5vdCByZWNvcmQsIHNjcmVlbnNob3Qgb3Igc2hhcmUgaXQgb3V0c2lkZSB0aGUgZm9vdGFnZSByZXF1ZXN0IHByb2Nlc3MuIik7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgiZmluZSIpLnRleHRDb250ZW50ID0gZmluZS5qb2luKCIgIik7CiAgfQoKICBmdW5jdGlvbiBnZXRKc29uKHVybCkgewogICAgcmV0dXJuIGZldGNoKHVybCwgeyBjcmVkZW50aWFsczogInNhbWUtb3JpZ2luIiwgY2FjaGU6ICJuby1zdG9yZSIgfSkudGhlbihmdW5jdGlvbiAocikgewogICAgICBpZiAoIXIub2spIHsgdGhyb3cgbmV3IEVycm9yKHVybCArICIgcmV0dXJuZWQgIiArIHIuc3RhdHVzKTsgfQogICAgICByZXR1cm4gci5qc29uKCk7CiAgICB9KTsKICB9CgogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoIkRPTUNvbnRlbnRMb2FkZWQiLCBmdW5jdGlvbiAoKSB7CiAgICBnZXRKc29uKCIvb2F1dGgyL3VzZXJpbmZvIikudGhlbihmdW5jdGlvbiAodSkgewogICAgICBpZiAodSAmJiAodS5lbWFpbCB8fCB1LnVzZXIpKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoIndobyIpLnRleHRDb250ZW50ID0gIlNpZ25lZCBpbiBhcyAiICsgKHUuZW1haWwgfHwgdS51c2VyKTsKICAgICAgfQogICAgfSkuY2F0Y2goZnVuY3Rpb24gKCkgeyAvKiB0aGUgcGFnZSBzdGlsbCB3b3JrcyB3aXRob3V0IHRoZSBuYW1lICovIH0pOwoKICAgIGdldEpzb24oInBvcnRhbC1jb25maWcuanNvbiIpLnRoZW4ocmVuZGVyKS5jYXRjaChmdW5jdGlvbiAoZSkgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgiYnVpbGRpbmdzIikudGV4dENvbnRlbnQgPSAiIjsKICAgICAgc2hvd05vdGljZSgiVGhlIGJ1aWxkaW5nIGxpc3QgY291bGQgbm90IGJlIGxvYWRlZCAoIiArIGUubWVzc2FnZSArICIpLiBUZWxsIEplZmYgSmFtZWxlLiIpOwogICAgfSk7CiAgfSk7Cn0oKSk7Cg=='
  'portal-config.json' = 'ewogICJ1cGRhdGVkIjogIk9jdG9iZXIgNSwgMjAyNiIsCiAgIm5vdGljZSI6ICIiLAogICJ3YWxsIjogewogICAgInVybCI6ICIiLAogICAgInRleHQiOiAiRXZlcnkgYnVpbGRpbmcgb24gb25lIHNjcmVlbi4gVGhpcyBvcGVucyBvbmNlIHRoZSBjYW1lcmEgcmVsYXkgcGlsb3QgaXMgcnVubmluZyAoQ2VudHJhbCBPZmZpY2UsIEJsdWUgTW91bnRhaW4gYW5kIE5ld2J1cnkgZmlyc3QpLiIKICB9LAogICJidWlsZGluZ3MiOiBbCiAgICB7CiAgICAgICJjb2RlIjogIkJNVSIsCiAgICAgICJuYW1lIjogIkJsdWUgTW91bnRhaW4gVW5pb24iLAogICAgICAicGxhdGZvcm0iOiAiVmVya2FkYSAoY2xvdWQpIiwKICAgICAgInN0YXR1cyI6ICJuYXRpdmUiLAogICAgICAibm90ZSI6ICJTaWduIGluIHdpdGggeW91ciBWZXJrYWRhIGFjY291bnQuIElmIHlvdSBkbyBub3QgaGF2ZSBvbmUsIGFzayBUb2RkIFBvd2VycyBvciBKZWZmLiIsCiAgICAgICJsaW5rcyI6IFsgeyAibGFiZWwiOiAiT3BlbiBWZXJrYWRhIENvbW1hbmQiLCAidXJsIjogImh0dHBzOi8vY29tbWFuZC52ZXJrYWRhLmNvbS8iIH0gXQogICAgfSwKICAgIHsKICAgICAgImNvZGUiOiAiV1JWUyIsCiAgICAgICJuYW1lIjogIldhaXRzIFJpdmVyIFZhbGxleSBTY2hvb2wiLAogICAgICAicGxhdGZvcm0iOiAiT3BlbkV5ZSAoY2xvdWQpIiwKICAgICAgInN0YXR1cyI6ICJuYXRpdmUiLAogICAgICAibm90ZSI6ICJTaWduIGluIHdpdGggeW91ciBPcGVuRXllIGFjY291bnQgKHNldCB1cCBpbiBKdWx5IDIwMjMpLiBBc2sgSmVmZiBpZiB0aGUgbG9naW4gbm8gbG9uZ2VyIHdvcmtzLiIsCiAgICAgICJsaW5rcyI6IFsgeyAibGFiZWwiOiAiT3BlbiBPcGVuRXllIiwgInVybCI6ICJodHRwczovL293cy5vcGVuZXllLm5ldC8iIH0gXQogICAgfSwKICAgIHsKICAgICAgImNvZGUiOiAiT0hTIiwKICAgICAgIm5hbWUiOiAiT3hib3cgSGlnaCBTY2hvb2wiLAogICAgICAicGxhdGZvcm0iOiAiZXhhY3FWaXNpb24gcmVjb3JkZXIiLAogICAgICAic3RhdHVzIjogInBlbmRpbmciLAogICAgICAibm90ZSI6ICJSZW1vdGUgdmlld2luZyBpcyBiZWluZyByZXN0b3JlZCBhZnRlciB0aGUgQXVndXN0IGZpcmV3YWxsIHJlcGxhY2VtZW50LiIsCiAgICAgICJsaW5rcyI6IFtdCiAgICB9LAogICAgewogICAgICAiY29kZSI6ICJORVMiLAogICAgICAibmFtZSI6ICJOZXdidXJ5IEVsZW1lbnRhcnkiLAogICAgICAicGxhdGZvcm0iOiAiZXhhY3FWaXNpb24gcmVjb3JkZXIiLAogICAgICAic3RhdHVzIjogInBlbmRpbmciLAogICAgICAibm90ZSI6ICJSZW1vdGUgdmlld2luZyBpcyBiZWluZyByZXN0b3JlZC4gQ3VycmVudCBDb25jZXB0cyBpcyBmaXhpbmcgdGhlIGZpcmV3YWxsIHBhdGggdG8gdGhlIGNhbWVyYSBzZXJ2ZXIuIiwKICAgICAgImxpbmtzIjogW10KICAgIH0sCiAgICB7CiAgICAgICJjb2RlIjogIkJFUyIsCiAgICAgICJuYW1lIjogIkJyYWRmb3JkIEVsZW1lbnRhcnkiLAogICAgICAicGxhdGZvcm0iOiAiZXhhY3FWaXNpb24gcmVjb3JkZXIgKG9sZGVyIFBDKSIsCiAgICAgICJzdGF0dXMiOiAibm9uZSIsCiAgICAgICJub3RlIjogIlZpZXdhYmxlIG9uIHNpdGUgb25seS4gVGhpcyByZWNvcmRlciBpcyBwbGFubmVkIGZvciByZXBsYWNlbWVudC4iLAogICAgICAibGlua3MiOiBbXQogICAgfSwKICAgIHsKICAgICAgImNvZGUiOiAiVEVTIiwKICAgICAgIm5hbWUiOiAiVGhldGZvcmQgRWxlbWVudGFyeSIsCiAgICAgICJwbGF0Zm9ybSI6ICJIb25leXdlbGwgcmVjb3JkZXIiLAogICAgICAic3RhdHVzIjogIm5vbmUiLAogICAgICAibm90ZSI6ICJWaWV3YWJsZSBpbiB0aGUgbWFpbiBvZmZpY2Ugb25seS4gSXQgam9pbnMgdGhlIGxpdmUgd2FsbCBhZnRlciB0aGlzIGZhbGwncyBzaXRlIGNoZWNrLiIsCiAgICAgICJsaW5rcyI6IFtdCiAgICB9LAogICAgewogICAgICAiY29kZSI6ICJSQiIsCiAgICAgICJuYW1lIjogIlJpdmVyIEJlbmQgQ2FyZWVyIGFuZCBUZWNobmljYWwgQ2VudGVyIiwKICAgICAgInBsYXRmb3JtIjogIkJlaW5nIGlkZW50aWZpZWQiLAogICAgICAic3RhdHVzIjogInVua25vd24iLAogICAgICAibm90ZSI6ICJUaGUgdGVjaG5vbG9neSB0ZWFtIGlzIGNvbmZpcm1pbmcgd2hpY2ggc3lzdGVtIFJpdmVyIEJlbmQgdXNlcy4iLAogICAgICAibGlua3MiOiBbXQogICAgfSwKICAgIHsKICAgICAgImNvZGUiOiAiQ08iLAogICAgICAibmFtZSI6ICJDZW50cmFsIE9mZmljZSIsCiAgICAgICJwbGF0Zm9ybSI6ICJVbmlGaSBQcm90ZWN0IChwaWxvdCkiLAogICAgICAic3RhdHVzIjogInBlbmRpbmciLAogICAgICAibm90ZSI6ICJDYW1lcmFzIGZvciB0aGUgQ2VudHJhbCBPZmZpY2UgYXJlIGFwcHJvdmVkIGFuZCBub3QgeWV0IGluc3RhbGxlZC4iLAogICAgICAibGlua3MiOiBbXQogICAgfQogIF0sCiAgImhlbHAiOiBbCiAgICB7ICJ0ZXh0IjogIkVtZXJnZW5jeSBpbiBwcm9ncmVzczogY2FsbCA5MTEgZmlyc3QsIHRoZW4gdGhlIGJ1aWxkaW5nIHByaW5jaXBhbC4iLCAidXJsIjogIiIsICJsaW5rVGV4dCI6ICIiIH0sCiAgICB7ICJ0ZXh0IjogIlRvIHJlcXVlc3QgYSBjb3B5IG9mIHJlY29yZGVkIGZvb3RhZ2UsIGVtYWlsIEplZmYgd2l0aCB0aGUgYnVpbGRpbmcsIGRhdGUsIHRpbWUgYW5kIHJlYXNvbjoiLCAidXJsIjogIm1haWx0bzpqZWZmLmphbWVsZUBvZXN1Lm9yZz9zdWJqZWN0PUNhbWVyYSUyMGZvb3RhZ2UlMjByZXF1ZXN0IiwgImxpbmtUZXh0IjogIlJlcXVlc3QgZm9vdGFnZSIgfSwKICAgIHsgInRleHQiOiAiU29tZXRoaW5nIG9uIHRoaXMgcGFnZSBub3Qgd29ya2luZz8iLCAidXJsIjogIm1haWx0bzpqZWZmLmphbWVsZUBvZXN1Lm9yZz9zdWJqZWN0PUNhbWVyYSUyMHBvcnRhbCUyMGhlbHAiLCAibGlua1RleHQiOiAiRW1haWwgSmVmZiBKYW1lbGUiIH0KICBdCn0K'
}

$script:Problems = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { Write-Output $t }
function Head([string]$t) { Write-Output ''; Write-Output ('== ' + $t) }
function Problem([string]$t) { $script:Problems.Add($t); Write-Output ('PROBLEM: ' + $t) }

function Invoke-Native([string]$exe, [string[]]$argList, [switch]$AllowFail) {
  # Windows PowerShell 5.1 turns native stderr into terminating errors under Stop; httpd and openssl write normal output there.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = (& $exe @argList 2>&1 | ForEach-Object { "$_" }) -join "`r`n"
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  $script:LastNativeExit = $code
  if ($code -ne 0 -and -not $AllowFail) { throw ("{0} {1} failed ({2}): {3}" -f $exe, ($argList -join ' '), $code, $out.Trim()) }
  return $out
}

function Get-ServerAddress {
  if ($ServerIP) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ServerIP -ErrorAction SilentlyContinue
    if (-not $ip) { throw "ServerIP $ServerIP is not an address on this server." }
    return $ip
  }
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
  if (-not $route) { throw 'No default route found; pass ServerIP.' }
  return (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1)
}

function Get-NetworkCidr([string]$ip, [int]$prefix) {
  $bytes = ([Net.IPAddress]::Parse($ip)).GetAddressBytes()
  [Array]::Reverse($bytes)
  $n = [BitConverter]::ToUInt32($bytes, 0)
  $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix)) }
  $net = $n -band $mask
  $b = [BitConverter]::GetBytes([uint32]$net)
  [Array]::Reverse($b)
  return ('{0}/{1}' -f ([Net.IPAddress]::new($b)).ToString(), $prefix)
}

function Get-Sha256([string]$path) { return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower() }

function Get-VcRuntime {
  $k = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
  if (Test-Path $k) { $p = Get-ItemProperty $k; if ($p.Installed -eq 1) { return [version]('{0}.{1}.{2}' -f $p.Major, $p.Minor, $p.Bld) } }
  return $null
}

function Get-ApacheArtifact {
  $url = $ApacheZipUrl
  if (-not $url) {
    $page = Invoke-WebRequest -UseBasicParsing -UserAgent $UA -Uri 'https://www.apachelounge.com/download/'
    $found = [regex]::Matches($page.Content, 'href="(?<p>/download/VS1[78]/binaries/httpd-2\.4\.(?<v>\d+)-(?<d>\d+)-[Ww]in64-VS1[78]\.zip)"') |
      Sort-Object { [int]$_.Groups['v'].Value }, { [int]$_.Groups['d'].Value } -Descending | Select-Object -First 1
    if (-not $found) { throw 'Could not find an Apache Win64 zip link on apachelounge.com/download. Pass ApacheZipUrl.' }
    $url = 'https://www.apachelounge.com' + $found.Groups['p'].Value
  }
  $name = Split-Path $url -Leaf
  $dest = Join-Path $Staging $name
  if ((Test-Path $dest) -and $ApacheSha256 -and (Get-Sha256 $dest) -ne $ApacheSha256.ToLower()) { Remove-Item $dest -Force }
  if (-not (Test-Path $dest)) { Invoke-WebRequest -UseBasicParsing -UserAgent $UA -Uri $url -OutFile $dest }
  return [pscustomobject]@{ Url = $url; Path = $dest; Sha256 = (Get-Sha256 $dest) }
}

function Get-ProxyArtifact {
  $api = 'https://api.github.com/repos/oauth2-proxy/oauth2-proxy/releases/tags/' + $OAuth2ProxyVersion
  $rel = Invoke-RestMethod -UseBasicParsing -UserAgent $UA -Uri $api -Headers @{ Accept = 'application/vnd.github+json' }
  $asset = $rel.assets | Where-Object { $_.name -match 'windows-amd64\.tar\.gz$' } | Select-Object -First 1
  if (-not $asset) { throw ('No windows-amd64 asset in oauth2-proxy ' + $OAuth2ProxyVersion + '. Assets: ' + (($rel.assets | ForEach-Object name) -join ', ')) }
  $dest = Join-Path $Staging $asset.name
  if ((Test-Path $dest) -and $OAuth2ProxySha256 -and (Get-Sha256 $dest) -ne $OAuth2ProxySha256.ToLower()) { Remove-Item $dest -Force }
  if (-not (Test-Path $dest)) { Invoke-WebRequest -UseBasicParsing -UserAgent $UA -Uri $asset.browser_download_url -OutFile $dest }
  $sha = Get-Sha256 $dest
  $gh = $null
  if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) { $gh = ($asset.digest -replace '^sha256:', '').ToLower() }
  return [pscustomobject]@{ Url = $asset.browser_download_url; Path = $dest; Sha256 = $sha; GitHubDigest = $gh }
}

function Test-Outbound([string]$url) {
  try { $r = Invoke-WebRequest -UseBasicParsing -UserAgent $UA -Uri $url -Method Head -TimeoutSec 15; return "ok ($($r.StatusCode))" }
  catch {
    if ($_.Exception.Response) { return ('ok (HTTP ' + [int]$_.Exception.Response.StatusCode + ')') }
    return ('FAILED: ' + $_.Exception.Message)
  }
}

function Get-Listeners {
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 80, 443, 4180, 8088 } |
    ForEach-Object {
      $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
      [pscustomobject]@{ Address = $_.LocalAddress; Port = $_.LocalPort; Pid = $_.OwningProcess; Process = $(if ($p) { $p.ProcessName } else { '?' }) }
    }
}

function Get-DnsPlan([string]$ip) {
  if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ Action = 'none'; Detail = 'DnsServer module not present on this server' } }
  $labels = $Hostname.Split('.')
  $parent = ($labels[1..($labels.Length - 1)] -join '.')
  $pz = Get-DnsServerZone -Name $parent -ErrorAction SilentlyContinue
  if ($pz) {
    $rec = Get-DnsServerResourceRecord -ZoneName $parent -Name $labels[0] -RRType A -ErrorAction SilentlyContinue
    if ($rec) { return [pscustomobject]@{ Action = 'exists'; Detail = "A record $($labels[0]) already in zone $parent -> $($rec.RecordData.IPv4Address)" } }
    return [pscustomobject]@{ Action = 'record-in-parent'; Detail = "add A record $($labels[0]) -> $ip in existing zone $parent"; Zone = $parent; Name = $labels[0] }
  }
  $z = Get-DnsServerZone -Name $Hostname -ErrorAction SilentlyContinue
  if ($z) {
    $rec = Get-DnsServerResourceRecord -ZoneName $Hostname -Name '@' -RRType A -ErrorAction SilentlyContinue
    if ($rec) { return [pscustomobject]@{ Action = 'exists'; Detail = "zone $Hostname exists, A -> $($rec.RecordData.IPv4Address)" } }
    return [pscustomobject]@{ Action = 'record-in-pinpoint'; Detail = "add A @ -> $ip in existing zone $Hostname"; Zone = $Hostname; Name = '@' }
  }
  return [pscustomobject]@{ Action = 'pinpoint'; Detail = "create AD-integrated zone $Hostname (domain replication, no dynamic updates) with A @ -> $ip. Only this one name is answered internally; the rest of oesu.org still resolves from the internet."; Zone = $Hostname; Name = '@' }
}

function Write-SiteFiles {
  New-Item -ItemType Directory -Force -Path $SiteDir | Out-Null
  foreach ($k in $SiteFiles.Keys) {
    $target = Join-Path $SiteDir $k
    if ($k -eq 'portal-config.json' -and (Test-Path $target)) { Say "  kept existing $k (edit it on the server to update building info)"; continue }
    [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($SiteFiles[$k]))
  }
}

function Get-Secrets {
  $f = Join-Path $SecretDir 'oauth.json'
  if (Test-Path $f) { return (Get-Content -Raw $f | ConvertFrom-Json) }
  return $null
}

function New-RandomString([int]$len) {
  $chars = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  $bytes = New-Object byte[] $len
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function TomlStr([string]$s) { return '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }

function Write-ProxyConfig($secrets) {
  $cid = 'NOT-SET-RUN-SETSECRET'; $csec = 'NOT-SET-RUN-SETSECRET'; $cookie = (New-RandomString 32)
  if ($secrets) {
    if ($secrets.client_id) { $cid = $secrets.client_id }
    if ($secrets.client_secret) { $csec = $secrets.client_secret }
    if ($secrets.cookie_secret) { $cookie = $secrets.cookie_secret }
  }
  $cfg = @"
# OESU Camera Portal, oauth2-proxy settings. Generated by Install-OESUCameraPortal.ps1 $ScriptVersion. Contains secrets: do not copy.
http_address = "127.0.0.1:4180"
reverse_proxy = true
real_client_ip_header = "X-Forwarded-For"
provider = "google"
provider_display_name = "OESU Google account"
client_id = $(TomlStr $cid)
client_secret = $(TomlStr $csec)
code_challenge_method = "S256"
redirect_url = "https://$Hostname/oauth2/callback"
upstreams = [ "http://127.0.0.1:8088/" ]
authenticated_emails_file = "$RootFwd/conf/allowed-emails.txt"
skip_provider_button = true
pass_user_headers = true
cookie_name = "_oesu_camportal"
cookie_secret = $(TomlStr $cookie)
cookie_secure = true
cookie_httponly = true
cookie_samesite = "lax"
cookie_expire = "8h0m0s"
session_store_type = "cookie"
request_logging = true
auth_logging = true
standard_logging = true
logging_filename = "$RootFwd/logs/oauth2-proxy.log"
logging_max_size = 10
logging_max_age = 180
logging_max_backups = 30
logging_local_time = true
footer = "OESU Technology. Live viewing is for named administrators only."
$(if ([version]($OAuth2ProxyVersion.TrimStart('v')) -ge [version]'7.15.4') { 'trusted_proxy_ips = [ "127.0.0.1" ]' })
"@
  [IO.File]::WriteAllText((Join-Path $ConfDir 'oauth2-proxy.cfg'), $cfg, (New-Object Text.UTF8Encoding($false)))
  return $cookie
}

function Write-ApacheConfig([string]$ip, [string]$net) {
  $tpl = @'
# OESU Camera Portal, Apache configuration. Generated by Install-OESUCameraPortal.ps1 {{VER}}. Rerun the installer instead of hand editing.
Define SRVROOT "{{ROOT}}/apache/Apache24"
ServerRoot "${SRVROOT}"
ServerName {{HOST}}
ServerAdmin jeff.jamele@oesu.org
PidFile "{{ROOT}}/logs/httpd.pid"
DefaultRuntimeDir "{{ROOT}}/logs"

Listen {{IP}}:80
Listen {{IP}}:443
Listen 127.0.0.1:8088

LoadModule alias_module modules/mod_alias.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule dir_module modules/mod_dir.so
LoadModule headers_module modules/mod_headers.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule mime_module modules/mod_mime.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
LoadModule reqtimeout_module modules/mod_reqtimeout.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
LoadModule ssl_module modules/mod_ssl.so

ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
Timeout 60
KeepAlive On
KeepAliveTimeout 5
RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500
LimitRequestBody 65536
ThreadsPerChild 64
MaxConnectionsPerChild 0
AcceptFilter http none
AcceptFilter https none
EnableSendfile Off
EnableMMAP Off
TypesConfig conf/mime.types
AddDefaultCharset utf-8

<Directory />
    AllowOverride None
    Options None
    Require all denied
</Directory>

LogLevel warn
ErrorLog "|{{ROOT}}/apache/Apache24/bin/rotatelogs.exe -l {{ROOT}}/logs/apache-error-%Y-%m-%d.log 86400"
LogFormat "%{%Y-%m-%d %H:%M:%S}t %a \"%m %U %H\" %>s %b \"%{User-Agent}i\" %D" edge
LogFormat "%{%Y-%m-%d %H:%M:%S}t viewer=%{X-Forwarded-Email}i from=%{X-Forwarded-For}i \"%m %U\" %>s %b" viewer

SSLProtocol -all +TLSv1.2 +TLSv1.3
SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
SSLHonorCipherOrder off
SSLSessionTickets off
SSLSessionCache "shmcb:{{ROOT}}/logs/ssl_scache(512000)"
SSLSessionCacheTimeout 300

# Port 80 only redirects to HTTPS.
<VirtualHost {{IP}}:80>
    ServerName {{HOST}}
    CustomLog "|{{ROOT}}/apache/Apache24/bin/rotatelogs.exe -l {{ROOT}}/logs/apache-redirect-%Y-%m-%d.log 86400" edge
    Redirect permanent / https://{{HOST}}/
</VirtualHost>

# Port 443: TLS, Central Office LAN only, everything goes through Google sign-in (oauth2-proxy).
<VirtualHost {{IP}}:443>
    ServerName {{HOST}}
    SSLEngine on
    SSLCertificateFile "{{ROOT}}/conf/ssl/{{HOST}}.crt"
    SSLCertificateKeyFile "{{ROOT}}/conf/ssl/{{HOST}}.key"
    CustomLog "|{{ROOT}}/apache/Apache24/bin/rotatelogs.exe -l {{ROOT}}/logs/apache-access-%Y-%m-%d.log 86400" edge

    <Location "/">
        Require ip {{NET}}
    </Location>

    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"
    Header always set Referrer-Policy "no-referrer"
    Header always set Permissions-Policy "camera=(), microphone=(), geolocation=()"
    Header always set Cross-Origin-Opener-Policy "same-origin"

    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 30
    RequestHeader unset X-Forwarded-Email
    RequestHeader unset X-Forwarded-User
    RequestHeader unset X-Forwarded-For
    RequestHeader unset X-Forwarded-Host
    RequestHeader unset X-Forwarded-Uri
    RequestHeader unset X-Real-IP
    RequestHeader unset X-Auth-Request-Redirect
    RequestHeader set X-Forwarded-Proto "https"
    ProxyPass "/" "http://127.0.0.1:4180/" retry=5
    ProxyPassReverse "/" "http://127.0.0.1:4180/"
</VirtualHost>

# Loopback only: the portal page itself, reachable only through oauth2-proxy.
<VirtualHost 127.0.0.1:8088>
    ServerName {{HOST}}
    DocumentRoot "{{ROOT}}/site"
    DirectoryIndex index.html
    <Directory "{{ROOT}}/site">
        Options None
        AllowOverride None
        Require ip 127.0.0.1
    </Directory>
    Header always set Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    Header always set Cache-Control "no-store"
    CustomLog "|{{ROOT}}/apache/Apache24/bin/rotatelogs.exe -l {{ROOT}}/logs/portal-viewers-%Y-%m-%d.log 86400" viewer
</VirtualHost>
'@
  $conf = $tpl.Replace('{{ROOT}}', $RootFwd).Replace('{{HOST}}', $Hostname).Replace('{{IP}}', $ip).Replace('{{NET}}', $net).Replace('{{VER}}', $ScriptVersion)
  [IO.File]::WriteAllText((Join-Path $ConfDir 'httpd.conf'), $conf, (New-Object Text.UTF8Encoding($false)))
}

function Set-Acls {
  Invoke-Native $Icacls @($Root, '/inheritance:r', '/grant:r', "${SID_SYSTEM}:(OI)(CI)F", "${SID_ADMINS}:(OI)(CI)F", "${SID_LOCALSVC}:(OI)(CI)RX", '/T', '/C', '/Q') | Out-Null
  Invoke-Native $Icacls @($LogDir, '/grant', "${SID_LOCALSVC}:(OI)(CI)M", '/T', '/C', '/Q') | Out-Null
  foreach ($d in @($SecretDir, $SslDir, $Staging)) {
    if (Test-Path $d) {
      Invoke-Native $Icacls @($d, '/inheritance:r', '/grant:r', "${SID_SYSTEM}:(OI)(CI)F", "${SID_ADMINS}:(OI)(CI)F", '/T', '/C', '/Q') | Out-Null
      Invoke-Native $Icacls @($d, '/remove:g', $SID_LOCALSVC, '/T', '/C', '/Q') | Out-Null
    }
  }
  # Apache must read the key and oauth2-proxy must read its config, and nothing else gets them.
  foreach ($f in @((Join-Path $SslDir "$Hostname.key"), (Join-Path $SslDir "$Hostname.crt"), (Join-Path $ConfDir 'oauth2-proxy.cfg'))) {
    if (Test-Path $f) { Invoke-Native $Icacls @($f, '/inheritance:r', '/grant:r', "${SID_SYSTEM}:F", "${SID_ADMINS}:F", "${SID_LOCALSVC}:R", '/C', '/Q') | Out-Null }
  }
  Invoke-Native $Icacls @($SslDir, '/grant', "${SID_LOCALSVC}:RX", '/C', '/Q') | Out-Null
}

function New-PortalCert {
  $crt = Join-Path $SslDir "$Hostname.crt"; $key = Join-Path $SslDir "$Hostname.key"
  if ((Test-Path $crt) -and (Test-Path $key)) {
    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2($crt)
    if ($c.NotAfter -gt (Get-Date).AddDays(30)) { Say "  certificate kept (expires $($c.NotAfter.ToString('yyyy-MM-dd')))"; return }
    Say '  certificate expires within 30 days, making a new one'
  }
  $openssl = Join-Path $ApacheDir 'bin\openssl.exe'
  if (-not (Test-Path $openssl)) { throw 'openssl.exe not found in the Apache bin folder.' }
  $cnf = Join-Path $ApacheDir 'conf\openssl.cnf'
  if (Test-Path $cnf) { $env:OPENSSL_CONF = $cnf }
  # 820 days keeps Apple devices happy with a privately trusted certificate (825 day limit).
  $o = Invoke-Native $openssl @('req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-days', '820', '-nodes',
    '-keyout', $key, '-out', $crt, '-subj', "/CN=$Hostname/O=Orange East Supervisory Union/OU=Technology",
    '-addext', "subjectAltName=DNS:$Hostname", '-addext', 'basicConstraints=critical,CA:FALSE',
    '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment', '-addext', 'extendedKeyUsage=serverAuth') -AllowFail
  if (-not (Test-Path $crt)) { throw ('Certificate generation failed: ' + $o) }
  New-Item -ItemType Directory -Force -Path $PubDir | Out-Null
  Copy-Item $crt (Join-Path $PubDir "$Hostname.crt") -Force
  Say "  new certificate made: $crt (public copy in $PubDir)"
}

function Register-ProxyTask {
  $exe = Join-Path $ProxyDir 'oauth2-proxy.exe'
  $action = New-ScheduledTaskAction -Execute $exe -Argument ('--config "' + (Join-Path $ConfDir 'oauth2-proxy.cfg') + '"') -WorkingDirectory $ProxyDir
  $t1 = New-ScheduledTaskTrigger -AtStartup
  $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCALSERVICE' -LogonType ServiceAccount -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings `
    -Description 'OESU Camera Portal: Google sign-in in front of the portal (oauth2-proxy). The 5 minute trigger restarts it if it stopped.' -Force | Out-Null
}

function Register-CleanupTask {
  $cmd = "Get-ChildItem -Path '$LogDir' -Filter *.log -File | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-180) } | Remove-Item -Force"
  $action = New-ScheduledTaskAction -Execute (Join-Path $Sys32 'WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -Command "' + $cmd + '"')
  $trigger = New-ScheduledTaskTrigger -Daily -At '3:17AM'
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount
  Register-ScheduledTask -TaskName $TaskClean -TaskPath '\OESU\' -Action $action -Trigger $trigger -Principal $principal `
    -Description 'OESU Camera Portal: delete portal logs older than 180 days.' -Force | Out-Null
}

function Install-ApacheService {
  $httpd = Join-Path $ApacheDir 'bin\httpd.exe'
  $existing = Get-Service -Name $Svc -ErrorAction SilentlyContinue
  if (-not $existing) {
    Invoke-Native $httpd @('-k', 'install', '-n', $Svc, '-f', (Join-Path $ConfDir 'httpd.conf')) | Out-Null
  }
  $w = Get-CimInstance Win32_Service -Filter "Name='$Svc'"
  $r = Invoke-CimMethod -InputObject $w -MethodName Change -Arguments @{ StartName = 'NT AUTHORITY\LocalService'; StartPassword = '' }
  if ($r.ReturnValue -ne 0) { throw "Could not set $Svc to run as LocalService (Win32 code $($r.ReturnValue))." }
  Set-Service -Name $Svc -StartupType Automatic
  Invoke-Native $ScExe @('description', $Svc, 'OESU Camera Portal (Apache, LAN only). Installed by Install-OESUCameraPortal.ps1.') | Out-Null
  Invoke-Native $ScExe @('failure', $Svc, 'reset=', '86400', 'actions=', 'restart/60000/restart/60000/restart/300000') | Out-Null
}

function Show-Status {
  Head 'Status'
  $s = Get-Service -Name $Svc -ErrorAction SilentlyContinue
  Say ('Apache service ' + $Svc + ': ' + $(if ($s) { $s.Status } else { 'not installed' }))
  if ($s) { $w = Get-CimInstance Win32_Service -Filter "Name='$Svc'"; Say ('  runs as ' + $w.StartName) }
  $t = Get-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' -ErrorAction SilentlyContinue
  Say ('oauth2-proxy task: ' + $(if ($t) { $t.State } else { 'not registered' }))
  $p = Get-Process -Name 'oauth2-proxy' -ErrorAction SilentlyContinue
  Say ('oauth2-proxy process: ' + $(if ($p) { 'running, pid ' + ($p.Id -join ',') } else { 'not running' }))
  Say 'Listeners:'; Get-Listeners | ForEach-Object { Say ('  {0}:{1} {2} (pid {3})' -f $_.Address, $_.Port, $_.Process, $_.Pid) }
  $crt = Join-Path $SslDir "$Hostname.crt"
  if (Test-Path $crt) {
    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2($crt)
    $days = [int]($c.NotAfter - (Get-Date)).TotalDays
    Say ("Certificate: {0}, expires {1} ({2} days), SHA-1 thumbprint {3}" -f $c.Subject, $c.NotAfter.ToString('yyyy-MM-dd'), $days, $c.Thumbprint)
    if ($days -lt 45) { Problem 'Certificate expires within 45 days: rerun Install to renew, then rerun TrustCert on viewer PCs.' }
  }
  $sec = Get-Secrets
  Say ('Google OAuth client: ' + $(if ($sec -and $sec.client_id -and $sec.client_secret) { 'set (client id ' + $sec.client_id.Substring(0, [Math]::Min(12, $sec.client_id.Length)) + '...)' } else { 'NOT SET, run SetSecret at the server' }))
  $emails = Join-Path $ConfDir 'allowed-emails.txt'
  if (Test-Path $emails) { Say ('Allowed viewers: ' + ((Get-Content $emails | Where-Object { $_ -and -not $_.StartsWith('#') }) -join ', ')) }
  try {
    $old = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $ip = (Get-ServerAddress).IPAddress
    $req = [Net.HttpWebRequest]::Create("https://$ip/")
    $req.Host = $Hostname; $req.AllowAutoRedirect = $false; $req.Timeout = 10000
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response }
    if ($resp) { Say ('HTTPS self test: ' + [int]$resp.StatusCode + ' ' + $resp.Headers['Location'] + ' (302 to Google or /oauth2 means sign-in is working)'); $resp.Close() }
    else { Problem 'HTTPS self test got no response.' }
  } catch { Problem ('HTTPS self test failed: ' + $_.Exception.Message) }
  finally { [Net.ServicePointManager]::ServerCertificateValidationCallback = $old }
  $pem = Join-Path $PubDir "$Hostname.crt"
  if (Test-Path $pem) {
    Say ''
    Say 'Public certificate (safe to share; pass as CertPem to TrustCert on viewer PCs):'
    Get-Content $pem | ForEach-Object { Say $_ }
  }
}

# ---------------------------------------------------------------- main
try {
  Say ("OESU Camera Portal installer {0}, mode {1}, on {2} at {3}" -f $ScriptVersion, $Mode, $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM-dd HH:mm'))

  if ($Mode -eq 'TrustCert') {
    if (-not $CertPem -or $CertPem -notmatch 'BEGIN CERTIFICATE') { throw 'TrustCert needs CertPem (the public certificate text printed by Status).' }
    $tmp = Join-Path $env:TEMP ('oesu-camportal-' + [guid]::NewGuid().ToString('N') + '.crt')
    [IO.File]::WriteAllText($tmp, ($CertPem -replace '\\n', "`n"))
    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2($tmp)
    if ($c.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -ne $Hostname) { throw "Certificate subject $($c.Subject) does not match $Hostname." }
    $bc = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' } | Select-Object -First 1
    if (-not $bc -or $bc.CertificateAuthority) { throw 'Refusing to trust this certificate: it must be the portal leaf certificate (basicConstraints CA:FALSE).' }
    $CertThumbprint = [Environment]::GetEnvironmentVariable('CertThumbprint')
    if ($CertThumbprint -and ($c.Thumbprint -ne $CertThumbprint.Replace(' ', '').ToUpper())) { throw "Certificate thumbprint $($c.Thumbprint) does not match CertThumbprint." }
    $have = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $c.Thumbprint
    if ($have) { Say "Already trusted: $($c.Thumbprint)" } else { Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null; Say "Trusted portal certificate $($c.Thumbprint) (expires $($c.NotAfter.ToString('yyyy-MM-dd')))." }
    Remove-Item $tmp -Force
    $resolved = $null
    try { $resolved = (Resolve-DnsName -Name $Hostname -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress } catch { }
    Say ("DNS: $Hostname resolves to " + $(if ($resolved) { $resolved } else { 'nothing' }))
    if ($ServerIP -and $resolved -ne $ServerIP) {
      if ($AddHosts) {
        $hosts = Join-Path $Sys32 'drivers\etc\hosts'
        $line = "$ServerIP`t$Hostname`t# OESU camera portal"
        $content = Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch ([regex]::Escape($Hostname)) }
        Set-Content -Path $hosts -Value (@($content) + $line) -Encoding ASCII
        Say "Added hosts entry $ServerIP $Hostname."
      } else { Problem "$Hostname does not resolve to $ServerIP on this PC. Rerun with AddHosts=true, or point this PC at the domain DNS." }
    }
    Say ('Done. The viewer opens https://' + $Hostname + '/ in Chrome or Edge.')
    exit 0
  }

  $principalOk = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $principalOk) { throw 'Run elevated (Administrator or SYSTEM).' }

  if ($Mode -eq 'Status') { Show-Status; if ($script:Problems.Count) { exit 1 } else { exit 0 } }

  if ($Mode -eq 'SetSecret') {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (-not [Environment]::UserInteractive -or $me -match 'SYSTEM$') { throw 'SetSecret must be run by a person at the server (RDP or console), not through Datto, so the secret never leaves the server.' }
    if (-not (Get-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' -ErrorAction SilentlyContinue)) { throw 'Run Install before SetSecret.' }
    $sec = Get-Secrets
    $cid = Read-Host 'Google OAuth client ID (ends in .apps.googleusercontent.com)'
    if ($cid -notmatch '\.apps\.googleusercontent\.com$') { throw 'That does not look like a Google OAuth client ID.' }
    $ss = Read-Host 'Google OAuth client secret (input hidden)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($plain.Length -lt 20) { throw 'That secret is too short.' }
    $cookie = if ($sec -and $sec.cookie_secret) { $sec.cookie_secret } else { New-RandomString 32 }
    New-Item -ItemType Directory -Force -Path $SecretDir | Out-Null
    $obj = [pscustomobject]@{ client_id = $cid; client_secret = $plain; cookie_secret = $cookie; set_by = $me; set_at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText((Join-Path $SecretDir 'oauth.json'), ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $plain = $null
    Write-ProxyConfig (Get-Secrets) | Out-Null
    Set-Acls
    Stop-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' -ErrorAction SilentlyContinue
    Get-Process -Name 'oauth2-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force
    Enable-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' | Out-Null
    Start-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\'
    Start-Sleep -Seconds 3
    Say 'Secret saved (readable only by SYSTEM, Administrators and the portal). Store the client secret in IT Glue too.'
    Show-Status
    exit 0
  }

  $addr = Get-ServerAddress
  $ip = $addr.IPAddress
  if (-not $AllowedNet) { $AllowedNet = Get-NetworkCidr $ip $addr.PrefixLength }
  $Nets = @($AllowedNet -split '[,\s]+' | Where-Object { $_ })
  foreach ($n in $Nets) { if ($n -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { throw "Bad AllowedNet entry '$n'." } }
  $AllowedNet = $Nets -join ' '
  $emails = @($AllowedEmails.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
  foreach ($e in $emails) { if ($e -notmatch '^[a-z0-9._%+-]+@oesu\.org$') { throw "Allowed email '$e' is not an oesu.org address." } }

  if ($Mode -eq 'Uninstall') {
    Head 'Uninstall'
    $s = Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if ($s) { Stop-Service $Svc -Force -ErrorAction SilentlyContinue; Invoke-Native (Join-Path $ApacheDir 'bin\httpd.exe') @('-k', 'uninstall', '-n', $Svc) -AllowFail | Out-Null; Say 'Apache service removed.' }
    foreach ($t in @($TaskProxy, $TaskClean)) { Unregister-ScheduledTask -TaskName $t -TaskPath '\OESU\' -Confirm:$false -ErrorAction SilentlyContinue }
    Get-Process -Name 'oauth2-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Say 'Tasks and firewall rules removed.'
    if ($RemoveDns -and (Test-Path $recPath)) {
      $ir = Get-Content -Raw $recPath | ConvertFrom-Json
      if ($ir.dnsAction -eq 'pinpoint' -and (Get-DnsServerZone -Name $ir.host -ErrorAction SilentlyContinue)) { Remove-DnsServerZone -Name $ir.host -Force; Say "DNS zone $($ir.host) removed." }
      elseif ($ir.dnsAction -in @('record-in-parent', 'record-in-pinpoint')) { Remove-DnsServerResourceRecord -ZoneName $ir.dnsZone -Name $ir.dnsName -RRType A -Force -ErrorAction SilentlyContinue; Say "DNS record $($ir.dnsName) removed from $($ir.dnsZone)." }
      else { Say 'DNS left alone (the installer did not create it).' }
    }
    Set-Location $env:SystemRoot
    Get-Process httpd, rotatelogs -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root*" } | Stop-Process -Force
    Start-Sleep -Seconds 2
    if (Test-Path $Root) { $dest = $Root + '-removed-' + (Get-Date -Format 'yyyyMMdd-HHmm'); Move-Item $Root $dest; Say "Files moved to $dest (nothing deleted)." }
    exit 0
  }

  # ---------------- Plan and Install share the checks
  New-Item -ItemType Directory -Force -Path $Root, $Staging | Out-Null
  # Lock the folder before anything is downloaded into it (C:\ inheritance would give Authenticated Users modify).
  Invoke-Native $Icacls @($Root, '/inheritance:r', '/grant:r', "${SID_SYSTEM}:(OI)(CI)F", "${SID_ADMINS}:(OI)(CI)F", '/C', '/Q') | Out-Null

  Head 'Server'
  $os = Get-CimInstance Win32_OperatingSystem
  $cs = Get-CimInstance Win32_ComputerSystem
  Say ("{0}, {1}, domain role {2} (4 or 5 means domain controller)" -f $os.Caption, $cs.Domain, $cs.DomainRole)
  Say ("Portal address {0} on {1}, allowed viewers' network {2}" -f $ip, $addr.InterfaceAlias, $AllowedNet)
  if ($cs.DomainRole -ge 4) { Say 'NOTE: domain controller. Apache and oauth2-proxy run as LocalService, listen only where needed, and accept only the LAN.' }

  Head 'Ports'
  $listen = @(Get-Listeners)
  $mine = @('httpd', 'oauth2-proxy')
  $conflicts = @($listen | Where-Object { $_.Process -notin $mine -and ($_.Address -in @('0.0.0.0', '::', $ip, '127.0.0.1')) })
  if ($listen.Count) { $listen | ForEach-Object { Say ('  in use: {0}:{1} by {2} (pid {3})' -f $_.Address, $_.Port, $_.Process, $_.Pid) } } else { Say '  80, 443, 4180, 8088 are free' }
  foreach ($c in $conflicts) { Problem ("Port {0} on {1} is held by {2}. The portal cannot start until that is resolved." -f $c.Port, $c.Address, $c.Process) }

  Head 'Windows Firewall'
  Get-NetFirewallProfile | ForEach-Object { Say ('  {0} profile enabled: {1}, default inbound {2}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction) }
  if ((Get-NetFirewallProfile -Name Domain).Enabled -ne 'True') { Say '  NOTE: the Domain profile is off, so the firewall rule will not restrict anything. Apache still refuses anyone outside the allowed network.' }
  $broad = Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -contains '443' -or $_.LocalPort -contains '80' } |
    Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Group -ne $FwGroup } |
    ForEach-Object { $_.DisplayName }
  if ($broad) { Say ('  existing allow rules for 80/443: ' + ($broad -join '; ')) }

  Head 'Prerequisites'
  $vc = Get-VcRuntime
  Say ('  VC++ 2015-2026 x64 runtime: ' + $(if ($vc) { $vc } else { 'not installed' }) + ' (Apache Lounge VS18 build wants 14.50 or later)')
  Say ('  tar.exe: ' + $(if (Test-Path $TarExe) { 'present' } else { 'MISSING' }))
  if (-not (Test-Path $TarExe)) { Problem 'tar.exe is missing; cannot unpack oauth2-proxy.' }
  foreach ($u in @('https://www.apachelounge.com/', 'https://api.github.com/', 'https://accounts.google.com/', 'https://oauth2.googleapis.com/', 'https://www.googleapis.com/', 'https://aka.ms/')) { Say ('  outbound ' + $u + ' ' + (Test-Outbound $u)) }

  Head 'DNS'
  $dns = Get-DnsPlan $ip
  Say ('  ' + $dns.Detail)
  try { $r = Resolve-DnsName -Name $Hostname -Type A -ErrorAction Stop | Where-Object IPAddress | Select-Object -First 1; Say ('  resolves today to ' + $r.IPAddress) } catch { Say '  does not resolve today (expected before install)' }

  Head 'Downloads (into staging, verified by SHA-256)'
  $ap = Get-ApacheArtifact
  Say ('  Apache:       ' + $ap.Url)
  Say ('    SHA-256     ' + $ap.Sha256)
  $px = Get-ProxyArtifact
  Say ('  oauth2-proxy: ' + $px.Url)
  Say ('    SHA-256     ' + $px.Sha256)
  if ($px.GitHubDigest) {
    if ($px.GitHubDigest -eq $px.Sha256) { Say '    matches the digest GitHub publishes for this release asset' } else { Problem 'oauth2-proxy download does NOT match the GitHub digest. Do not install.' }
  } else { Say '    GitHub did not return a digest for this asset; compare with the release page by hand' }

  Head 'Install would'
  Say ('  1. Install the VC++ runtime if older than 14.50 (Microsoft-signed, verified before running)')
  Say ('  2. Unpack Apache to ' + $ApacheDir + ' and oauth2-proxy to ' + $ProxyDir)
  Say ('  3. Write the portal page to ' + $SiteDir + ' (an existing portal-config.json is kept)')
  Say ('  4. Write ' + (Join-Path $ConfDir 'httpd.conf') + ': listen on ' + $ip + ':80 (redirect only), ' + $ip + ':443 and 127.0.0.1:8088; only ' + $AllowedNet + ' allowed')
  Say ('  5. Make a self-signed certificate for ' + $Hostname + ' (820 days) unless a valid one exists')
  Say ('  6. Allow these Google accounts: ' + ($emails -join ', '))
  Say ('  7. Lock ' + $Root + ' to SYSTEM and Administrators; LocalService gets read, plus write on logs')
  Say ('  8. DNS: ' + $(if ($CreateDns) { $dns.Detail } else { 'no change (CreateDns=false)' }))
  Say ('  9. Firewall rule "' + $FwGroup + '": inbound TCP 80,443 to httpd.exe from ' + $AllowedNet + ' only')
  Say (' 10. Service ' + $Svc + ' (Apache) as NT AUTHORITY\LocalService, automatic, restart on failure')
  Say (' 11. Task \OESU\' + $TaskProxy + ' (oauth2-proxy as LocalService, at startup and every 5 minutes if stopped); task \OESU\' + $TaskClean + ' (180 day log retention)')
  Say (' 12. ' + $(if ($PublishTrust) { 'Publish the portal certificate to Active Directory so domain PCs trust it' } else { 'Not touch certificate trust on other PCs (use TrustCert on each viewer PC)' }))

  if ($Mode -eq 'Plan') {
    Head 'Result'
    if ($script:Problems.Count) { Say ('Plan found ' + $script:Problems.Count + ' problem(s); fix them before Install.'); exit 1 }
    Say 'Plan OK. To install, rerun with Mode=Install, WhatIf=false and:'
    Say ('  ApacheSha256=' + $ap.Sha256)
    Say ('  OAuth2ProxySha256=' + $px.Sha256)
    exit 0
  }

  if ($Mode -ne 'Install') { throw "Unknown mode '$Mode'. Use Plan, Install, SetSecret, Status, TrustCert or Uninstall." }

  # ---------------- Install
  if ($script:Problems.Count) { throw 'Install stopped: the checks above found problems.' }
  if ($ApacheSha256.ToLower() -ne $ap.Sha256) { throw "ApacheSha256 does not match the downloaded file ($($ap.Sha256)). Run Plan and confirm the value." }
  if ($OAuth2ProxySha256.ToLower() -ne $px.Sha256) { throw "OAuth2ProxySha256 does not match the downloaded file ($($px.Sha256)). Run Plan and confirm the value." }

  Head 'Installing'
  if (-not $vc -or $vc -lt [version]'14.50.0') {
    $vcExe = Join-Path $Staging 'vc_redist.x64.exe'
    Invoke-WebRequest -UseBasicParsing -UserAgent $UA -Uri 'https://aka.ms/vc14/vc_redist.x64.exe' -OutFile $vcExe
    $sig = Get-AuthenticodeSignature $vcExe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'VC++ runtime download is not validly signed by Microsoft.' }
    $p = Start-Process -FilePath $vcExe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    if ($p.ExitCode -notin 0, 1638, 3010) { throw "VC++ runtime install failed ($($p.ExitCode))." }
    Say ('  VC++ runtime installed (exit ' + $p.ExitCode + $(if ($p.ExitCode -eq 3010) { ', a reboot is pending but Apache runs without it' } else { '' }) + ')')
  }

  New-Item -ItemType Directory -Force -Path $ConfDir, $SslDir, $SecretDir, $LogDir, $PubDir, $ProxyDir, (Split-Path $ApacheDir) | Out-Null
  $svcObj = Get-Service -Name $Svc -ErrorAction SilentlyContinue
  if ($svcObj -and $svcObj.Status -eq 'Running') { Stop-Service $Svc -Force; Say '  stopped Apache for upgrade' }
  Stop-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' -ErrorAction SilentlyContinue
  Get-Process -Name 'oauth2-proxy' -ErrorAction SilentlyContinue | Stop-Process -Force

  $x = Join-Path $Staging 'apache-extract'
  if (Test-Path $x) { Remove-Item $x -Recurse -Force }
  Expand-Archive -Path $ap.Path -DestinationPath $x -Force
  $src = Get-ChildItem $x -Directory -Recurse -Filter 'Apache24' | Select-Object -First 1
  if (-not $src) { throw 'Apache24 folder not found in the zip.' }
  Get-Process httpd, rotatelogs -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Root*" } | Stop-Process -Force
  Start-Sleep -Seconds 2
  if (Test-Path $ApacheDir) { $bak = $ApacheDir + '.prev-' + (Get-Date -Format 'yyyyMMddHHmm'); Move-Item $ApacheDir $bak; Say "  previous Apache kept at $bak" }
  Move-Item $src.FullName $ApacheDir
  Say ('  Apache unpacked: ' + ((Invoke-Native (Join-Path $ApacheDir 'bin\httpd.exe') @('-v') -AllowFail) -split "`r`n" | Select-Object -First 1))

  $px2 = Join-Path $Staging 'proxy-extract'
  if (Test-Path $px2) { Remove-Item $px2 -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $px2 | Out-Null
  Invoke-Native $TarExe @('-xzf', $px.Path, '-C', $px2) | Out-Null
  $exe = Get-ChildItem $px2 -Recurse -Filter 'oauth2-proxy*.exe' | Select-Object -First 1
  if (-not $exe) { $exe = Get-ChildItem $px2 -Recurse -File | Where-Object { $_.Name -match '^oauth2-proxy$' } | Select-Object -First 1 }
  if (-not $exe) { throw 'oauth2-proxy executable not found in the archive.' }
  Copy-Item $exe.FullName (Join-Path $ProxyDir 'oauth2-proxy.exe') -Force
  Say ('  oauth2-proxy unpacked: ' + (Invoke-Native (Join-Path $ProxyDir 'oauth2-proxy.exe') @('--version') -AllowFail).Trim())

  Write-SiteFiles
  $emailFile = Join-Path $ConfDir 'allowed-emails.txt'
  [IO.File]::WriteAllText($emailFile, ("# Google accounts allowed into the OESU camera portal. One per line. Managed by the installer (AllowedEmails).`r`n" + ($emails -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
  New-PortalCert
  $sec = Get-Secrets
  $cookie = Write-ProxyConfig $sec
  if (-not $sec) {
    $obj = [pscustomobject]@{ client_id = ''; client_secret = ''; cookie_secret = $cookie; set_by = 'installer'; set_at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText((Join-Path $SecretDir 'oauth.json'), ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  }
  Write-ApacheConfig $ip $AllowedNet
  Set-Acls
  Invoke-Native $Icacls @((Join-Path $ApacheDir 'logs'), '/grant', "${SID_LOCALSVC}:(OI)(CI)M", '/C', '/Q') -AllowFail | Out-Null
  $test = Invoke-Native (Join-Path $ApacheDir 'bin\httpd.exe') @('-t', '-f', (Join-Path $ConfDir 'httpd.conf')) -AllowFail
  if ($test -notmatch 'Syntax OK') { throw ('Apache config test failed: ' + $test.Trim()) }
  Say '  Apache config test: Syntax OK'

  if ($CreateDns -and $dns.Action -in @('pinpoint', 'record-in-parent', 'record-in-pinpoint')) {
    if ($dns.Action -eq 'pinpoint') { Add-DnsServerPrimaryZone -Name $Hostname -ReplicationScope Domain -DynamicUpdate None }
    Add-DnsServerResourceRecordA -ZoneName $dns.Zone -Name $dns.Name -IPv4Address $ip -TimeToLive (New-TimeSpan -Minutes 10)
    Say ('  DNS: ' + $dns.Detail)
  }

  Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName 'OESU Camera Portal HTTPS (Central Office LAN only)' -Group $FwGroup -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort 80, 443 -LocalAddress $ip -RemoteAddress $Nets -Program (Join-Path $ApacheDir 'bin\httpd.exe') -Profile Any | Out-Null
  Say ('  firewall rule added: TCP 80,443 from ' + $AllowedNet)

  Install-ApacheService
  Register-ProxyTask
  Register-CleanupTask
  Start-Service $Svc
  Say '  Apache service started as LocalService'
  $sec = Get-Secrets
  if ($sec -and $sec.client_id -and $sec.client_secret) { Start-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\'; Say '  oauth2-proxy started' }
  else {
    Disable-ScheduledTask -TaskName $TaskProxy -TaskPath '\OESU\' | Out-Null
    Say '  oauth2-proxy task is disabled until the Google client secret is set: run this script with -Mode SetSecret at the server (the page answers 503 until then)'
  }

  if ($PublishTrust) {
    $out = Invoke-Native $Certutil @('-dspublish', '-f', (Join-Path $PubDir "$Hostname.crt"), 'RootCA') -AllowFail
    if ($script:LastNativeExit -eq 0) { Say '  certificate published to Active Directory; domain PCs trust it after their next policy refresh' }
    else { Problem ('Publishing to AD failed (needs Enterprise Admin; SYSTEM usually cannot): ' + $out.Trim() + ' Use TrustCert on each viewer PC instead.') }
  }

  if ($PSCommandPath -and (Test-Path $PSCommandPath)) { Copy-Item $PSCommandPath (Join-Path $Root 'Install-OESUCameraPortal.ps1') -Force; Say ('  installer kept at ' + (Join-Path $Root 'Install-OESUCameraPortal.ps1') + ' for SetSecret and Status') }
  $record = [pscustomobject]@{ installed = (Get-Date).ToString('s'); version = $ScriptVersion; host = $Hostname; ip = $ip; allowedNet = $AllowedNet; apache = $ap.Url; apacheSha256 = $ap.Sha256; oauth2proxy = $px.Url; oauth2proxySha256 = $px.Sha256; viewers = $emails; dnsAction = $(if ($CreateDns) { $dns.Action } else { 'none' }); dnsZone = $dns.Zone; dnsName = $dns.Name }
  [IO.File]::WriteAllText((Join-Path $Root 'install-record.json'), ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  Show-Status
  Head 'Result'
  Say 'Install complete. Next: create the Google OAuth client if not done, run SetSecret at the server, then TrustCert on the viewer PCs.'
  exit 0
}
catch {
  Write-Output ('FAILED: ' + $_.Exception.Message)
  exit 1
}
