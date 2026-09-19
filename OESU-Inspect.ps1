<#
=======================================================================
 OESU-Inspect.ps1
 Version 1.0  (2026-09-19)

 A general purpose READ ONLY inspector, run through the OESU - Run Script
 launcher. It exists so routine "what is in that folder" and "what does
 that log say" questions stop costing a commit and a console session.

 IT CANNOT CHANGE ANYTHING. There is deliberately not a single write
 cmdlet in this file: no Set-, New-, Remove-, Copy-, Move-, Rename-,
 Out-File, icacls, robocopy or redirection to disk. It reads and prints.
 If you ever find a write verb in here, someone has edited it.

 WHY THERE IS A SENSITIVE-PATH GUARD
 This runs as SYSTEM on OESU2019, which holds HR Privileged and
 Personnel Files. A general file reader on that box can read staff
 medical notes and personnel records. So reading file CONTENT under
 those trees is refused unless AllowSensitive is explicitly true, and
 every refusal and every allowed sensitive read is printed loudly into
 the Datto job log, which is itself an audit trail.
 Listing names and sizes under those trees is always allowed; it is
 reading the contents that is gated.

 PARAMETERS (Params JSON on the launcher)
   Action    shares | list | find | read | tail | acl        default shares
   Path      absolute path to act on
   Filter    wildcard for list and find                      default *
   Recurse   true to recurse a list                          default false
   Lines     lines for tail, or head limit for read          default 50
   MaxKB     hard cap on printed file content                default 64
   AllowSensitive   true to read content under restricted trees

 ACTIONS
   shares  every SMB share and its path
   list    names, sizes, modified times in one folder
   find    recursive filename search under Path
   read    print a text file, capped
   tail    print the last N lines of a text file
   acl     print the NTFS permissions on a path, which is what the
           freeze step needs before it denies write to a group

 OUTPUT
   Machine readable lines start with SHARE|, ITEM|, ACL| or INFO|.
=======================================================================
#>

$ErrorActionPreference = 'Continue'

$Computer = $env:COMPUTERNAME

$Action = if ($env:Action) { $env:Action.Trim().ToLower() } else { 'shares' }
$Path   = if ($env:Path)   { $env:Path.Trim() }   else { '' }
$Filter = if ($env:Filter) { $env:Filter.Trim() } else { '*' }
$Lines  = if ($env:Lines)  { [int]$env:Lines }    else { 50 }
$MaxKB  = if ($env:MaxKB)  { [int]$env:MaxKB }    else { 64 }
$Recurse         = ($env:Recurse -eq 'true')
$AllowSensitive  = ($env:AllowSensitive -eq 'true')

# Trees whose CONTENT is gated. Listing names under these is still fine.
$SensitivePatterns = @('*\HR Privileged\*', '*\Personnel Files\*', '*\HR Privileged', '*\Personnel Files')

# NOTE: must accept pipeline input. Without a process block, "... | Out-String | Say"
# binds nothing and prints an empty line, which silently blanks every table.
function Say {
    param([Parameter(ValueFromPipeline = $true, Position = 0)][string]$m)
    process { Write-Host $m }
}

function Fail([string]$reason, [string]$code) {
    Say "REFUSED: $reason"
    Say "INFO|$Computer|refused|$code"
    Say "DONE|OESU-Inspect|1.0|refused|$Computer"
    exit 1
}

function Test-Sensitive([string]$p) {
    foreach ($pat in $SensitivePatterns) { if ($p -like $pat) { return $true } }
    return $false
}

function Show-Size([int64]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return "$b B"
}

Say '======================================================================='
Say " OESU-Inspect v1.0   READ ONLY   action: $Action"
Say " computer: $Computer   time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
if ($Path) { Say " path: $Path" }
Say '======================================================================='
Say ''

# ---------------------------------------------------------------- shares

if ($Action -eq 'shares') {
    try {
        $sh = @(Get-SmbShare -ErrorAction Stop | Sort-Object Name)
        $sh | Select-Object Name, Path, Description | Format-Table -AutoSize | Out-String -Width 240 | Say
        foreach ($s in $sh) { Say ("SHARE|{0}|{1}|{2}" -f $Computer, $s.Name, $s.Path) }
        Say ''
        Say ("INFO|{0}|shares|{1}" -f $Computer, $sh.Count)
    } catch {
        Say "Could not enumerate shares: $($_.Exception.Message)"
    }
    Say "DONE|OESU-Inspect|1.0|ok|$Computer"
    exit 0
}

# ---------------------------------------------------- everything else needs a path

if (-not $Path) { Fail "Action '$Action' needs a Path." 'nopath' }
if ($Path -notmatch '^[A-Za-z]:\\' -and $Path -notmatch '^\\\\') {
    Fail "Path must be absolute, got '$Path'." 'relpath'
}
if (-not (Test-Path -LiteralPath $Path)) { Fail "Path not found: $Path" 'notfound' }

$item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
$isDir = $item -and $item.PSIsContainer

# ---------------------------------------------------------------- acl

if ($Action -eq 'acl') {
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        Say "Owner: $($acl.Owner)"
        Say ''
        $acl.Access |
            Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited |
            Format-Table -AutoSize | Out-String -Width 240 | Say
        foreach ($a in $acl.Access) {
            Say ("ACL|{0}|{1}|{2}|{3}|{4}" -f $Computer, $a.IdentityReference, $a.FileSystemRights, $a.AccessControlType, $a.IsInherited)
        }
    } catch {
        Say "Could not read the ACL: $($_.Exception.Message)"
    }
    Say ''
    Say "DONE|OESU-Inspect|1.0|ok|$Computer"
    exit 0
}

# ---------------------------------------------------------------- list

if ($Action -eq 'list') {
    if (-not $isDir) { Fail "list needs a folder, '$Path' is a file. Use read or tail." 'notadir' }

    $kids = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -Recurse:$Recurse -ErrorAction SilentlyContinue)

    $rows = $kids | Sort-Object PSIsContainer -Descending | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Type     = if ($_.PSIsContainer) { 'dir' } else { 'file' }
            Size     = if ($_.PSIsContainer) { '' } else { Show-Size $_.Length }
            Modified = $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm')
            Name     = if ($Recurse) { $_.FullName.Substring($Path.TrimEnd('\').Length).TrimStart('\') } else { $_.Name }
        }
    }

    if ($rows.Count -eq 0) {
        Say "  (nothing matches '$Filter')"
    } else {
        $rows | Format-Table Type, Size, Modified, Name -AutoSize | Out-String -Width 240 | Say
        foreach ($r in $rows) { Say ("ITEM|{0}|{1}|{2}|{3}" -f $Computer, $r.Type, $r.Modified, $r.Name) }
    }

    $files = @($kids | Where-Object { -not $_.PSIsContainer })
    $bytes = ($files | Measure-Object Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    Say ''
    Say ("INFO|{0}|list|{1} items|{2} files|{3}" -f $Computer, $rows.Count, $files.Count, (Show-Size $bytes))
    Say "DONE|OESU-Inspect|1.0|ok|$Computer"
    exit 0
}

# ---------------------------------------------------------------- find

if ($Action -eq 'find') {
    if (-not $isDir) { Fail "find needs a folder to search under." 'notadir' }

    $hits = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -Recurse -File -ErrorAction SilentlyContinue |
              Select-Object -First 500)

    if ($hits.Count -eq 0) {
        Say "  no files matching '$Filter' under $Path"
    } else {
        $hits | ForEach-Object {
            [pscustomobject]@{
                Size     = Show-Size $_.Length
                Modified = $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm')
                Path     = $_.FullName
            }
        } | Format-Table -AutoSize | Out-String -Width 240 | Say
    }
    Say ''
    Say ("INFO|{0}|find|{1}|{2}" -f $Computer, $Filter, $hits.Count)
    if ($hits.Count -eq 500) { Say 'NOTE: capped at 500 hits. Narrow the Filter.' }
    Say "DONE|OESU-Inspect|1.0|ok|$Computer"
    exit 0
}

# ---------------------------------------------------------------- read / tail

if ($Action -eq 'read' -or $Action -eq 'tail') {
    if ($isDir) { Fail "'$Path' is a folder. Use list." 'notafile' }

    if ((Test-Sensitive $Path) -and (-not $AllowSensitive)) {
        Say 'This file sits under a restricted tree (HR Privileged or Personnel Files).'
        Say 'Reading its contents is refused unless AllowSensitive is set to true.'
        Say 'Listing names and sizes there needs no override; only content is gated.'
        Fail "Refusing to print contents of a restricted file without AllowSensitive." 'sensitive'
    }
    if ((Test-Sensitive $Path) -and $AllowSensitive) {
        Say '*** SENSITIVE READ: AllowSensitive was set. This read is recorded in the Datto job log. ***'
        Say ''
    }

    $len = $item.Length
    Say ("Size: {0}   Modified: {1} UTC" -f (Show-Size $len), $item.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))
    Say ''

    # crude but effective binary check: look for a null byte near the start
    $probeLen = [Math]::Min(2048, [int]$len)
    $isBinary = $false
    if ($probeLen -gt 0) {
        # .NET stream read works on both Windows PowerShell 5.1 and PowerShell 7.
        # Get-Content -Encoding Byte is 5.1 only and throws on 7.
        try {
            $fs  = [IO.File]::OpenRead($Path)
            $buf = New-Object byte[] $probeLen
            $got = $fs.Read($buf, 0, $probeLen)
            $fs.Close()
            for ($i = 0; $i -lt $got; $i++) { if ($buf[$i] -eq 0) { $isBinary = $true; break } }
        } catch { }
    }
    if ($isBinary) {
        Say 'This looks like a binary file. Not printing it.'
        Say "INFO|$Computer|read|binary|$len"
        Say "DONE|OESU-Inspect|1.0|ok|$Computer"
        exit 0
    }

    $capBytes = $MaxKB * 1KB
    if ($len -gt $capBytes) {
        Say ("NOTE: file is {0}, printing only the {1} the cap allows. Raise MaxKB or use tail." -f (Show-Size $len), (Show-Size $capBytes))
        Say ''
    }

    try {
        if ($Action -eq 'tail') {
            $text = Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop
            Say "----- last $Lines lines -----"
        } else {
            $text = if ($Lines -gt 0) { Get-Content -LiteralPath $Path -TotalCount $Lines -ErrorAction Stop }
                    else              { Get-Content -LiteralPath $Path -ErrorAction Stop }
            Say "----- file contents -----"
        }

        $printed = 0
        foreach ($line in $text) {
            $printed += $line.Length + 2
            if ($printed -gt $capBytes) { Say '... (cap reached, output truncated)'; break }
            Say $line
        }
        Say '-------------------------'
    } catch {
        Say "Could not read the file: $($_.Exception.Message)"
    }

    Say ''
    Say "INFO|$Computer|$Action|$Path|$len"
    Say "DONE|OESU-Inspect|1.0|ok|$Computer"
    exit 0
}

Fail "Unknown Action '$Action'. Use shares, list, find, read, tail or acl." 'badaction'
