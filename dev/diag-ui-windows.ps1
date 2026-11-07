<#
.SYNOPSIS
  task-22 UI-window sampler: poll /ui.windows on both clients and flag stuck windows.
.DESCRIPTION
  Samples every -SampleInterval seconds on ports 7788/7789, records visible window
  name/rect/textLen; takes a screenshot every -ShotInterval seconds. A window that is
  visible in >=2 consecutive samples is reported as "stuck".
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File bridge\dev\diag-ui-windows.ps1 -DurationSec 300
#>
param(
  [string]$Stamp = (Get-Date -Format 'yyyyMMdd-HHmmss'),
  [int]$DurationSec = 300,
  [int]$SampleInterval = 5,
  [int]$ShotInterval = 20,
  [int]$HostPort = 7788,
  [int]$GuestPort = 7789
)
$ErrorActionPreference = 'Continue'
$logDir = 'ranked\logs'
$dir = Join-Path $logDir ('uiwin-' + $Stamp)
$log = Join-Path $logDir ('ui-windows-' + $Stamp + '.log')
New-Item -ItemType Directory -Path $dir -Force | Out-Null
function Get-Json($url) { try { return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3).Content | ConvertFrom-Json } catch { return $null } }
function W($m) { Add-Content -Path $log -Value $m -Encoding UTF8 }
W ('diag-ui-windows stamp=' + $Stamp + ' duration=' + $DurationSec + 's sample=' + $SampleInterval + 's shot=' + $ShotInterval + 's dir=' + $dir)
$started = $false
$deadline = (Get-Date).AddSeconds(240)
while ((Get-Date) -lt $deadline) {
  $h = Get-Json ('http://127.0.0.1:' + $HostPort + '/state')
  if ($h -and $h.started) { $started = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $started) { W 'FAIL: duel not started within 240s'; Write-Output 'FAIL: not started'; exit 1 }
W ('duel started at ' + (Get-Date -Format 'HH:mm:ss'))
$t0 = Get-Date; $nextShot = 0; $shotN = 0
while (((Get-Date) - $t0).TotalSeconds -lt $DurationSec) {
  $el = [int]((Get-Date) - $t0).TotalSeconds
  foreach ($port in @($HostPort, $GuestPort)) {
    $ui = Get-Json ('http://127.0.0.1:' + $port + '/ui')
    $st = Get-Json ('http://127.0.0.1:' + $port + '/state')
    if ($null -eq $ui) { W ('[' + $el + 's] p' + $port + ' GONE'); continue }
    $vis = @()
    if ($ui.windows) { foreach ($w in @($ui.windows)) { if ($w.visible) { $vis += ($w.name + '|' + $w.rect.l + ',' + $w.rect.t + ',' + $w.rect.r + ',' + $w.rect.b + '|t=' + $w.textLen) } } }
    $turnTxt = 'state=null'; if ($st) { $turnTxt = 'turn=' + $st.turn + ' curMsg=' + $st.curMsg }
    $visTxt = '[]'; if ($vis.Count -gt 0) { $visTxt = $vis -join ';' }
    W ('[' + $el + 's] p' + $port + ' ' + $turnTxt + ' visible=' + $visTxt)
  }
  if ($el -ge $nextShot) {
    $nextShot = $el + $ShotInterval
    & powershell -NoProfile -ExecutionPolicy Bypass -File 'bridge\shot.ps1' -Tag ('diag' + $shotN) -OutDir $dir | Out-Null
    W ('  shot diag' + $shotN + ' at ' + $el + 's')
    $shotN++
  }
  Start-Sleep -Seconds $SampleInterval
}
W 'sampling done'
$streak = @{}
$best = @{}
foreach ($ln in (Get-Content $log -Encoding UTF8)) {
  if ($ln -notmatch '^\[\d+s\] p(\d+) .*visible=(.*)$') { continue }
  $port = $matches[1]; $vis = $matches[2]
  $names = @()
  if ($vis -ne '[]') { foreach ($v in ($vis -split ';')) { $names += ($v -split '\|')[0] } }
  foreach ($key in @($streak.Keys)) { if ($key.StartsWith($port + ':')) { $nm = $key.Substring($port.Length + 1); if ($names -notcontains $nm) { $streak[$key] = 0 } } }
  foreach ($n in $names) {
    $key = $port + ':' + $n
    if (-not $streak.ContainsKey($key)) { $streak[$key] = 0 }
    $streak[$key]++
    if (-not $best.ContainsKey($key) -or $streak[$key] -gt $best[$key]) { $best[$key] = $streak[$key] }
  }
}
Write-Output '--- window visibility summary (max consecutive samples) ---'
foreach ($k in ($best.Keys | Sort-Object)) { Write-Output ('  ' + $k + ' = ' + $best[$k]); Add-Content -Path $log -Value ('SUMMARY ' + $k + ' maxConsecutiveVisible=' + $best[$k]) -Encoding UTF8 }
Write-Output ($dir + ' ; ' + $log)
