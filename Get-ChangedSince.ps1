<#
=======================================================================
 Get-ChangedSince.ps1
 Version 1.0  (2026-09-19)

 Answers one question: how much has actually changed on the file server
 since the migration ran, and where.

 READ ONLY against the data. It opens nothing, moves nothing, changes no
 permission. The only thing it writes is its own report, into
 C:\ProgramData\OESU, never into C:\Data.

 Designed to be run through the OESU - Run Script launcher, so it needs
 no RDP session and no console.

 PARAMETERS (passed as Params JSON by the launcher)
   SinceUtc   ISO date to compare against. Default 2026-09-12T00:00:00Z,
              the day the GAM migration ran.
   ScanRoots  Semicolon separated folders. Default C:\Data
   TopN       How many of the most recently changed files to list.
              Default 40. Output goes through a job log, so keep it small.

 OUTPUT
   A per-folder table, a total, and the newest TopN paths.
   Machine readable lines start with CHANGED| or TOTAL|.
   Report CSV: C:\ProgramData\OESU\changed-since.csv
=======================================================================
#>

$ErrorActionPreference = 'Continue'

$Computer = $env:COMPUTERNAME
$OutDir   = if ($env:ProgramData) { Join-Path $env:ProgramData 'OESU' } else { Join-Path ([IO.Path]::GetTempPath()) 'OESU' }
$Report   = Join-Path $OutDir 'changed-since.csv'

$SinceRaw = if ($env:SinceUtc) { $env:SinceUtc } else { '2026-09-12T00:00:00Z' }
$RootsRaw = if ($env:ScanRoots) { $env:ScanRoots } else { '' }
$TopN     = if ($env:TopN) { [int]$env:TopN } else { 40 }
$Depth    = if ($env:Depth) { [int]$env:Depth } else { 2 }

$Since = [datetime]::MinValue
$styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
if (-not [datetime]::TryParse($SinceRaw, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$Since)) {
    Write-Host "REFUSED: SinceUtc '$SinceRaw' is not a date I can read."
    exit 1
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Write-Host '======================================================================='
Write-Host " Get-ChangedSince v1.0   READ ONLY"
Write-Host " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host " counting files modified after: $($Since.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Host '======================================================================='
Write-Host ''

# Where to look. With no ScanRoots given, ask the server what it actually shares
# rather than assuming a path. Scanning what we THINK is there is how you miss a
# folder users map every day.
$shareInfo = @()
try {
    $shareInfo = @(Get-SmbShare -ErrorAction Stop | Where-Object {
        $_.Name -notmatch '\$$' -and
        @('NETLOGON','SYSVOL','CertEnroll') -notcontains $_.Name -and
        $_.Path
    })
} catch {
    Write-Host "  (could not enumerate shares: $($_.Exception.Message))"
}

if ($shareInfo.Count -gt 0) {
    Write-Host 'SHARES SERVED BY THIS MACHINE:'
    $shareInfo | Select-Object Name, Path | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
    foreach ($s in $shareInfo) { Write-Host ("SHARE|{0}|{1}|{2}" -f $Computer, $s.Name, $s.Path) }
    Write-Host ''
}

if ($RootsRaw) {
    $roots = @($RootsRaw -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ })
} elseif ($shareInfo.Count -gt 0) {
    $roots = @($shareInfo | ForEach-Object { $_.Path.TrimEnd('\') } | Sort-Object -Unique)
    Write-Host ("No ScanRoots given, so scanning the {0} shared path(s) listed above." -f $roots.Count)
    Write-Host ''
} else {
    $roots = @('C:\Data')
    Write-Host 'No ScanRoots given and no shares readable. Falling back to C:\Data.'
    Write-Host ''
}

$changed   = New-Object System.Collections.Generic.List[object]
$totalAll  = 0
$totalNew  = 0
$bytesNew  = 0
$unreadable = 0

foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Host "  SKIP  $root  (not found)"
        continue
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()

    # group by the first folder under the root, which is how the migration was scoped
    $perFolder = @{}

    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable walkErr |
        ForEach-Object {
            $totalAll++
            if ($_.LastWriteTimeUtc -le $Since) { return }

            # split on either separator so grouping is correct regardless of platform
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            $parts = @($rel -split '[\\/]')
            # group $Depth levels deep. users\Shared Accounting and users\Sonya.McLam
            # are different things; rolling them into "users" hides the answer.
            $keep = [Math]::Min($Depth, $parts.Count - 1)
            $top = if ($keep -le 0) { '(files at root)' } else { ($parts[0..($keep-1)]) -join '\' }
            if (-not $perFolder.ContainsKey($top)) {
                $perFolder[$top] = [pscustomobject]@{ Folder = $top; Files = 0; Bytes = [int64]0 }
            }
            $perFolder[$top].Files++
            $perFolder[$top].Bytes += $_.Length

            $totalNew++
            $bytesNew += $_.Length

            $changed.Add([pscustomobject]@{
                Root        = $root
                RelPath     = $rel
                SizeBytes   = $_.Length
                ModifiedUtc = $_.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
        }

    $sw.Stop()
    $unreadable += @($walkErr).Count

    Write-Host "ROOT $root   scanned in $([int]$sw.Elapsed.TotalSeconds)s"
    Write-Host ''

    if ($perFolder.Count -eq 0) {
        Write-Host '  nothing changed under this root'
    } else {
        $rows = $perFolder.Values | Sort-Object Files -Descending
        $rows | Format-Table `
            @{n='Folder';e={$_.Folder}}, `
            @{n='Files';e={'{0:N0}' -f $_.Files}}, `
            @{n='MB';e={'{0:N1}' -f ($_.Bytes/1MB)}} |
            Out-String -Width 240 | Write-Host
        foreach ($r in $rows) {
            Write-Host ("CHANGED|{0}|{1}|{2}|{3}" -f $Computer, $r.Folder, $r.Files, $r.Bytes)
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------- report

try {
    $changed | Sort-Object ModifiedUtc -Descending | Export-Csv -Path $Report -NoTypeInformation -Encoding UTF8
} catch {
    Write-Host "  (could not write $Report : $($_.Exception.Message))"
}

Write-Host '======================================================================='
Write-Host (" Files scanned      : {0:N0}" -f $totalAll)
Write-Host (" Changed since date : {0:N0}" -f $totalNew)
Write-Host (" Bytes to re-push   : {0:N2} MB" -f ($bytesNew/1MB))
if ($totalAll -gt 0) {
    Write-Host (" Percent changed    : {0:N2}%" -f (100 * $totalNew / $totalAll))
}
if ($unreadable -gt 0) {
    Write-Host (" Paths unreadable   : {0:N0}  (long paths or permissions, NOT counted above)" -f $unreadable)
}
Write-Host " Report written to  : $Report"
Write-Host '======================================================================='
Write-Host ("TOTAL|{0}|{1}|{2}|{3}|{4}" -f $Computer, $totalAll, $totalNew, $bytesNew, $unreadable)
Write-Host ''

if ($totalNew -gt 0) {
    Write-Host "Most recently changed, up to $TopN of $totalNew :"
    $changed | Sort-Object ModifiedUtc -Descending | Select-Object -First $TopN |
        Format-Table @{n='Modified (UTC)';e={$_.ModifiedUtc}}, @{n='KB';e={'{0:N0}' -f ($_.SizeBytes/1KB)}}, RelPath |
        Out-String -Width 240 | Write-Host
}

Write-Host "DONE|Get-ChangedSince|1.0|$Computer"
exit 0
