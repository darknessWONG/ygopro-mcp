# bridge/sync-skill.ps1 - compare/merge the live DSH skill with the repo copy.
#
# The live copy at %USERPROFILE%\.dsh\skills\ygopro-play is authoritative: the
# playing LLM edits it directly. The repo copy (_repos\ygopro-mcp\skill\ygopro-play)
# is only a backup and may be older. Always run this script BEFORE editing a skill
# file, and never overwrite the newer copy with the older one.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File bridge\sync-skill.ps1
#   powershell ... -File bridge\sync-skill.ps1 -Apply -Direction live
#   powershell ... -File bridge\sync-skill.ps1 -Apply -Direction repo -Force
#
# Exit: 0 = identical or synced; 1 = differs (not applied); 2 = error / refused.
param(
    [switch]$Apply,
    [ValidateSet('live', 'repo')]
    [string]$Direction = 'live',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$liveDir = Join-Path $env:USERPROFILE '.dsh\skills\ygopro-play'
$repoDir = Join-Path $root '_repos\ygopro-mcp\skill\ygopro-play'
$names = @('SKILL.md', 'PLAYBOOK-FULL.md', 'PITFALLS-2026-11.md')

if (-not (Test-Path $liveDir)) { Write-Host "ERROR: live skill not found: $liveDir"; exit 2 }
if (-not (Test-Path $repoDir)) { Write-Host "ERROR: repo skill not found: $repoDir"; exit 2 }

Write-Host "live = $liveDir"
Write-Host "repo = $repoDir"
Write-Host ''

$different = $false
$rows = @()
foreach ($n in $names) {
    $lp = Join-Path $liveDir $n
    $rp = Join-Path $repoDir $n
    if ((-not (Test-Path $lp)) -and (-not (Test-Path $rp))) { continue }
    $li = $null
    $ri = $null
    if (Test-Path $lp) { $li = Get-Item $lp }
    if (Test-Path $rp) { $ri = Get-Item $rp }
    $lh = 'MISSING'
    $rh = 'MISSING'
    if ($li) { $lh = (Get-FileHash $lp -Algorithm SHA256).Hash }
    if ($ri) { $rh = (Get-FileHash $rp -Algorithm SHA256).Hash }
    $same = ($lh -eq $rh)
    if (-not $same) { $different = $true }
    $note = ''
    if (-not $same) {
        if (-not $li) { $note = 'repo only' }
        elseif (-not $ri) { $note = 'live only' }
        elseif ($li.LastWriteTime -gt $ri.LastWriteTime) { $note = 'LIVE newer' }
        elseif ($ri.LastWriteTime -gt $li.LastWriteTime) { $note = 'REPO newer' }
        else { $note = 'same mtime, content differs' }
    }
    $row = [pscustomobject]@{ Name = $n; Same = $same; Note = $note; LiveTime = $null; RepoTime = $null; LiveHash = $lh; RepoHash = $rh }
    if ($li) { $row.LiveTime = $li.LastWriteTime }
    if ($ri) { $row.RepoTime = $ri.LastWriteTime }
    $rows += $row
    $state = 'same'
    if (-not $same) { $state = 'DIFF' }
    Write-Host ("{0,-22} {1,-6} {2}" -f $n, $state, $note)
    if (-not $same) {
        Write-Host ("    live {0} {1}" -f $row.LiveTime, $row.LiveHash.Substring(0, 8))
        Write-Host ("    repo {0} {1}" -f $row.RepoTime, $row.RepoHash.Substring(0, 8))
    }
}

if (-not $different) {
    Write-Host ''
    Write-Host 'OK: live and repo skill are identical.'
    exit 0
}

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Files differ, nothing changed. Pick a direction and add -Apply:'
    Write-Host '  live -> repo : -Apply -Direction live       (recommended: live is authoritative)'
    Write-Host '  repo -> live : -Apply -Direction repo -Force (overwrites live; confirm live is not newer)'
    exit 1
}

if (($Direction -eq 'repo') -and (-not $Force)) {
    $newerLive = $rows | Where-Object {
        (-not $_.Same) -and $_.LiveTime -and $_.RepoTime -and ($_.LiveTime -gt $_.RepoTime)
    }
    if ($newerLive) {
        Write-Host ''
        Write-Host 'REFUSED: live is newer than repo; refusing to overwrite live. Use -Force to override.'
        exit 2
    }
}

$src = $repoDir
$dst = $liveDir
$label = 'repo -> live'
if ($Direction -eq 'live') {
    $src = $liveDir
    $dst = $repoDir
    $label = 'live -> repo'
}

foreach ($n in $names) {
    $s = Join-Path $src $n
    if (-not (Test-Path $s)) { continue }
    $d = Join-Path $dst $n
    # per-file guard: never overwrite a NEWER destination unless -Force (a blanket
    # direction can otherwise clobber the only up-to-date copy of one file)
    if ((Test-Path $d) -and (-not $Force)) {
        $si = Get-Item $s
        $di = Get-Item $d
        if ($si.LastWriteTime -lt $di.LastWriteTime) {
            Write-Host "SKIP $n (source older than destination; use -Force to override)"
            continue
        }
    }
    Copy-Item $s $d -Force
    Write-Host "copied $n  ($label)"
}
Write-Host ''
Write-Host "DONE ($label). Commit/push the repo change; live takes effect for new sessions."
exit 0
